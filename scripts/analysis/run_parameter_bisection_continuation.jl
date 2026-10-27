#!/usr/bin/env julia

"""
Use adaptive bisection in one sensitivity parameter for any policy instrument
and declared wedge. Each target starts from a previously tested solved
neighbour; intermediate parameter values are numerical continuation points and
are not part of the reported sensitivity design.
"""

module ParameterBisectionContinuation

using CSV
using DataFrames
using Distributed
using JuMP
using CERiseCGE
include(joinpath(@__DIR__, "policy_recovery.jl"))
using .PolicyRecovery: point_key, point_file, accepted_points, declared_key,
    policy_model, source_policy_start, source_baseline_start, checkpoint_complete

include(joinpath(@__DIR__, "recovered_policy_summary.jl"))
using .RecoveredPolicySummary
include(joinpath(@__DIR__, "recovered_policy_outcome.jl"))
using .RecoveredPolicyOutcome

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_INPUT_FILE = joinpath(ROOT_DIR, "results", "parameter_neighbor.csv")
const DEFAULT_OUTPUT_FILE = joinpath(ROOT_DIR, "results", "parameter_bisection.csv")
const DEFAULT_WORKERS = 10
const DEFAULT_MINIMUM_FRACTION_INCREMENT = 1.0 / 1024.0
const MAXIMUM_ATTEMPTS = 60

function command_options(args)
    input_file = DEFAULT_INPUT_FILE
    output_file = DEFAULT_OUTPUT_FILE
    summary_dir = nothing
    outcome_dir = nothing
    baseline_dir = nothing
    remaining_from = nothing
    minimum_fraction_increment = DEFAULT_MINIMUM_FRACTION_INCREMENT
    continuation_path = :parameter_only
    workers = DEFAULT_WORKERS
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--input" && index < length(args)
            input_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--output" && index < length(args)
            output_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--summary-dir" && index < length(args)
            summary_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--outcome-dir" && index < length(args)
            outcome_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--baseline-dir" && index < length(args)
            baseline_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--remaining-from" && index < length(args)
            remaining_from = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--minimum-fraction-increment" && index < length(args)
            minimum_fraction_increment = parse(Float64, args[index + 1])
            0.0 < minimum_fraction_increment <= 1.0 ||
                error("--minimum-fraction-increment must be in (0, 1].")
            index += 2
        elseif args[index] == "--continuation-path" && index < length(args)
            continuation_path = Symbol(args[index + 1])
            continuation_path in (:parameter_only, :diagonal_policy_parameter) ||
                error("--continuation-path must be parameter_only or diagonal_policy_parameter.")
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/run_parameter_bisection_continuation.jl " *
                "[--input PATH] [--output PATH] [--summary-dir PATH] [--remaining-from PATH] " *
                "[--outcome-dir PATH] [--baseline-dir PATH] [--minimum-fraction-increment VALUE] " *
                "[--continuation-path parameter_only|diagonal_policy_parameter] " *
                "[--workers N] [--dry-run]")
        end
    end
    return (input_file = input_file, output_file = output_file,
        summary_dir = summary_dir, outcome_dir = outcome_dir,
        remaining_from = remaining_from,
        minimum_fraction_increment = minimum_fraction_increment,
        continuation_path = continuation_path,
        baseline_dir=baseline_dir, workers = workers, dry_run = dry_run)
end

checkpoint_dir(output_file::AbstractString) = joinpath(dirname(output_file),
    "$(splitext(basename(output_file))[1])_checkpoints")

function unresolved_endpoint_points(path::AbstractString)
    isfile(path) || error("Previous parameter-bisection results are missing: $(path)")
    table = CSV.read(path, DataFrame)
    required = Set([:sensitivity_profile, :instrument, :wedge, :trial_fraction, :trial_accepted])
    required ⊆ Set(Symbol.(names(table))) ||
        error("Previous parameter-bisection results have no recognised endpoint columns.")
    targets = Set(declared_key(row) for row in eachrow(table))
    return setdiff(targets, accepted_points(table))
