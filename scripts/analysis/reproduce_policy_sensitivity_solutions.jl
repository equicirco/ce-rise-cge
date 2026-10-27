#!/usr/bin/env julia

"""
Reproduce the complete six-region policy-sensitivity solution set from scratch.

The workflow first solves all declared policy points, then applies only
diagnostic continuation paths to every rejected instrument and wedge.
It materializes one complete result table, retaining every endpoint that remains
unresolved under the declared acceptance criteria. No policy point, calibration
value, acceptance criterion, or economic equation is altered by the continuation
stages.
"""

module ReproducePolicySensitivity

using CSV
using DataFrames
using CERiseCGE
include(joinpath(@__DIR__, "run_checkpoints.jl"))

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_OUTPUT_DIR = joinpath(ROOT_DIR, "results")
const DEFAULT_WORKERS = 10
const FINE_INCREMENT = "0.0001220703125" # 1 / 8192

function command_options(args)
    output_dir = DEFAULT_OUTPUT_DIR
    workers = DEFAULT_WORKERS
    outcome_dir = nothing
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--output-dir" && index < length(args)
            output_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--outcome-dir" && index < length(args)
            outcome_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/reproduce_policy_sensitivity_solutions.jl " *
                "[--output-dir PATH] [--outcome-dir PATH] [--workers N] [--dry-run]")
        end
    end
    outcome_dir === nothing && (outcome_dir = joinpath(output_dir, "data", "outcomes"))
    return (output_dir = output_dir, workers = workers, outcome_dir = outcome_dir,
        dry_run = dry_run)
end

relative(path::AbstractString) = relpath(path, ROOT_DIR)

function run_stage(script::AbstractString, args::Vector{String})
    path = joinpath(ROOT_DIR, script)
    command = `$(Base.julia_cmd()) --project=$(ROOT_DIR) $(path) $(args)`
    println("Running ", basename(script))
    flush(stdout)
    run(command)
    return nothing
end

function write_coverage(final_file::AbstractString, output_dir::AbstractString; expected_rows::Integer=14_580)
    table = CSV.read(final_file, DataFrame)
    nrow(table) == expected_rows || error("Final result table has $(nrow(table)) rows; expected $expected_rows.")
    valid = coalesce.(table.solver_valid, false)
    coverage = DataFrame(
        total_policy_points = [nrow(table)],
        validated_equilibria = [count(valid)],
        unresolved_points = [count(.!valid)],
        validated_share_percent = [100.0 * count(valid) / nrow(table)],
    )
    CSV.write(joinpath(output_dir, "policy_solution_coverage.csv"), coverage)
    unresolved = table[.!valid, :]
    CSV.write(joinpath(output_dir, "unresolved_policy_points.csv"), unresolved)
    return nothing
end

