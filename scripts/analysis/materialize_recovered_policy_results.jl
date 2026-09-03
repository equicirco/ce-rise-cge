#!/usr/bin/env julia

"""
Replay accepted continuation paths and materialize their full policy summaries.

The initial grid retains all declared policy points. This script replaces only
the initially rejected 2% virgin-metal-tax rows recovered by the staged
continuation diagnostics, leaving unresolved rows visibly invalid.
"""

module MaterializeRecoveredPolicyResults

using CSV
using DataFrames
using Distributed
using JuMP
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const TAX_WEDGE = 0.02
const DEFAULT_WORKERS = 10

function command_options(args)
    paths = Dict{Symbol,String}()
    workers = DEFAULT_WORKERS
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] in ("--grid", "--predictor", "--neighbor", "--bisection", "--fine", "--diagonal", "--output") && index < length(args)
            key = Symbol(args[index][3:end])
            paths[key] = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/materialize_recovered_policy_results.jl " *
                "--grid PATH --predictor PATH --neighbor PATH --bisection PATH " *
                "--fine PATH --diagonal PATH --output PATH [--workers N] [--dry-run]")
        end
    end
    required = Set([:grid, :predictor, :neighbor, :bisection, :fine, :diagonal, :output])
    required ⊆ Set(keys(paths)) || error("Every staged-result path and --output is required.")
    return merge((workers = workers, dry_run = dry_run), (; paths...))
end

checkpoint_dir(output_file::AbstractString) = joinpath(dirname(output_file),
    "$(splitext(basename(output_file))[1])_checkpoints")

function accepted_endpoint_rows(path::AbstractString)
    table = CSV.read(path, DataFrame)
    required = Set([:target_profile, :trial_fraction, :trial_accepted])
    required ⊆ Set(Symbol.(names(table))) || error("Continuation file $(path) has no endpoint columns.")
    return table[.!ismissing.(table.target_profile) .&
        coalesce.(table.trial_fraction .== 1.0, false) .&
        coalesce.(table.trial_accepted, false), :]
end

function one_continuation_task(path::AbstractString, stage::Symbol)
    accepted = accepted_endpoint_rows(path)
    tasks = NamedTuple[]
    for rows in groupby(accepted, :target_profile)
        first_row = rows[1, :]
        full_trace = CSV.read(path, DataFrame)
        target_rows = full_trace[.!ismissing.(full_trace.target_profile) .&
            (full_trace.target_profile .== first_row.target_profile), :]
        accepted_steps = coalesce.(target_rows.trial_accepted, false) .&
            .!ismissing.(target_rows.trial_fraction)
        fractions = sort!(unique(Float64.(target_rows.trial_fraction[accepted_steps])))
        push!(tasks, (
            target = Symbol(first_row.target_profile),
            stage = stage,
            source = Symbol(first_row.source_profile),
            parameter = String(first_row.continued_parameter),
            accepted_fractions = fractions,
        ))
    end
    return tasks
end

function predictor_tasks(path::AbstractString)
    table = CSV.read(path, DataFrame)
    required = Set([:sensitivity_profile, :continuation_phase, :trial_accepted])
    required ⊆ Set(Symbol.(names(table))) || error("Predictor trace has no recognised columns.")
    profiles = sort!(unique(Symbol(row.sensitivity_profile) for row in eachrow(table)
        if String(row.continuation_phase) == "predictor_target" && row.trial_accepted);
        by = String)
    return [(target = profile, stage = :predictor, source = missing,
        parameter = missing, accepted_fractions = Float64[]) for profile in profiles]
end

function neighbor_tasks(path::AbstractString)
    table = CSV.read(path, DataFrame)
    required = Set([:sensitivity_profile, :source_profile, :changed_parameter, :solver_valid])
    required ⊆ Set(Symbol.(names(table))) || error("Neighbour continuation file has no recognised columns.")
    tasks = NamedTuple[]
    for rows in groupby(table, :sensitivity_profile)
        accepted = rows[coalesce.(rows.solver_valid, false), :]
        isempty(accepted) && continue
        row = accepted[1, :]
        push!(tasks, (
            target = Symbol(row.sensitivity_profile), stage = :neighbor,
            source = Symbol(row.source_profile), parameter = String(row.changed_parameter),
            accepted_fractions = Float64[],
        ))
    end
    return tasks