end

function choose_tasks(input_file::AbstractString, directory::AbstractString;
    remaining_from::Union{Nothing,AbstractString}=nothing,
    minimum_fraction_increment::Real=DEFAULT_MINIMUM_FRACTION_INCREMENT,
    continuation_path::Symbol=:parameter_only,
    summary_dir::Union{Nothing,AbstractString}=nothing)
    isfile(input_file) || error("Parameter-neighbour results are missing: $(input_file)")
    table = CSV.read(input_file, DataFrame)
    required = Set([:sensitivity_profile, :instrument, :wedge, :source_profile, :changed_parameter,
        :parameter_distance, :solver_valid, :max_scaled_residual])
    required ⊆ Set(Symbol.(names(table))) || error("Input has no recognised continuation columns.")
    selected = isnothing(remaining_from) ? nothing : unresolved_endpoint_points(remaining_from)
    tasks = NamedTuple[]
    for group in groupby(table, [:sensitivity_profile, :instrument, :wedge])
        any(coalesce.(group.solver_valid, false)) && continue
        row = first(eachrow(group))
        selected === nothing || point_key(row) in selected || continue
        attempts = filter(item -> !ismissing(item.source_profile) && !ismissing(item.changed_parameter),
            eachrow(group))
        finite = filter(item -> !ismissing(item.max_scaled_residual) &&
            isfinite(item.max_scaled_residual), attempts)
        candidates = isempty(finite) ? collect(attempts) : collect(finite)
        sort!(candidates; by = item -> (
            ismissing(item.max_scaled_residual) ? Inf : item.max_scaled_residual,
            item.parameter_distance, String(item.source_profile)))
        sources = NamedTuple[]
        seen = Set{Tuple{Symbol,String}}()
        for candidate in candidates
            source_name = Symbol(candidate.source_profile)
            parameter = String(candidate.changed_parameter)
            identifier = (source_name, parameter)
            identifier in seen && continue
            push!(seen, identifier)
            push!(sources, (
                profile = source_name,
                parameter = parameter,
            ))
        end
        push!(tasks, (
            target = Symbol(row.sensitivity_profile),
            instrument = Symbol(row.instrument),
            wedge = Float64(row.wedge),
            sources = sources,
            minimum_fraction_increment = Float64(minimum_fraction_increment),
            continuation_path = continuation_path,
            output_path = point_file(directory, point_key(row)...),
            summary_path = isnothing(summary_dir) ? nothing :
                point_file(summary_dir, point_key(row)...),
        ))
    end
    sort!(tasks; by = item -> (String(item.target), String(item.instrument), item.wedge))
    return tasks
end

function summary_stage(task)
    task.continuation_path === :diagonal_policy_parameter && return :diagonal
    task.minimum_fraction_increment < DEFAULT_MINIMUM_FRACTION_INCREMENT && return :fine
    return :bisection
end

function parameter_key(label::AbstractString)
    pieces = split(label, ".")
    length(pieces) == 2 || error("Continuation parameter label $(label) is invalid.")
    return (String(pieces[1]), String(pieces[2]))
end

function intermediate_profile(source::CERiseCGE.SensitivityProfile,
    target::CERiseCGE.SensitivityProfile, key::Tuple{String,String}, fraction::Real)
    0.0 <= fraction <= 1.0 || error("Parameter-continuation fraction must be in [0, 1].")
    values = copy(source.values)
    values[key] = source.values[key] + fraction * (target.values[key] - source.values[key])
    return CERiseCGE.SensitivityProfile(
        Symbol("continuation_", target.name),
        "Numerical parameter-continuation point for $(target.name).",
        values,
    )
end

