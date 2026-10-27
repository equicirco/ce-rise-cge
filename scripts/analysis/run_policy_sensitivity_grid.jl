#!/usr/bin/env julia

"""
Run the six-region policy--sensitivity experiment with per-profile checkpoints.

Each worker writes a status record when it starts a profile, updates that record
after every policy-solve attempt, and writes the profile's 20 result rows once
complete.  Completed profiles are retained if the process is restarted.  The
combined CSV is written only after every profile checkpoint is available.
"""

module PolicySensitivityGrid

using CSV
using DataFrames
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const OUTPUT_DIR = joinpath(ROOT_DIR, "results")
const DEFAULT_OUTPUT_FILE = joinpath(OUTPUT_DIR, "policy_sensitivity_grid.csv")
const DEFAULT_WORKERS = 10

function command_options(args)
    dry_run = false
    output_file = DEFAULT_OUTPUT_FILE
    outcome_dir = nothing
    baseline_dir = nothing
    workers = DEFAULT_WORKERS
    index = 1
    while index <= length(args)
        if args[index] == "--dry-run"
            dry_run = true
            index += 1
        elseif args[index] == "--output" && index < length(args)
            output_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
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
        else
            error("Usage: julia --project=. scripts/analysis/run_policy_sensitivity_grid.jl " *
                  "[--dry-run] [--output PATH] [--outcome-dir PATH] [--baseline-dir PATH] [--workers N]")
        end
    end
    outcome_dir === nothing && (outcome_dir = joinpath(dirname(output_file), "data", "outcomes", "direct"))
    baseline_dir === nothing && (baseline_dir = joinpath(dirname(output_file), "data", "baselines"))
    return (dry_run = dry_run, output_file = output_file, outcome_dir = outcome_dir, baseline_dir=baseline_dir,
        workers = workers)
end

function checkpoint_dir(output_file::AbstractString)
    stem = splitext(basename(output_file))[1]
    return joinpath(dirname(output_file), "$(stem)_checkpoints")
end

function profile_checkpoint_complete(profile, directory::AbstractString,
    policy_points::Integer; outcome_dir, baseline_dir, bundle=default_calibration_bundle())
    return CERiseCGE._profile_checkpoint_complete(profile, bundle, directory, outcome_dir, baseline_dir)
end

function write_combined_output(output_file::AbstractString, profiles,
    directory::AbstractString, expected_rows::Integer)
    tables = DataFrame[
        DataFrame(CSV.File(joinpath(directory, "$(profile.name).csv")))
        for profile in profiles
    ]
    results = vcat(tables...; cols=:union)
    nrow(results) == expected_rows || error(
        "Profile checkpoints contain $(nrow(results)) rows; expected $(expected_rows).")
    CERiseCGE._write_atomic_csv(output_file, results)
    return results
end

function main()
    options = command_options(ARGS)
    bundle = default_calibration_bundle()
    profiles = sensitivity_profiles(bundle)
    wedges = policy_wedge_grid(bundle)
    policy_points = nrow(wedges)
    expected_rows = length(profiles) * policy_points
    directory = checkpoint_dir(options.output_file)
    completed = filter(profile -> profile_checkpoint_complete(profile, directory, policy_points;
        outcome_dir=options.outcome_dir, baseline_dir=options.baseline_dir, bundle), profiles)
    completed_names = Set(profile.name for profile in completed)
    pending = filter(profile -> profile.name ∉ completed_names, profiles)

    println("Sensitivity profiles: ", length(profiles))
    println("Policy points per profile: ", policy_points)
    println("Completed profile checkpoints: ", length(completed))
    println("Profiles pending: ", length(pending))
    println("Distributed workers: ", options.workers)
    println("Checkpoint directory: ", directory)
    options.outcome_dir === nothing || println("Outcome directory: ", options.outcome_dir)
    flush(stdout)

    if options.dry_run
        println("Dry run completed; no results were written.")
        return nothing
    end

    mkpath(directory)
    requested_instruments = collect(CIRCULAR_POLICY_INSTRUMENTS)
    isempty(pending) || CERiseCGE.RuntimeExperiments.run_grid(
        pending;
        runner = profile -> CERiseCGE._checkpointed_sensitivity_profile(
            profile, bundle, requested_instruments, directory;
            outcome_dir=options.outcome_dir, baseline_dir=options.baseline_dir),
        execution = :distributed,
        workers = options.workers,
        worker_modules = [:CERiseCGE],
    )

    results = write_combined_output(options.output_file, profiles, directory, expected_rows)
    valid_rows = count(results.solver_valid)
    println("Solver-valid policy rows: ", valid_rows, " of ", expected_rows)
    println("Wrote ", options.output_file)
    flush(stdout)
    return nothing
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    PolicySensitivityGrid.main()
end
