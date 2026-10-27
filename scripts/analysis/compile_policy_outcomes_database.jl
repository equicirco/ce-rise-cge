#!/usr/bin/env julia

"""Build the outcome database from saved results; this script never solves models."""
module CompilePolicyOutcomes

using CSV
using DataFrames
using DBInterface
using DuckDB
using CERiseCGE
include(joinpath(@__DIR__, "policy_outcome_database.jl"))
using .PolicyOutcomeDatabase

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))

function command_options(args)
    input = joinpath(ROOT_DIR, "results", "policy_sensitivity_solutions.csv")
    output = nothing
    outcomes = nothing
    baselines = nothing
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] in ("--input", "--output", "--outcome-dir", "--baseline-dir") && index < length(args)
            value = abspath(args[index + 1])
            args[index] == "--input" && (input = value)
            args[index] == "--output" && (output = value)
            args[index] == "--outcome-dir" && (outcomes = value)
            args[index] == "--baseline-dir" && (baselines = value)
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: compile_policy_outcomes_database.jl [--input PATH] [--output PATH] " *
                "[--outcome-dir PATH] [--baseline-dir PATH] [--dry-run]")
        end
    end
    data = joinpath(dirname(input), "data")
    return (solutions=input, database=something(output, joinpath(data, "policy_outcomes.duckdb")),
        outcome_dir=something(outcomes, joinpath(data, "outcomes")),
        baseline_dir=something(baselines, joinpath(data, "baselines")), dry_run=dry_run)
end

function input_files(options, solutions)
    isfile(options.solutions) || error("Saved policy results are missing: $(options.solutions)")
    outcomes = String[]
    for name in ("direct", "recovered")
        directory = joinpath(options.outcome_dir, name)
        isdir(directory) || continue
        append!(outcomes, filter(path -> endswith(path, ".csv"), readdir(directory; join=true)))
    end
    baselines = isdir(options.baseline_dir) ? filter(path -> endswith(path, ".csv") &&
        !any(suffix -> endswith(path, suffix), (".metal.csv", ".variables.csv", ".complete.csv", ".failure.csv")),
        readdir(options.baseline_dir; join=true)) : String[]
    baseline_variables = isdir(options.baseline_dir) ? filter(path -> endswith(path, ".variables.csv"),
        readdir(options.baseline_dir; join=true)) : String[]
    for path in baselines
        CERiseCGE._checkpoint_files_valid(replace(path, r"\.csv$" => ".complete.csv")) ||
            error("The saved reference checkpoint is incomplete or modified: $path")
    end
    variables = NamedTuple[]
    root = dirname(options.solutions)
    for row in eachrow(solutions)
        coalesce(row.solver_valid, false) || continue
        direct = CERiseCGE._policy_checkpoint_paths(joinpath(root, "policy_sensitivity_grid_checkpoints"),
            joinpath(options.outcome_dir, "direct"), row.sensitivity_profile, row.instrument, row.wedge)
        recovered = CERiseCGE._policy_point_file(joinpath(dirname(options.baseline_dir), "variables", "recovered"),
            row.sensitivity_profile, row.instrument, row.wedge)
        direct_valid = CERiseCGE._checkpoint_files_valid(direct.manifest) &&
            only(CSV.read(direct.summary, DataFrame).solver_valid)
        recovered_valid = CERiseCGE._checkpoint_files_valid(recovered * ".complete.csv")
        path = direct_valid ? direct.variables : recovered
        (direct_valid || recovered_valid) && isfile(path) ||
            error("Saved variable values are missing or modified for $(row.scenario).")
        push!(variables, (path=path, profile=String(row.sensitivity_profile), scenario=String(row.scenario),
            instrument=String(row.instrument), wedge=Float64(row.wedge)))
    end
    return (outcomes=sort!(outcomes), baselines=sort!(baselines),
        baseline_variables=sort!(baseline_variables), variables=variables)
end

key(row) = (String(row.sensitivity_profile), String(row.scenario), String(row.instrument), Float64(row.wedge))

