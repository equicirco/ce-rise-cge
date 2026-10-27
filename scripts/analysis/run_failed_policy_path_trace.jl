#!/usr/bin/env julia

"""
Trace policy-continuation attempts for the profile--instrument paths rejected
by a completed solvability sweep.

The sweep summary stores one result per declared policy point.  When adaptive
continuation fails, that result can be its final internal trial rather than the
declared point itself.  This diagnostic retains the direct target attempt and
every continuation trial in separate rows, without changing model equations,
calibration data, solver settings, or policy wedges.
"""

module FailedPolicyPathTrace

using CSV
using DataFrames
using Distributed
using JuMP
using CERiseCGE
include(joinpath(@__DIR__, "policy_recovery.jl"))
using .PolicyRecovery: point_key, point_file, checkpoint_complete

include(joinpath(@__DIR__, "recovered_policy_summary.jl"))
using .RecoveredPolicySummary
include(joinpath(@__DIR__, "recovered_policy_outcome.jl"))
using .RecoveredPolicyOutcome

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_INPUT_FILE = joinpath(ROOT_DIR, "results", "policy_sensitivity_grid.csv")
const DEFAULT_OUTPUT_FILE = joinpath(ROOT_DIR, "results", "predictor_trace.csv")
const DEFAULT_WORKERS = 6

function command_options(args)
    input_file = DEFAULT_INPUT_FILE
    output_file = DEFAULT_OUTPUT_FILE
    workers = DEFAULT_WORKERS
    limit = nothing
    predictor = false
    summary_dir = nothing
    outcome_dir = nothing
    baseline_dir = nothing
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--input" && index < length(args)
            input_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--output" && index < length(args)
            output_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--limit" && index < length(args)
            limit = parse(Int, args[index + 1])
            limit > 0 || error("--limit must be positive.")
            index += 2
        elseif args[index] == "--predictor"
            predictor = true
            index += 1
        elseif args[index] == "--summary-dir" && index < length(args)
            summary_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--outcome-dir" && index < length(args)
            outcome_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--baseline-dir" && index < length(args)
            baseline_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/run_failed_policy_path_trace.jl " *
                "[--input PATH] [--output PATH] [--workers N] [--limit N] [--predictor] " *
                "[--summary-dir PATH] [--outcome-dir PATH] [--baseline-dir PATH] [--dry-run]")
        end
    end
    return (input_file=input_file, output_file=output_file, workers=workers,
        limit=limit, predictor=predictor, summary_dir=summary_dir,
        outcome_dir=outcome_dir, baseline_dir=baseline_dir, dry_run=dry_run)
end

checkpoint_dir(output_file::AbstractString) = joinpath(dirname(output_file),
    "$(splitext(basename(output_file))[1])_checkpoints")

checkpoint_path(directory::AbstractString, profile::Symbol, instrument::Symbol) =
    joinpath(directory, "$(profile)__$(instrument).csv")

function _trace_row(profile, phase::Symbol, instrument::Symbol,
    declared_wedge::Real, source_wedge::Real, trial_wedge::Real, attempt::Integer,
    scenario::Symbol, result, elapsed_seconds::Real)
    row = CERiseCGE._solvability_diagnostic_row(profile, phase, scenario,
        instrument, trial_wedge, result, elapsed_seconds)
    return merge(row, (
        declared_wedge = Float64(declared_wedge),
        source_wedge = Float64(source_wedge),
        trial_wedge = Float64(trial_wedge),
        continuation_phase = phase,
        attempt = Int(attempt),
        trial_accepted = CERiseCGE._valid_policy_solution(result),
    ))
end

function _baseline_row(profile, result, elapsed_seconds::Real)
    row = CERiseCGE._solvability_diagnostic_row(profile, :baseline, :baseline,
        missing, 0.0, result, elapsed_seconds)
    return merge(row, (
        declared_wedge = 0.0,
        source_wedge = 0.0,
        trial_wedge = 0.0,
        continuation_phase = :baseline,
        attempt = 1,
        trial_accepted = CERiseCGE._valid_policy_solution(result),
    ))
end

