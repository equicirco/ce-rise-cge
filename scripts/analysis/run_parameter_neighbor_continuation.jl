#!/usr/bin/env julia

"""
Attempt remaining 2% virgin-metal-tax failures from adjacent solved sensitivity
profiles. A neighbour differs in exactly one sensitivity parameter, so this is
continuation in parameter space rather than a change in model equations or in
the reported policy point.
"""

module ParameterNeighborContinuation

using CSV
using DataFrames
using Distributed
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_GRID_FILE = joinpath(ROOT_DIR, "results", "multi_region",
    "policy_sensitivity", "policy_sensitivity_grid_it_other_services.csv")
const DEFAULT_PREDICTOR_FILE = joinpath(ROOT_DIR, "results", "multi_region",
    "solvability_it_other_services_tax_predictor_trace.csv")
const DEFAULT_OUTPUT_FILE = joinpath(ROOT_DIR, "results", "multi_region",
    "parameter_neighbor_tax_continuation.csv")
const DEFAULT_WORKERS = 10
const TAX_WEDGE = 0.02

function command_options(args)
    grid_file = DEFAULT_GRID_FILE
    predictor_file = DEFAULT_PREDICTOR_FILE
    output_file = DEFAULT_OUTPUT_FILE
    workers = DEFAULT_WORKERS
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--grid" && index < length(args)
            grid_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--predictor" && index < length(args)
            predictor_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--output" && index < length(args)
            output_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/run_parameter_neighbor_continuation.jl " *
                "[--grid PATH] [--predictor PATH] [--output PATH] [--workers N] [--dry-run]")
        end
    end
    return (grid_file = grid_file, predictor_file = predictor_file,
        output_file = output_file, workers = workers, dry_run = dry_run)
end

checkpoint_dir(output_file::AbstractString) = joinpath(dirname(output_file),
    "$(splitext(basename(output_file))[1])_checkpoints")

function recovered_predictor_profiles(path::AbstractString)
    isfile(path) || return Set{Symbol}()
    trace = CSV.read(path, DataFrame)
    return Set(Symbol(row.sensitivity_profile) for row in eachrow(trace)
        if String(row.continuation_phase) == "predictor_target" && row.trial_accepted)
end

function profile_difference(target, source)
    parameter_keys = sort!(collect(keys(target.values)); by = item -> join(string.(item), "|"))
    changed = [key for key in parameter_keys if target.values[key] != source.values[key]]
    distance = sum(abs(log(target.values[key] / source.values[key])) for key in changed)
    return (count = length(changed), keys = changed, distance = distance)
end

function parameter_label(keys)
    isempty(keys) && return missing
    return join(["$(first(key)).$(last(key))" for key in keys], "|")
end

function continuation_tasks(grid_file::AbstractString, predictor_file::AbstractString,
    directory::AbstractString)
    isfile(grid_file) || error("Completed policy grid is missing: $(grid_file)")
    grid = CSV.read(grid_file, DataFrame)
    required = Set([:sensitivity_profile, :instrument, :wedge, :solver_valid])
    required ⊆ Set(Symbol.(names(grid))) || error("Policy grid has no recognised columns.")
    tax = filter(row -> String(row.instrument) == "virgin_metal_tax" &&
        row.wedge == TAX_WEDGE, eachrow(grid))
    valid = Set(Symbol(row.sensitivity_profile) for row in tax if row.solver_valid)
    recovered = recovered_predictor_profiles(predictor_file)
    remaining = sort!(collect(setdiff(
        Set(Symbol(row.sensitivity_profile) for row in tax if !row.solver_valid),
        recovered)); by = String)
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    all(haskey(profiles, name) for name in union(valid, Set(remaining))) ||
        error("A grid sensitivity profile is not available from the current calibration bundle.")
    tasks = NamedTuple[]
    for target_name in remaining
        target = profiles[target_name]
        candidates = NamedTuple[]
        for source_name in valid
            source = profiles[source_name]
            difference = profile_difference(target, source)
            difference.count == 1 || continue
            push!(candidates, (
                profile = source_name,
                parameter = parameter_label(difference.keys),
                distance = difference.distance,
            ))
        end
        sort!(candidates; by = item -> (item.distance, String(item.parameter), String(item.profile)))
        isempty(candidates) && error("No adjacent valid 2% tax profile is available for $(target_name).")
        push!(tasks, (
            target = target_name,
            candidates = candidates,
            output_path = joinpath(directory, "$(target_name).csv"),
        ))
    end
    return tasks
end

function result_row(target, source, parameter, distance, result, elapsed_seconds;
    source_baseline_valid::Union{Missing,Bool}=missing,
    source_tax_valid::Union{Missing,Bool}=missing,
    error_message::Union{Missing,String}=missing)
    row = CERiseCGE._solvability_diagnostic_row(target, :policy,
        :virgin_metal_tax_0_02, :virgin_metal_tax, TAX_WEDGE, result, elapsed_seconds)
    return merge(row, (
        source_profile = source,
        changed_parameter = parameter,
        parameter_distance = distance,
        source_baseline_valid = source_baseline_valid,
        source_tax_valid = source_tax_valid,
        continuation_error = error_message,
    ))
