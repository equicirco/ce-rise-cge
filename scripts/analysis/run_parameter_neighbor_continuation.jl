#!/usr/bin/env julia

"""
Attempt remaining policy failures from adjacent solved sensitivity profiles at
the same instrument and wedge. A neighbour differs in exactly one parameter, so this is
continuation in parameter space rather than a change in model equations or in
the reported policy point.
"""

module ParameterNeighborContinuation

using CSV
using DataFrames
using Distributed
using CERiseCGE
include(joinpath(@__DIR__, "policy_recovery.jl"))
using .PolicyRecovery: point_key, point_file, accepted_points, policy_model,
    source_policy_start, checkpoint_complete

include(joinpath(@__DIR__, "recovered_policy_summary.jl"))
using .RecoveredPolicySummary
include(joinpath(@__DIR__, "recovered_policy_outcome.jl"))
using .RecoveredPolicyOutcome

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_GRID_FILE = joinpath(ROOT_DIR, "results", "policy_sensitivity_grid.csv")
const DEFAULT_PREDICTOR_FILE = joinpath(ROOT_DIR, "results", "predictor_trace.csv")
const DEFAULT_OUTPUT_FILE = joinpath(ROOT_DIR, "results", "parameter_neighbor.csv")
const DEFAULT_WORKERS = 10

function command_options(args)
    grid_file = DEFAULT_GRID_FILE
    predictor_file = DEFAULT_PREDICTOR_FILE
    output_file = DEFAULT_OUTPUT_FILE
    summary_dir = nothing
    outcome_dir = nothing
    baseline_dir = nothing
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
        elseif args[index] == "--summary-dir" && index < length(args)
            summary_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--outcome-dir" && index < length(args)
            outcome_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--baseline-dir" && index < length(args)
            baseline_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
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
                "[--grid PATH] [--predictor PATH] [--output PATH] [--summary-dir PATH] " *
                "[--outcome-dir PATH] [--baseline-dir PATH] [--workers N] [--dry-run]")
        end
    end
    return (grid_file = grid_file, predictor_file = predictor_file,
        output_file = output_file, summary_dir = summary_dir, outcome_dir = outcome_dir,
        baseline_dir=baseline_dir, workers = workers, dry_run = dry_run)
end

checkpoint_dir(output_file::AbstractString) = joinpath(dirname(output_file),
    "$(splitext(basename(output_file))[1])_checkpoints")

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
    directory::AbstractString; summary_dir::Union{Nothing,AbstractString}=nothing, baseline_dir=nothing)
    isfile(grid_file) || error("Completed policy grid is missing: $(grid_file)")
    grid = CSV.read(grid_file, DataFrame)
    required = Set([:sensitivity_profile, :instrument, :wedge, :solver_valid])
    required ⊆ Set(Symbol.(names(grid))) || error("Policy grid has no recognised columns.")
    valid = Set(point_key(row) for row in eachrow(grid) if coalesce(row.solver_valid, false))
    recovered = accepted_points(predictor_file)
    union!(valid, recovered)
    remaining = sort!(collect(setdiff(
        Set(point_key(row) for row in eachrow(grid) if !coalesce(row.solver_valid, false)),
        recovered)); by = item -> (String(item[1]), String(item[2]), item[3]))
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    all(haskey(profiles, key[1]) for key in union(valid, Set(remaining))) ||
        error("A grid sensitivity profile is not available from the current calibration bundle.")
    tasks = NamedTuple[]
    for (target_name, instrument, wedge) in remaining
        baseline_dir === nothing || CERiseCGE._checkpoint_files_valid(
            CERiseCGE._baseline_paths(baseline_dir, target_name).manifest) || continue
        target = profiles[target_name]
        candidates = NamedTuple[]
        for (source_name, source_instrument, source_wedge) in valid
            source_instrument === instrument && source_wedge == wedge || continue
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
        push!(tasks, (
            target = target_name,
            instrument=instrument,
            wedge=wedge,
            candidates = candidates,
            output_path = point_file(directory, target_name, instrument, wedge),
            summary_path = isnothing(summary_dir) ? nothing :
                point_file(summary_dir, target_name, instrument, wedge),
        ))
    end
    return tasks
end

function result_row(target, instrument, wedge, source, parameter, distance, result, elapsed_seconds;
    source_baseline_valid::Union{Missing,Bool}=missing,
    source_policy_valid::Union{Missing,Bool}=missing,
    error_message::Union{Missing,String}=missing)
    row = CERiseCGE._solvability_diagnostic_row(target, :policy,
        CERiseCGE.eu_wide_policy_scenario(instrument, wedge).name,
        instrument, wedge, result, elapsed_seconds)
    return merge(row, (
        source_profile = source,
        changed_parameter = parameter,
        parameter_distance = distance,
        source_baseline_valid = source_baseline_valid,
        source_policy_valid = source_policy_valid,
        continuation_error = error_message,
    ))