function _policy_attempt(profile, model, phase, instrument, declared_wedge, source_wedge,
    attempt; start_values, runner=CERiseCGE.run_policy_scenario)
    result = nothing
    failure = nothing
    elapsed = @elapsed try
        result = runner(model; start_values)
    catch err
        err isa InterruptException && rethrow()
        failure = err
    end
    trial_wedge = CERiseCGE.policy_wedge(model.scenario, instrument)
    row = if failure === nothing
        _trace_row(profile, phase, instrument, declared_wedge, source_wedge, trial_wedge,
            attempt, model.scenario.name, result, elapsed)
    else
        merge(CERiseCGE._solvability_failure_row(profile, phase, model.scenario.name,
            instrument, trial_wedge, failure), (declared_wedge=Float64(declared_wedge),
            source_wedge=Float64(source_wedge), trial_wedge=Float64(trial_wedge),
            continuation_phase=phase, attempt=Int(attempt), trial_accepted=false))
    end
    return (result=result, row=row)
end

"""Trace one declared policy path using the same adaptive-continuation logic as the sweep."""
function _predictor_start_values(result, prior_starts::AbstractDict{Symbol,<:Real},
    fraction::Real)
    fraction > 0.0 || error("Predictor fraction must be positive.")
    starts = CERiseCGE.solution_start_values(result)
    predicted = Dict{Symbol,Float64}()
    for (name, value) in starts
        prior = get(prior_starts, name, value)
        candidate = value + fraction * (value - prior)
        variable = result.context.variables[name]
        variable isa JuMP.VariableRef || error("Predictor start $(name) is not a variable.")
        if JuMP.has_lower_bound(variable)
            candidate = max(candidate, JuMP.lower_bound(variable))
        end
        if JuMP.has_upper_bound(variable)
            candidate = min(candidate, JuMP.upper_bound(variable))
        end
        isfinite(candidate) || error("Predictor start $(name) is not finite.")
        predicted[name] = candidate
    end
    return predicted
end

function trace_declared_policy_path(profile, models, baseline_result; predictor::Bool=false,
    baseline_start_values=nothing)
    instrument = CERiseCGE._validate_policy_path(models)
    source_strength = 0.0
    source_starts = baseline_start_values === nothing ? CERiseCGE.solution_start_values(baseline_result) : baseline_start_values
    source_result = baseline_result
    prior_strength = nothing
    prior_starts = nothing
    rows = NamedTuple[]
    endpoints = NamedTuple[]

    for model in models
        target_wedge = CERiseCGE.policy_wedge(model.scenario, instrument)
        target_strength = abs(target_wedge)
        direct = _policy_attempt(profile, model, :direct_target, instrument, target_wedge,
            sign(target_wedge) * source_strength, 1; start_values=source_starts)
        direct_result = direct.result
        push!(rows, direct.row)

        if direct.row.trial_accepted
            prior_strength = source_strength
            prior_starts = source_starts
            source_strength = target_strength
            source_starts = CERiseCGE.solution_start_values(direct_result)
            source_result = direct_result
            push!(endpoints, (model=model, result=direct_result))
            continue
        end

        configuration = CERiseCGE.solver_configuration(model)
        current_strength = source_strength
        starts = source_starts
        current_result = source_result
        step = (target_strength - current_strength) / 2.0
        attempts = 1
        accepted_target = false
        while attempts < configuration.policy_continuation_max_attempts &&
              step >= configuration.policy_continuation_minimum_increment
            trial_strength = min(target_strength, current_strength + step)
            trial_wedge = sign(target_wedge) * trial_strength
            trial_model = isapprox(trial_strength, target_strength;
                atol=eps(target_strength), rtol=0.0) ?
                model : CERiseCGE._policy_continuation_model(model, instrument, trial_wedge)
            attempts += 1
            trial = _policy_attempt(profile, trial_model, :continuation_trial, instrument,
                target_wedge, sign(target_wedge) * current_strength, attempts; start_values=starts)
            trial_result = trial.result
            valid = trial.row.trial_accepted
            push!(rows, trial.row)
            if valid
                prior_strength = current_strength
                prior_starts = starts
                current_strength = trial_strength
                starts = CERiseCGE.solution_start_values(trial_result)
                current_result = trial_result
                if isapprox(current_strength, target_strength;
                    atol=eps(target_strength), rtol=0.0)
                    accepted_target = true
                    source_strength = current_strength
                    source_starts = starts
                    push!(endpoints, (model=model, result=current_result))
                    break
                end
                step = min(target_strength - current_strength, 2.0 * step)
            else
                step /= 2.0
            end
        end
        if !accepted_target && predictor && prior_strength !== nothing &&
           prior_starts !== nothing && current_strength > prior_strength
            fraction = (target_strength - current_strength) /
                (current_strength - prior_strength)
            predictor_starts = _predictor_start_values(current_result, prior_starts, fraction)
            attempts += 1
            predicted = _policy_attempt(profile, model, :predictor_target, instrument,
                target_wedge, sign(target_wedge) * current_strength, attempts; start_values=predictor_starts)
            predictor_result = predicted.result
            push!(rows, predicted.row)
            if predicted.row.trial_accepted
                source_strength = target_strength
                source_starts = CERiseCGE.solution_start_values(predictor_result)
                source_result = predictor_result
                push!(endpoints, (model=model, result=predictor_result))
            end
        end
        accepted_target || nothing
    end
    return (trace=DataFrame(rows), endpoints=endpoints)