end

function failure_row(target, source, parameter, distance, error_message::String)
    row = CERiseCGE._solvability_failure_row(target, :policy,
        :virgin_metal_tax_0_02, :virgin_metal_tax, TAX_WEDGE,
        ErrorException(error_message))
    return merge(row, (
        source_profile = source,
        changed_parameter = parameter,
        parameter_distance = distance,
        source_baseline_valid = missing,
        source_tax_valid = missing,
        continuation_error = error_message,
    ))
end

function target_model(profile, bundle)
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle = bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    scenario = CERiseCGE.eu_wide_policy_scenario(:virgin_metal_tax, TAX_WEDGE;
        bundle = profile_bundle)
    return CERiseCGE.multi_region_model(; bundle = profile_bundle,
        calibration = calibration, scenario = scenario)
end

function source_tax_solution(profile, bundle)
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle = bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    baseline_model = CERiseCGE.multi_region_model(; bundle = profile_bundle,
        calibration = calibration)
    baseline = CERiseCGE.run_baseline(baseline_model)
    CERiseCGE._valid_policy_solution(baseline) || return (baseline = baseline, policy = nothing)
    models = CERiseCGE.policy_sweep_models(:virgin_metal_tax;
        bundle = profile_bundle, calibration = calibration)
    runs = CERiseCGE.run_policy_path(models;
        start_values = CERiseCGE.solution_start_values(baseline))
    policy = only(filter(run -> CERiseCGE.policy_wedge(run.model.scenario,
        :virgin_metal_tax) == TAX_WEDGE, runs)).result
    return (baseline = baseline, policy = policy)
end

function run_task(task)
    isfile(task.output_path) && return (target = task.target, state = :skipped)
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    target = profiles[task.target]
    model = target_model(target, bundle)
    rows = NamedTuple[]
    for candidate in task.candidates
        source = profiles[candidate.profile]
        try
            source_run = source_tax_solution(source, bundle)
            baseline_valid = CERiseCGE._valid_policy_solution(source_run.baseline)
            if !baseline_valid || source_run.policy === nothing
                push!(rows, failure_row(target, candidate.profile, candidate.parameter,
                    candidate.distance, "Source profile has no valid baseline or tax path."))
                continue
            end
            source_valid = CERiseCGE._valid_policy_solution(source_run.policy)
            if !source_valid
                push!(rows, failure_row(target, candidate.profile, candidate.parameter,
                    candidate.distance, "Source profile has no valid 2% tax solution."))
                continue
            end
            elapsed = @elapsed result = CERiseCGE.run_policy_scenario(model;
                start_values = CERiseCGE.solution_start_values(source_run.policy))
            row = result_row(target, candidate.profile, candidate.parameter,
                candidate.distance, result, elapsed;
                source_baseline_valid = baseline_valid,
                source_tax_valid = source_valid)
            push!(rows, row)
            row.solver_valid && break
        catch err
            push!(rows, failure_row(target, candidate.profile, candidate.parameter,
                candidate.distance, sprint(showerror, err)))
        end
    end
    CERiseCGE._write_atomic_csv(task.output_path, DataFrame(rows))
    return (target = task.target, state = :completed)
end

function start_workers(worker_count::Integer)
    worker_count == 1 && return nothing
    project_file = Base.active_project()
    project_file === nothing && error("The diagnostic must be launched with --project=.")
    workers = addprocs(worker_count;
        exeflags = "--project=$(dirname(project_file))",
        env = Dict("CE_RISE_NEIGHBOR_WORKER" => "true"))
    script_path = abspath(@__FILE__)
    for worker in workers
        remotecall_wait(Base.include, worker, Main, script_path)
    end
    return workers
end

function main()
    options = command_options(ARGS)
    directory = checkpoint_dir(options.output_file)
    tasks = continuation_tasks(options.grid_file, options.predictor_file, directory)
    pending = filter(task -> !isfile(task.output_path), tasks)
    println("Remaining tax profiles: ", length(tasks))
    println("Completed checkpoints: ", length(tasks) - length(pending))
    println("Pending profiles: ", length(pending))
    println("Checkpoint directory: ", directory)
    flush(stdout)
    if options.dry_run
        println("Dry run completed; no diagnostics were written.")
        return nothing
    end
    mkpath(directory)
    start_workers(options.workers)
    isempty(pending) || (options.workers == 1 ? map(run_task, pending) : pmap(run_task, pending))
    tables = DataFrame[CSV.read(task.output_path, DataFrame) for task in tasks]
    combined = vcat(tables...; cols = :union)
    CERiseCGE._write_atomic_csv(options.output_file, combined)
    println("Wrote ", nrow(combined), " continuation attempts to ", options.output_file)
end

end

if (abspath(PROGRAM_FILE) == @__FILE__) &&
   get(ENV, "CE_RISE_NEIGHBOR_WORKER", "false") != "true"
    ParameterNeighborContinuation.main()
end