end

function failure_row(target, instrument, wedge, source, parameter, distance, error_message::String)
    row = CERiseCGE._solvability_failure_row(target, :policy,
        CERiseCGE.eu_wide_policy_scenario(instrument, wedge).name, instrument, wedge,
        ErrorException(error_message))
    return merge(row, (
        source_profile = source,
        changed_parameter = parameter,
        parameter_distance = distance,
        source_baseline_valid = missing,
        source_policy_valid = missing,
        continuation_error = error_message,
    ))
end

function run_task(task)
    checkpoint_complete(task.output_path, [point_key(task.target, task.instrument, task.wedge)],
        isnothing(task.summary_path) ? nothing : dirname(task.summary_path),
        isnothing(task.outcome_path) ? nothing : dirname(task.outcome_path);
        baseline_dir=get(task, :baseline_dir, nothing)) &&
        return (target = task.target, state = :skipped)
    mkpath(dirname(task.output_path))
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    target = profiles[task.target]
    model = policy_model(target, bundle, task.instrument, task.wedge)
    rows = NamedTuple[]
    isempty(task.candidates) && push!(rows, failure_row(target, task.instrument, task.wedge,
        missing, missing, Inf, "No adjacent valid source exists at this instrument and wedge."))
    for candidate in task.candidates
        source = profiles[candidate.profile]
        try
            source_run = source_policy_start(source, bundle, task.instrument, task.wedge;
                baseline_dir=get(task, :baseline_dir, nothing))
            baseline_valid = source_run.baseline_valid
            if !baseline_valid || !source_run.policy_valid
                push!(rows, failure_row(target, task.instrument, task.wedge, candidate.profile, candidate.parameter,
                    candidate.distance, "Source profile has no valid baseline or policy path."))
                continue
            end
            source_valid = source_run.policy_valid
            if !source_valid
                push!(rows, failure_row(target, task.instrument, task.wedge, candidate.profile, candidate.parameter,
                    candidate.distance, "Source profile has no valid solution at this instrument and wedge."))
                continue
            end
            elapsed = @elapsed result = CERiseCGE.run_policy_scenario(model;
                start_values = source_run.starts)
            row = result_row(target, task.instrument, task.wedge, candidate.profile, candidate.parameter,
                candidate.distance, result, elapsed;
                source_baseline_valid = baseline_valid,
                source_policy_valid = source_valid)
            push!(rows, row)
            if row.solver_valid
                !isnothing(task.summary_path) &&
                    RecoveredPolicySummary.write_summary(task.summary_path, target, bundle,
                        model, result, :neighbor; baseline_dir=get(task, :baseline_dir, nothing))
                !isnothing(task.outcome_path) &&
                    RecoveredPolicyOutcome.write_outcome(task.outcome_path, target, bundle,
                        model, result; baseline_dir=get(task, :baseline_dir, nothing))
                break
            end
        catch err
            err isa InterruptException && rethrow()
            push!(rows, failure_row(target, task.instrument, task.wedge, candidate.profile, candidate.parameter,
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
    tasks = continuation_tasks(options.grid_file, options.predictor_file, directory;
        summary_dir = options.summary_dir, baseline_dir=options.baseline_dir)
    tasks = [merge(task, (baseline_dir=options.baseline_dir, outcome_path = isnothing(options.outcome_dir) ? nothing :
        point_file(options.outcome_dir, task.target, task.instrument, task.wedge),)) for task in tasks]
    pending = filter(task -> !checkpoint_complete(task.output_path,
        [point_key(task.target, task.instrument, task.wedge)], options.summary_dir, options.outcome_dir;
        baseline_dir=options.baseline_dir), tasks)
    println("Remaining policy points: ", length(tasks))
    println("Completed checkpoints: ", length(tasks) - length(pending))
    println("Pending policy points: ", length(pending))
    println("Checkpoint directory: ", directory)
    flush(stdout)
    if options.dry_run
        println("Dry run completed; no diagnostics were written.")
        return nothing
    end
    mkpath(directory)
    if !isempty(pending)
        start_workers(options.workers)
        options.workers == 1 ? map(run_task, pending) : pmap(run_task, pending)
    end
    combined = PolicyRecovery.combine_checkpoints([task.output_path for task in tasks], options.output_file)
    println("Wrote ", nrow(combined), " continuation attempts to ", options.output_file)
end

end

if (abspath(PROGRAM_FILE) == @__FILE__) &&
   get(ENV, "CE_RISE_NEIGHBOR_WORKER", "false") != "true"
    ParameterNeighborContinuation.main()
end