function main()
    options = command_options(ARGS)
    out = options.output_dir
    grid = joinpath(out, "policy_sensitivity_grid.csv")
    predictor = joinpath(out, "predictor_trace.csv")
    neighbor = joinpath(out, "parameter_neighbor.csv")
    bisection = joinpath(out, "parameter_bisection.csv")
    fine = joinpath(out, "parameter_bisection_fine.csv")
    diagonal = joinpath(out, "parameter_bisection_diagonal.csv")
    recovered_summaries = joinpath(out, "recovered_endpoint_summaries")
    direct_outcomes = joinpath(options.outcome_dir, "direct")
    recovered_outcomes = joinpath(options.outcome_dir, "recovered")
    baselines = joinpath(out, "data", "baselines")
    final = joinpath(out, "policy_sensitivity_solutions.csv")

    println("Output directory: ", out)
    println("Workers: ", options.workers)
    bundle = default_calibration_bundle()
    profiles = sensitivity_profiles(bundle)
    println("Sensitivity profiles: ", length(profiles))
    println("Declared policy points: ", length(profiles) * nrow(policy_wedge_grid(bundle)))
    options.outcome_dir === nothing || println("Outcome checkpoints: ", options.outcome_dir)
    if options.dry_run
        println("Stages: declared grid; predictor; neighbouring-profile continuation; " *
            "parameter continuation; fine parameter continuation; diagonal continuation; " *
            "full-result materialization; database compilation from saved outcomes.")
        println("Dry run completed; no results were written.")
        return nothing
    end
    signature = RunCheckpoints.input_signature(ROOT_DIR, bundle)
    push!(signature, ("outcome_directory", relpath(options.outcome_dir, out)))
    !isfile(joinpath(out, "run_inputs.csv")) && isdir(options.outcome_dir) &&
        !isempty(readdir(options.outcome_dir)) && error("The outcome directory contains results from an unverified run.")
    RunCheckpoints.verify_run!(out, signature)
    workers = string(options.workers)
    grid_args = ["--output", relative(grid), "--workers", workers]
    direct_outcomes === nothing || append!(grid_args,
        ["--outcome-dir", relative(direct_outcomes)])
    append!(grid_args, ["--baseline-dir", relative(baselines)])
    run_stage("scripts/analysis/run_policy_sensitivity_grid.jl", grid_args)
    predictor_args = [
        "--input", relative(grid), "--output", relative(predictor),
        "--workers", workers, "--predictor", "--summary-dir", relative(recovered_summaries),
    ]
    recovered_outcomes === nothing || append!(predictor_args,
        ["--outcome-dir", relative(recovered_outcomes)])
    append!(predictor_args, ["--baseline-dir", relative(baselines)])
    run_stage("scripts/analysis/run_failed_policy_path_trace.jl", predictor_args)
    neighbor_args = [
        "--grid", relative(grid), "--predictor", relative(predictor),
        "--output", relative(neighbor), "--workers", workers,
        "--summary-dir", relative(recovered_summaries),
    ]
    recovered_outcomes === nothing || append!(neighbor_args,
        ["--outcome-dir", relative(recovered_outcomes)])
    append!(neighbor_args, ["--baseline-dir", relative(baselines)])
    run_stage("scripts/analysis/run_parameter_neighbor_continuation.jl", neighbor_args)
    bisection_args = [
        "--input", relative(neighbor), "--output", relative(bisection),
        "--workers", workers, "--summary-dir", relative(recovered_summaries),
    ]
    recovered_outcomes === nothing || append!(bisection_args,
        ["--outcome-dir", relative(recovered_outcomes)])
    append!(bisection_args, ["--baseline-dir", relative(baselines)])
    run_stage("scripts/analysis/run_parameter_bisection_continuation.jl", bisection_args)
    fine_args = [
        "--input", relative(neighbor), "--remaining-from", relative(bisection),
        "--minimum-fraction-increment", FINE_INCREMENT,
        "--output", relative(fine), "--workers", workers,
        "--summary-dir", relative(recovered_summaries),
    ]
    recovered_outcomes === nothing || append!(fine_args,
        ["--outcome-dir", relative(recovered_outcomes)])
    append!(fine_args, ["--baseline-dir", relative(baselines)])
    run_stage("scripts/analysis/run_parameter_bisection_continuation.jl", fine_args)
    diagonal_args = [
        "--input", relative(neighbor), "--remaining-from", relative(fine),
        "--minimum-fraction-increment", FINE_INCREMENT,
        "--continuation-path", "diagonal_policy_parameter",
        "--output", relative(diagonal), "--workers", workers,
        "--summary-dir", relative(recovered_summaries),
    ]
    recovered_outcomes === nothing || append!(diagonal_args,
        ["--outcome-dir", relative(recovered_outcomes)])
    append!(diagonal_args, ["--baseline-dir", relative(baselines)])
    run_stage("scripts/analysis/run_parameter_bisection_continuation.jl", diagonal_args)
    run_stage("scripts/analysis/materialize_recovered_policy_results.jl", [
        "--grid", relative(grid), "--summary-dir", relative(recovered_summaries),
        "--output", relative(final),
    ])
    write_coverage(final, out; expected_rows=length(sensitivity_profiles(bundle)) * nrow(policy_wedge_grid(bundle)))
    run_stage("scripts/analysis/compile_policy_outcomes_database.jl", [
        "--input", relative(final), "--outcome-dir", relative(options.outcome_dir),
        "--baseline-dir", relative(baselines), "--output", relative(joinpath(out, "data", "policy_outcomes.duckdb")),
    ])
    println("Reproduction completed: ", final)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    ReproducePolicySensitivity.main()
end