end

function parameter_key(label::AbstractString)
    pieces = split(label, ".")
    length(pieces) == 2 || error("Continuation parameter label $(label) is invalid.")
    return (String(pieces[1]), String(pieces[2]))
end

function intermediate_profile(source::CERiseCGE.SensitivityProfile,
    target::CERiseCGE.SensitivityProfile, key::Tuple{String,String}, fraction::Real)
    values = copy(source.values)
    values[key] = source.values[key] + fraction * (target.values[key] - source.values[key])
    return CERiseCGE.SensitivityProfile(
        Symbol("replay_", target.name),
        "Temporary replay point for an accepted continuation path.", values)
end

function profile_bundle(profile, bundle)
    local_bundle = CERiseCGE.sensitivity_bundle(profile; bundle = bundle)
    calibration = CERiseCGE.multi_region_calibration(local_bundle)
    return (bundle = local_bundle, calibration = calibration)
end

function baseline_solution(profile, bundle)
    prepared = profile_bundle(profile, bundle)
    model = CERiseCGE.multi_region_model(; bundle = prepared.bundle, calibration = prepared.calibration)
    result = CERiseCGE.run_baseline(model)
    CERiseCGE._valid_policy_solution(result) || error("Baseline for $(profile.name) is not valid.")
    return (model = model, result = result)
end

function tax_model(profile, bundle, wedge::Real)
    prepared = profile_bundle(profile, bundle)
    scenario = CERiseCGE.eu_wide_policy_scenario(:virgin_metal_tax, wedge;
        bundle = prepared.bundle)
    return CERiseCGE.multi_region_model(; bundle = prepared.bundle,
        calibration = prepared.calibration, scenario = scenario)
end

function source_tax_solution(profile, bundle)
    baseline = baseline_solution(profile, bundle)
    prepared = profile_bundle(profile, bundle)
    records = CERiseCGE._run_declared_policy_points(
        CERiseCGE.policy_sweep_models(:virgin_metal_tax;
            bundle = prepared.bundle, calibration = prepared.calibration);
        baseline_start_values = CERiseCGE.solution_start_values(baseline.result))
    endpoint = only(filter(record -> CERiseCGE.policy_wedge(record.model.scenario,
        :virgin_metal_tax) == TAX_WEDGE, records))
    endpoint.solver_valid || error("Source profile $(profile.name) has no valid 2% tax path.")
    return endpoint.result
end

function predictor_starts(result, prior_starts::AbstractDict{Symbol,<:Real}, fraction::Real)
    starts = CERiseCGE.solution_start_values(result)
    predicted = Dict{Symbol,Float64}()
    for (name, value) in starts
        prior = get(prior_starts, name, value)
        candidate = value + fraction * (value - prior)
        variable = result.context.variables[name]
        JuMP.has_lower_bound(variable) && (candidate = max(candidate, JuMP.lower_bound(variable)))
        JuMP.has_upper_bound(variable) && (candidate = min(candidate, JuMP.upper_bound(variable)))
        isfinite(candidate) || error("Predictor start $(name) is not finite.")
        predicted[name] = candidate
    end
    return predicted
end