end

function run_failure_path(task)
    profile_name = Symbol(task.profile)
    instrument = Symbol(task.instrument)
    output_path = String(task.output_path)
    requested = [point_key(profile_name, instrument, wedge) for wedge in task.wedges]
    checkpoint_complete(output_path, requested, task.summary_dir, task.outcome_dir;
        baseline_dir=get(task, :baseline_dir, nothing)) && return (
        profile = profile_name,
        instrument = instrument,
        output_path = output_path,
        state = :skipped,
    )

    bundle = CERiseCGE.default_calibration_bundle()
    profile = only(filter(item -> item.name === profile_name,
        CERiseCGE.sensitivity_profiles(bundle)))
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle=bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    baseline_model = CERiseCGE.multi_region_model(; bundle=profile_bundle,
        calibration=calibration)
    baseline_result = nothing
    baseline_error = nothing
    saved = CERiseCGE._load_policy_baseline(profile, baseline_model, get(task, :baseline_dir, nothing))
    baseline_elapsed = @elapsed try
        if saved === nothing
        baseline_result = CERiseCGE.run_baseline(baseline_model)
        end
    catch err
        err isa InterruptException && rethrow()
        baseline_error = err
    end
    baseline_row = saved !== nothing ?
        (sensitivity_profile=profile.name, stage=:baseline, scenario=:baseline, instrument=missing,
            wedge=0.0, declared_wedge=0.0, source_wedge=0.0, trial_wedge=0.0,
            continuation_phase=:baseline, attempt=0, trial_accepted=true, solver_valid=true,
            solver_elapsed_seconds=0.0, cached_reference=true) :
        baseline_error === nothing ? _baseline_row(profile, baseline_result, baseline_elapsed) :
        merge(CERiseCGE._solvability_failure_row(profile, :baseline, :baseline, missing, 0.0, baseline_error),
            (declared_wedge=0.0, source_wedge=0.0, trial_wedge=0.0, continuation_phase=:baseline,
                attempt=1, trial_accepted=false))
    rows = NamedTuple[baseline_row]
    if saved !== nothing || (baseline_result !== nothing && CERiseCGE._valid_policy_solution(baseline_result))
        models = CERiseCGE.policy_sweep_models(instrument; bundle=profile_bundle,
            calibration=calibration)
        traced = trace_declared_policy_path(profile, models, baseline_result;
            predictor=task.predictor, baseline_start_values=saved === nothing ? nothing : saved.starts)
        for row in eachrow(traced.trace)
            push!(rows, NamedTuple(row))
        end
        for endpoint in traced.endpoints
            wedge = CERiseCGE.policy_wedge(endpoint.model.scenario, instrument)
            wedge in task.wedges || continue
            !isnothing(task.summary_dir) && RecoveredPolicySummary.write_summary(
                point_file(task.summary_dir, profile_name, instrument, wedge), profile, bundle,
                endpoint.model, endpoint.result, :predictor; baseline_dir=get(task, :baseline_dir, nothing))
            !isnothing(task.outcome_dir) && RecoveredPolicyOutcome.write_outcome(
                point_file(task.outcome_dir, profile_name, instrument, wedge), profile, bundle,
                endpoint.model, endpoint.result; baseline_dir=get(task, :baseline_dir, nothing))
        end
    end
    table = DataFrame(rows)
    mkpath(dirname(output_path))
    CERiseCGE._write_atomic_csv(output_path, table)
    return (
        profile = profile_name,
        instrument = instrument,
        output_path = output_path,
        state = :completed,
    )