function trace_row(target, source, key, fraction::Real, phase::Symbol, attempt::Integer,
    model, result, elapsed_seconds::Real, continuation_path::Symbol, instrument::Symbol, declared_wedge::Real)
    trial_value = source.values[key] + fraction * (target.values[key] - source.values[key])
    scenario = model.scenario
    row = CERiseCGE._solvability_diagnostic_row(target, :policy, scenario.name,
        instrument, CERiseCGE.policy_wedge(scenario, instrument),
        result, elapsed_seconds)
    return merge(row, (
        target_profile = target.name,
        declared_wedge = Float64(declared_wedge),
        source_profile = source.name,
        continued_parameter = "$(first(key)).$(last(key))",
        source_parameter_value = source.values[key],
        target_parameter_value = target.values[key],
        trial_fraction = Float64(fraction),
        trial_parameter_value = trial_value,
        continuation_phase = phase,
        continuation_path = continuation_path,
        attempt = Int(attempt),
        trial_accepted = CERiseCGE._valid_policy_solution(result),
    ))
end

function trace_task(task)
    checkpoint_complete(task.output_path, [point_key(task.target, task.instrument, task.wedge)],
        isnothing(task.summary_path) ? nothing : dirname(task.summary_path),
        isnothing(task.outcome_path) ? nothing : dirname(task.outcome_path);
        baseline_dir=get(task, :baseline_dir, nothing)) &&
        return (target = task.target, state = :skipped)
    mkpath(dirname(task.output_path))
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    target = profiles[task.target]
    try
        source = nothing
        key = nothing
        source_run = nothing
        source_errors = String[]
        for candidate in task.sources
            candidate_source = profiles[candidate.profile]
            try
                candidate_run = task.continuation_path === :parameter_only ?
                    source_policy_start(candidate_source, bundle, task.instrument, task.wedge;
                        baseline_dir=get(task, :baseline_dir, nothing)) :
                    source_baseline_start(candidate_source, bundle; baseline_dir=get(task, :baseline_dir, nothing))
                if candidate_run.baseline_valid && candidate_run.policy_valid
                    source = candidate_source
                    key = parameter_key(candidate.parameter)
                    source_run = candidate_run
                    break
                end
                push!(source_errors, "$(candidate.profile): no reproducible valid source path")
            catch err
                err isa InterruptException && rethrow()
                push!(source_errors, "$(candidate.profile): $(sprint(showerror, err))")
            end
        end
        source === nothing && error("No neighbouring source could be re-solved (" *
            join(source_errors, "; ") * ").")
        rows = NamedTuple[]
        current_fraction = 0.0
        current_starts = source_run.starts
        attempts = 0
        direct_model = policy_model(target, bundle, task.instrument, task.wedge)
        direct_elapsed = @elapsed direct = CERiseCGE.run_policy_scenario(direct_model;
            start_values = current_starts)
        attempts += 1
        push!(rows, trace_row(target, source, key, 1.0, :direct_target, attempts,
            direct_model, direct, direct_elapsed, task.continuation_path, task.instrument, task.wedge))
        if CERiseCGE._valid_policy_solution(direct)
            !isnothing(task.summary_path) &&
                RecoveredPolicySummary.write_summary(task.summary_path, target, bundle,
                    direct_model, direct, summary_stage(task); baseline_dir=get(task, :baseline_dir, nothing))
            !isnothing(task.outcome_path) &&
                RecoveredPolicyOutcome.write_outcome(task.outcome_path, target, bundle,
                    direct_model, direct; baseline_dir=get(task, :baseline_dir, nothing))
            CERiseCGE._write_atomic_csv(task.output_path, DataFrame(rows))
            return (target = task.target, state = :recovered)
        end
        step = 0.5
        while attempts < MAXIMUM_ATTEMPTS && step >= task.minimum_fraction_increment
            trial_fraction = min(1.0, current_fraction + step)
            profile = intermediate_profile(source, target, key, trial_fraction)
            wedge = task.continuation_path === :parameter_only ? task.wedge :
                task.wedge * trial_fraction
            model = policy_model(profile, bundle, task.instrument, wedge)
            elapsed = @elapsed result = CERiseCGE.run_policy_scenario(model;
                start_values = current_starts)
            attempts += 1
            push!(rows, trace_row(target, source, key, trial_fraction,
                :parameter_bisection, attempts, model, result, elapsed,
                task.continuation_path, task.instrument, task.wedge))
            if CERiseCGE._valid_policy_solution(result)
                current_fraction = trial_fraction
                current_starts = CERiseCGE.solution_start_values(result)
                if isapprox(current_fraction, 1.0; atol = eps(1.0), rtol = 0.0)
                    !isnothing(task.summary_path) &&
                        RecoveredPolicySummary.write_summary(task.summary_path, target, bundle,
                            model, result, summary_stage(task); baseline_dir=get(task, :baseline_dir, nothing))
                    !isnothing(task.outcome_path) &&
                        RecoveredPolicyOutcome.write_outcome(task.outcome_path, target, bundle,
                            model, result; baseline_dir=get(task, :baseline_dir, nothing))
                    break
                end
                step = min(1.0 - current_fraction, 2.0 * step)
            else
                step /= 2.0
            end
        end
        CERiseCGE._write_atomic_csv(task.output_path, DataFrame(rows))
        return (target = task.target, state = :completed)
    catch err
        err isa InterruptException && rethrow()
        row = CERiseCGE._solvability_failure_row(target, :policy,
            CERiseCGE.eu_wide_policy_scenario(task.instrument, task.wedge).name,
            task.instrument, task.wedge, err)
        row = merge(row, (target_profile=target.name, declared_wedge=task.wedge,
            trial_fraction=missing, trial_accepted=false))
        CERiseCGE._write_atomic_csv(task.output_path, DataFrame([row]))
        return (target = task.target, state = :error)
    end