function validate_database(store, expected)
    valid = expected[coalesce.(expected.solver_valid, false), :]
    observed = DataFrame(DBInterface.execute(store.connection,
        "SELECT sensitivity_profile, scenario, instrument, wedge, count(*) AS n " *
        "FROM policy_outcomes GROUP BY ALL"))
    Set(key.(eachrow(observed))) == Set(key.(eachrow(valid))) ||
        error("Saved detailed outcomes do not cover exactly the accepted policy points.")
    columns = join(["\"$column\"" for column in CERiseCGE._OUTCOME_KEY_FIELDS], ", ")
    duplicates = DataFrame(DBInterface.execute(store.connection,
        "SELECT count(*) AS n FROM (SELECT sensitivity_profile, scenario, $columns, count(*) AS n " *
        "FROM policy_outcomes GROUP BY ALL HAVING count(*) <> 1)"))
    only(duplicates.n) == 0 || error("Duplicate detailed outcome identifiers.")
    counts = DataFrame(DBInterface.execute(store.connection,
        "SELECT p.sensitivity_profile, p.scenario, count(*) AS n, " *
        "(SELECT count(*) FROM baseline_outcomes b WHERE b.sensitivity_profile=p.sensitivity_profile) AS baseline_n " *
        "FROM policy_outcomes p GROUP BY p.sensitivity_profile, p.scenario"))
    all(counts.n .== counts.baseline_n) || error("An accepted case has incomplete baseline or policy outcomes.")
    joins = join(["p.\"$column\" IS NOT DISTINCT FROM b.\"$column\""
        for column in CERiseCGE._OUTCOME_KEY_FIELDS], " AND ")
    invalid = DataFrame(DBInterface.execute(store.connection,
        "SELECT count(*) AS n FROM policy_outcomes p LEFT JOIN baseline_outcomes b " *
        "ON p.sensitivity_profile=b.sensitivity_profile AND $joins " *
        "WHERE b.level IS NULL OR p.baseline_level IS DISTINCT FROM b.level " *
        "OR NOT isfinite(p.policy_level) OR NOT isfinite(p.absolute_change)"))
    only(invalid.n) == 0 || error("Policy outcomes have missing, inconsistent or non-finite reference values.")
    variables = DataFrame(DBInterface.execute(store.connection,
        "SELECT sensitivity_profile, scenario, instrument, wedge FROM policy_variables GROUP BY ALL"))
    Set(key.(eachrow(variables))) == Set(key.(eachrow(valid))) || error("Saved policy-variable coverage is incomplete.")
    duplicates = DataFrame(DBInterface.execute(store.connection,
        "SELECT count(*) AS n FROM (SELECT sensitivity_profile, scenario, variable, count(*) " *
        "FROM policy_variables GROUP BY ALL HAVING count(*) <> 1)"))
    only(duplicates.n) == 0 || error("Duplicate saved variable values.")
    for table in ("baseline_variables", "policy_variables")
        invalid = DataFrame(DBInterface.execute(store.connection,
            "SELECT count(*) AS n FROM $table WHERE variable IS NULL OR value IS NULL OR NOT isfinite(value)"))
        only(invalid.n) == 0 || error("Invalid saved values in $table.")
    end
    return PolicyOutcomeDatabase.database_summary(store.connection)
end

function compile_database(options)
    solutions = CSV.read(options.solutions, DataFrame)
    files = input_files(options, solutions)
    length(unique((String(row.sensitivity_profile), String(row.instrument), Float64(row.wedge))
        for row in eachrow(solutions))) == nrow(solutions) || error("Duplicate declared policy points.")
    isempty(files.outcomes) && error("Saved detailed outcomes are missing; no models will be rerun by this script.")
    isempty(files.baselines) && error("Saved zero-policy outcomes are missing.")
    paths = sort!(vcat([options.solutions], files.outcomes, files.baselines,
        files.baseline_variables, [item.path for item in files.variables]))
    inputs = DataFrame(file=relpath.(paths, Ref(dirname(options.solutions))),
        sha256=CERiseCGE._file_digest.(paths))
    sort!(inputs, :file)
    if isfile(options.database)
        database = DuckDB.DB(options.database; readonly=true)
        connection = DBInterface.connect(database)
        try
            stored = DataFrame(DBInterface.execute(connection, "SELECT * FROM source_files ORDER BY file"))
            isequal(stored, inputs) || error("The existing database contains different saved results.")
            summary = validate_database((connection=connection,), solutions)
            println("Verified existing database: ", options.database)
            return summary
        finally
            DBInterface.close!(connection)
            close(database)
        end
    end
    mkpath(dirname(options.database))
    return mktempdir(dirname(options.database)) do directory
        temporary = joinpath(directory, "policy_outcomes.duckdb")
        store = PolicyOutcomeDatabase.create_database(temporary, solutions)
        summary = try
            for path in files.baselines
                PolicyOutcomeDatabase.append_table!(store, "baseline_outcomes", CSV.read(path, DataFrame))
            end
            for path in files.outcomes
                PolicyOutcomeDatabase.append_outcomes!(store, CSV.read(path, DataFrame))
            end
            for path in files.baseline_variables
                table = CSV.read(path, DataFrame)
                table.sensitivity_profile = fill(first(split(basename(path), ".variables.csv")), nrow(table))
                PolicyOutcomeDatabase.append_table!(store, "baseline_variables", table)
            end
            for item in files.variables
                table = CSV.read(item.path, DataFrame)
                table.sensitivity_profile = fill(item.profile, nrow(table))
                table.scenario = fill(item.scenario, nrow(table))
                table.instrument = fill(item.instrument, nrow(table))
                table.wedge = fill(item.wedge, nrow(table))
                PolicyOutcomeDatabase.append_table!(store, "policy_variables", table)
            end
            PolicyOutcomeDatabase._create_table!(store.connection, "source_files", inputs)
            validate_database(store, solutions)
        finally
            PolicyOutcomeDatabase.close_database!(store)
        end
        mv(temporary, options.database)
        println("Compiled ", summary.outcome_rows, " detailed outcome rows into ", options.database)
        return summary
    end
end

function main()
    options = command_options(ARGS)
    if options.dry_run
        println("Read saved policy and baseline outcomes; validate and compile the database. No model solves.")
        return nothing
    end
    compile_database(options)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    CompilePolicyOutcomes.main()
end