end

function failed_path_tasks(input_file::AbstractString, directory::AbstractString;
    limit::Union{Nothing,Int}=nothing)
    isfile(input_file) || error("Completed sweep input is missing: $(input_file)")
    table = CSV.read(input_file, DataFrame)
    required = Set([:sensitivity_profile, :instrument, :wedge, :solver_valid])
    required ⊆ Set(Symbol.(names(table))) || error("Input sweep has no recognised diagnostic columns.")
    is_diagnostic = :stage in Symbol.(names(table))
    failed = filter(row ->
        (!is_diagnostic || String(row.stage) == "policy") && !coalesce(row.solver_valid, false),
        eachrow(table))
    pairs = sort!(unique([(Symbol(row.sensitivity_profile), Symbol(row.instrument))
        for row in failed]); by = item -> (String(first(item)), String(last(item))))
    limit === nothing || (pairs = first(pairs, min(limit, length(pairs))))
    return [(profile=profile, instrument=instrument,
        wedges=sort!(unique(Float64[row.wedge for row in failed
            if Symbol(row.sensitivity_profile) === profile && Symbol(row.instrument) === instrument]); by=abs),
        output_path=checkpoint_path(directory, profile, instrument))
        for (profile, instrument) in pairs]
end

function combine_checkpoints(tasks, output_file::AbstractString)
    combined = PolicyRecovery.combine_checkpoints([task.output_path for task in tasks], output_file)
    sort!(combined, [:sensitivity_profile, :instrument, :declared_wedge,
        :attempt, :trial_wedge])
    CERiseCGE._write_atomic_csv(output_file, combined)
    return combined
end

function _start_workers(worker_count::Integer)
    worker_count == 1 && return nothing
    project_file = Base.active_project()
    project_file === nothing && error("The trace runner must be launched with --project=.")
    new_workers = addprocs(worker_count;
        exeflags="--project=$(dirname(project_file))",
        env=Dict("CE_RISE_TRACE_WORKER" => "true"))
    script_path = abspath(@__FILE__)
    for worker in new_workers
        remotecall_wait(Base.include, worker, Main, script_path)
    end
    return new_workers
end

function main()
    options = command_options(ARGS)
    directory = checkpoint_dir(options.output_file)
    tasks = failed_path_tasks(options.input_file, directory; limit=options.limit)
    if options.baseline_dir !== nothing
        filter!(task -> CERiseCGE._checkpoint_files_valid(
            CERiseCGE._baseline_paths(options.baseline_dir, task.profile).manifest), tasks)
    end
    tasks = [merge(task, (
        predictor=options.predictor,
        summary_dir=options.summary_dir,
        outcome_dir=options.outcome_dir,
        baseline_dir=options.baseline_dir,
    )) for task in tasks]
    pending = filter(task -> !checkpoint_complete(task.output_path,
        [point_key(task.profile, task.instrument, wedge) for wedge in task.wedges],
        task.summary_dir, task.outcome_dir; baseline_dir=options.baseline_dir), tasks)
    println("Failed profile--instrument paths: ", length(tasks))
    println("Completed checkpoints: ", length(tasks) - length(pending))
    println("Pending paths: ", length(pending))
    println("Checkpoint directory: ", directory)
    flush(stdout)
    if options.dry_run
        println("Dry run completed; no diagnostics were written.")
        return nothing
    end
    if !isempty(pending)
        _start_workers(options.workers)
        println("Tracing pending paths with ", options.workers, " worker process(es).")
        flush(stdout)
        options.workers == 1 ? map(run_failure_path, pending) :
            pmap(run_failure_path, pending)
    end
    combined = combine_checkpoints(tasks, options.output_file)
    println("Wrote ", nrow(combined), " trace rows to ", options.output_file)
    return nothing
end

end

if (abspath(PROGRAM_FILE) == @__FILE__) &&
   get(ENV, "CE_RISE_TRACE_WORKER", "false") != "true"
    FailedPolicyPathTrace.main()
end