end

function start_workers(worker_count::Integer)
    worker_count == 1 && return nothing
    project_file = Base.active_project()
    project_file === nothing && error("The diagnostic must be launched with --project=.")
    workers = addprocs(worker_count;
        exeflags = "--project=$(dirname(project_file))",
        env = Dict("CE_RISE_PARAMETER_BISECTION_WORKER" => "true"))
    script_path = abspath(@__FILE__)
    for worker in workers
        remotecall_wait(Base.include, worker, Main, script_path)
    end
    return workers
end

function main()
    options = command_options(ARGS)
    directory = checkpoint_dir(options.output_file)
    tasks = choose_tasks(options.input_file, directory;
        remaining_from = options.remaining_from,
        minimum_fraction_increment = options.minimum_fraction_increment,
        continuation_path = options.continuation_path,
        summary_dir = options.summary_dir)
    tasks = [merge(task, (baseline_dir=options.baseline_dir, outcome_path = isnothing(options.outcome_dir) ? nothing :
        point_file(options.outcome_dir, task.target, task.instrument, task.wedge),)) for task in tasks]
    pending = filter(task -> !checkpoint_complete(task.output_path,
        [point_key(task.target, task.instrument, task.wedge)], options.summary_dir, options.outcome_dir;
        baseline_dir=options.baseline_dir), tasks)
    println("Remaining policy points: ", length(tasks))
    println("Completed checkpoints: ", length(tasks) - length(pending))
    println("Pending policy points: ", length(pending))
    println("Workers: ", options.workers)
    println("Checkpoint directory: ", directory)
    flush(stdout)
    if options.dry_run
        println("Dry run completed; no diagnostics were written.")
        return nothing
    end
    mkpath(directory)
    if !isempty(pending)
        start_workers(options.workers)
        options.workers == 1 ? map(trace_task, pending) : pmap(trace_task, pending)
    end
    combined = PolicyRecovery.combine_checkpoints([task.output_path for task in tasks], options.output_file)
    println("Wrote ", nrow(combined), " parameter-bisection rows to ", options.output_file)
end

end

if (abspath(PROGRAM_FILE) == @__FILE__) &&
   get(ENV, "CE_RISE_PARAMETER_BISECTION_WORKER", "false") != "true"
    ParameterBisectionContinuation.main()
end
