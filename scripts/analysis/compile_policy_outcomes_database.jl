#!/usr/bin/env julia

"""
Reproduce the policy-sensitivity experiment and compile detailed accepted
equilibrium outcomes into one local DuckDB database.

All temporary solver checkpoints and outcome CSVs are kept outside the project.
Only the completed database is written below `results/data/`.
"""

using CSV
using DataFrames
using DBInterface

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_DATABASE = joinpath(ROOT_DIR, "results", "data", "policy_outcomes.duckdb")
const DEFAULT_WORKERS = 10

include(joinpath(@__DIR__, "policy_outcome_database.jl"))
using .PolicyOutcomeDatabase

function command_options(args)
    database = DEFAULT_DATABASE
    workers = DEFAULT_WORKERS
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--output" && index < length(args)
            database = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/compile_policy_outcomes_database.jl " *
                "[--output PATH] [--workers N] [--dry-run]")
        end
    end
    return (database = database, workers = workers, dry_run = dry_run)
end

function run_reproduction(workdir::AbstractString, workers::Integer)
    output_dir = joinpath(workdir, "solver")
    outcome_dir = joinpath(workdir, "outcomes")
    script = joinpath(ROOT_DIR, "scripts", "analysis",
        "reproduce_policy_sensitivity_solutions.jl")
    command = `$(Base.julia_cmd()) --project=$(ROOT_DIR) $(script) --output-dir $(output_dir) --outcome-dir $(outcome_dir) --workers $(string(workers))`
    run(command)
    return (
        solutions = joinpath(output_dir, "policy_sensitivity_solutions.csv"),
        direct_outcomes = joinpath(outcome_dir, "direct"),
        recovered_outcomes = joinpath(outcome_dir, "recovered"),
    )
end

function outcome_paths(paths)
    files = String[]
    for directory in (paths.direct_outcomes, paths.recovered_outcomes)
        isdir(directory) || continue
        append!(files, filter(path -> endswith(path, ".csv"),
            readdir(directory; join=true)))
    end
    sort!(files)
    isempty(files) && error("The reproduced experiment generated no detailed outcome tables.")
    return files
end

policy_key(row) = (String(row.sensitivity_profile), String(row.scenario))

function validate_database(store, expected::DataFrame)
    expected_valid = filter(:solver_valid => identity, expected)
    expected_keys = Set(policy_key(row) for row in eachrow(expected_valid))
    observed = DataFrame(DBInterface.execute(store.connection,
        "SELECT sensitivity_profile, scenario, count(*) AS outcome_rows " *
        "FROM policy_outcomes GROUP BY sensitivity_profile, scenario"))
    observed_keys = Set(policy_key(row) for row in eachrow(observed))
    expected_keys == observed_keys || error(
        "Outcome database has $(length(observed_keys)) policy scenarios; expected $(length(expected_keys)).")
    all(observed.outcome_rows .> 0) || error("An accepted policy scenario has no detailed outcomes.")
    return PolicyOutcomeDatabase.database_summary(store.connection)
end

function compile_database(options)
    ispath(options.database) && error(
        "Refusing to overwrite existing outcome database: $(options.database)")
    mktempdir() do workdir
        paths = run_reproduction(workdir, options.workers)
        solutions = CSV.read(paths.solutions, DataFrame)
        nrow(solutions) == 14_580 || error(
            "Reproduced policy table has $(nrow(solutions)) rows; expected 14,580.")
        temporary_database = joinpath(workdir, "policy_outcomes.duckdb")
        store = PolicyOutcomeDatabase.create_database(temporary_database, solutions)
        summary = nothing
        try
            for path in outcome_paths(paths)
                PolicyOutcomeDatabase.append_outcomes!(store, CSV.read(path, DataFrame))
            end
            summary = validate_database(store, solutions)
        finally
            PolicyOutcomeDatabase.close_database!(store)
        end
        mkpath(dirname(options.database))
        mv(temporary_database, options.database)
        println("Compiled ", options.database)
        println("Policy points: ", summary.policy_points)
        println("Detailed outcome rows: ", summary.outcome_rows)
    end
    return nothing
end

function main()
    options = command_options(ARGS)
    println("Database: ", options.database)
    println("Workers: ", options.workers)
    if options.dry_run
        println("Workflow: reproduce policy solutions; capture accepted detailed outcomes; " *
            "validate scenario coverage; write one DuckDB database.")
        return nothing
    end
    compile_database(options)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