function predictor_endpoint(profile, bundle)
    baseline = baseline_solution(profile, bundle)
    prepared = profile_bundle(profile, bundle)
    models = CERiseCGE.policy_sweep_models(:virgin_metal_tax;
        bundle = prepared.bundle, calibration = prepared.calibration)
    source_strength = 0.0
    source_result = baseline.result
    source_starts = CERiseCGE.solution_start_values(source_result)
    prior_strength = nothing
    prior_starts = nothing
    for model in models
        target_strength = abs(CERiseCGE.policy_wedge(model.scenario, :virgin_metal_tax))
        direct = CERiseCGE.run_policy_scenario(model; start_values = source_starts)
        if CERiseCGE._valid_policy_solution(direct)
            prior_strength, prior_starts = source_strength, source_starts
            source_strength, source_result = target_strength, direct
            source_starts = CERiseCGE.solution_start_values(direct)
            target_strength == TAX_WEDGE && return (model = model, result = direct)
            continue
        end
        configuration = CERiseCGE.solver_configuration(model)
        current_strength, current_result, starts = source_strength, source_result, source_starts
        step = (target_strength - current_strength) / 2.0
        accepted_target = false
        attempts = 1
        while attempts < configuration.policy_continuation_max_attempts &&
              step >= configuration.policy_continuation_minimum_increment
            trial_strength = min(target_strength, current_strength + step)
            trial_model = isapprox(trial_strength, target_strength; atol = eps(target_strength), rtol = 0.0) ?
                model : CERiseCGE._policy_continuation_model(model, :virgin_metal_tax, trial_strength)
            trial = CERiseCGE.run_policy_scenario(trial_model; start_values = starts)
            attempts += 1
            if CERiseCGE._valid_policy_solution(trial)
                prior_strength, prior_starts = current_strength, starts
                current_strength, current_result = trial_strength, trial
                starts = CERiseCGE.solution_start_values(trial)
                if isapprox(current_strength, target_strength; atol = eps(target_strength), rtol = 0.0)
                    accepted_target = true
                    source_strength, source_result, source_starts = current_strength, current_result, starts
                    break
                end
                step = min(target_strength - current_strength, 2.0 * step)
            else
                step /= 2.0
            end
        end
        if !accepted_target && prior_strength !== nothing && prior_starts !== nothing &&
           current_strength > prior_strength
            fraction = (target_strength - current_strength) / (current_strength - prior_strength)
            predicted = CERiseCGE.run_policy_scenario(model;
                start_values = predictor_starts(current_result, prior_starts, fraction))
            if CERiseCGE._valid_policy_solution(predicted)
                source_strength, source_result = target_strength, predicted
                source_starts = CERiseCGE.solution_start_values(predicted)
                target_strength == TAX_WEDGE && return (model = model, result = predicted)
            end
        end
    end
    error("Predictor replay did not recover $(profile.name) at 2% tax.")
end

function replay_parameter_continuation(task, target, source, bundle; diagonal::Bool)
    key = parameter_key(task.parameter)
    initial = diagonal ? baseline_solution(source, bundle).result : source_tax_solution(source, bundle)
    current = initial
    endpoint_model = nothing
    for fraction in task.accepted_fractions
        profile = intermediate_profile(source, target, key, fraction)
        wedge = diagonal ? TAX_WEDGE * fraction : TAX_WEDGE
        model = tax_model(profile, bundle, wedge)
        result = CERiseCGE.run_policy_scenario(model;
            start_values = CERiseCGE.solution_start_values(current))
        CERiseCGE._valid_policy_solution(result) ||
            error("Could not replay accepted continuation fraction $(fraction) for $(target.name).")
        current, endpoint_model = result, model
    end
    endpoint_model === nothing && error("No accepted continuation endpoint was recorded for $(target.name).")
    return (model = endpoint_model, result = current)
end

function replay_task(task)
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    target = profiles[task.target]
    baseline = baseline_solution(target, bundle)
    endpoint = if task.stage === :predictor
        predictor_endpoint(target, bundle)
    elseif task.stage === :neighbor
        source = profiles[task.source]
        model = tax_model(target, bundle, TAX_WEDGE)
        result = CERiseCGE.run_policy_scenario(model;
            start_values = CERiseCGE.solution_start_values(source_tax_solution(source, bundle)))
        CERiseCGE._valid_policy_solution(result) || error("Neighbour replay did not recover $(target.name).")
        (model = model, result = result)
    elseif task.stage in (:bisection, :fine)
        replay_parameter_continuation(task, target, profiles[task.source], bundle; diagonal = false)
    elseif task.stage === :diagonal
        replay_parameter_continuation(task, target, profiles[task.source], bundle; diagonal = true)
    else
        error("Unknown recovery stage $(task.stage).")
    end
    summary = CERiseCGE.policy_sweep_summary(baseline.result, baseline.model, [endpoint])
    nrow(summary) == 1 || error("Recovered endpoint summary must contain one row.")
    summary.sensitivity_profile = [target.name]
    for (component, key) in CERiseCGE.SENSITIVITY_PARAMETER_KEYS
        summary[!, Symbol(key)] = [target.values[(component, key)]]
    end
    summary.solver_valid = [true]
    summary.solver_message = [missing]
    summary.solver_elapsed_seconds = [missing]
    summary.profile_elapsed_seconds = [missing]
    summary.solver_attempts = [missing]
    summary.recovery_stage = [String(task.stage)]
    return summary
end

function start_workers(worker_count::Integer)
    worker_count == 1 && return nothing
    project_file = Base.active_project()
    project_file === nothing && error("The replay must be launched with --project=.")
    workers = addprocs(worker_count;
        exeflags = "--project=$(dirname(project_file))",
        env = Dict("CE_RISE_MATERIALIZE_RECOVERIES_WORKER" => "true"))
    script_path = abspath(@__FILE__)
    for worker in workers
        remotecall_wait(Base.include, worker, Main, script_path)
    end
    return workers
end

function main()
    options = command_options(ARGS)
    output_dir = checkpoint_dir(options.output)
    task_sets = (
        predictor_tasks(options.predictor),
        neighbor_tasks(options.neighbor),
        one_continuation_task(options.bisection, :bisection),
        one_continuation_task(options.fine, :fine),
        one_continuation_task(options.diagonal, :diagonal),
    )
    tasks = NamedTuple[]
    for task_set in task_sets
        append!(tasks, task_set)
    end
    targets = Symbol[task.target for task in tasks]
    length(unique(targets)) == length(targets) || error("Recovery stages overlap in target profiles.")
    tasks = [merge(task, (
        output_path = joinpath(output_dir, "$(task.target).csv"),
    )) for task in tasks]
    pending = filter(task -> !isfile(task.output_path), tasks)
    println("Recovered target profiles: ", length(tasks))
    println("Completed recovery summaries: ", length(tasks) - length(pending))
    println("Pending recovery summaries: ", length(pending))
    println("Workers: ", options.workers)
    if options.dry_run
        println("Dry run completed; no results were written.")
        return nothing
    end
    mkpath(output_dir)
    start_workers(options.workers)
    runner = task -> begin
        table = replay_task(task)
        CERiseCGE._write_atomic_csv(task.output_path, table)
        return task.target
    end
    isempty(pending) || (options.workers == 1 ? map(runner, pending) : pmap(runner, pending))
    recovered = vcat([CSV.read(task.output_path, DataFrame) for task in tasks]...; cols = :union)
    grid = CSV.read(options.grid, DataFrame)
    grid.recovery_stage = [row.solver_valid ? "declared_policy_path" : "unresolved" for row in eachrow(grid)]
    recovered_targets = Set(String.(recovered.sensitivity_profile))
    retained = grid[.!((String.(grid.instrument) .== "virgin_metal_tax") .&
        (grid.wedge .== TAX_WEDGE) .& in.(String.(grid.sensitivity_profile), Ref(recovered_targets))), :]
    final = vcat(retained, recovered; cols = :union)
    sort!(final, [:sensitivity_profile, :instrument, :wedge])
    nrow(final) == nrow(grid) || error("Final table has $(nrow(final)) rows; expected $(nrow(grid)).")
    count(coalesce.(final.solver_valid, false)) == 14_570 ||
        error("Final table does not contain the expected 14,570 valid solutions.")
    CERiseCGE._write_atomic_csv(options.output, final)
    println("Wrote ", nrow(final), " rows with ", count(coalesce.(final.solver_valid, false)),
        " validated solutions to ", options.output)
end

end

if (abspath(PROGRAM_FILE) == @__FILE__) &&
   get(ENV, "CE_RISE_MATERIALIZE_RECOVERIES_WORKER", "false") != "true"
    MaterializeRecoveredPolicyResults.main()
end
