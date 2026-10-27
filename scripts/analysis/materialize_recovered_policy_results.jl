#!/usr/bin/env julia

"""
Combine direct-grid outcomes with summaries persisted by successful recovery stages.

Each recovery stage writes its endpoint summary when it first obtains a valid
solution. This script performs no additional model solves: it replaces only
the initially invalid declared policy rows with those persisted summaries.
"""

module MaterializeRecoveredPolicyResults

using CSV
using DataFrames
using CERiseCGE
include(joinpath(@__DIR__, "policy_recovery.jl"))
using .PolicyRecovery: point_key

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))

function command_options(args)
    paths = Dict{Symbol,String}()
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] in ("--grid", "--summary-dir", "--output") && index < length(args)
            key = Symbol(replace(args[index][3:end], "-" => "_"))
            paths[key] = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/materialize_recovered_policy_results.jl " *
                "--grid PATH --summary-dir PATH --output PATH [--dry-run]")
        end
    end
    required = Set([:grid, :summary_dir, :output])
    required ⊆ Set(keys(paths)) || error("--grid, --summary-dir, and --output are required.")
    return merge((dry_run = dry_run,), (; paths...))
end

function read_recovered_summaries(directory::AbstractString)
    paths = isdir(directory) ?
        sort!(filter(path -> endswith(path, ".csv"), readdir(directory; join=true))) : String[]
    isempty(paths) && return DataFrame(sensitivity_profile=String[], instrument=String[],
        wedge=Float64[], solver_valid=Bool[], recovery_stage=String[])
    tables = DataFrame[CSV.read(path, DataFrame) for path in paths]
    all(nrow(table) == 1 for table in tables) ||
        error("Every recovered endpoint summary must contain exactly one row.")
    recovered = vcat(tables...; cols = :union)
    required = Set([:sensitivity_profile, :instrument, :wedge, :solver_valid, :recovery_stage])
    required ⊆ Set(Symbol.(names(recovered))) ||
        error("Recovered endpoint summaries have no recognised policy-summary columns.")
    all(coalesce(row.solver_valid, false) for row in eachrow(recovered)) ||
        error("Recovered summaries must contain accepted endpoints.")
    targets = point_key.(eachrow(recovered))
    length(unique(targets)) == length(targets) ||
        error("Recovered summaries duplicate a profile, instrument and wedge.")
    return recovered
end

function merge_recovered_results(grid::DataFrame, recovered::DataFrame)
    grid_keys = point_key.(eachrow(grid))
    length(unique(grid_keys)) == nrow(grid) || error("The declared grid contains duplicate policy points.")
    recovered_keys = point_key.(eachrow(recovered))
    length(unique(recovered_keys)) == nrow(recovered) || error("Recovered policy points are duplicated.")
    Set(recovered_keys) ⊆ Set(grid_keys) || error("A recovered endpoint is outside the declared grid.")
    all(coalesce.(recovered.solver_valid, false)) || error("A recovered endpoint is not accepted.")
    original = copy(grid)
    original.recovery_stage = [coalesce(row.solver_valid, false) ? "declared_policy_path" : "unresolved"
        for row in eachrow(original)]
    rejected = Set(grid_keys[.!coalesce.(grid.solver_valid, false)])
    replacements = recovered[in.(recovered_keys, Ref(rejected)), :]
    replaced = Set(point_key.(eachrow(replacements)))
    retained = original[.!in.(grid_keys, Ref(replaced)), :]
    final = vcat(retained, replacements; cols=:union)
    sort!(final, [:sensitivity_profile, :instrument, :wedge])
    nrow(final) == nrow(grid) && Set(point_key.(eachrow(final))) == Set(grid_keys) ||
        error("Recovery changed the declared policy-point coverage.")
    return final
end

function main()
    options = command_options(ARGS)
    grid = CSV.read(options.grid, DataFrame)
    recovered = read_recovered_summaries(options.summary_dir)
    println("Direct-grid rows: ", nrow(grid))
    println("Persisted recovered endpoints: ", nrow(recovered))
    if options.dry_run
        println("Dry run completed; no consolidated results were written.")
        return nothing
    end
    final = merge_recovered_results(grid, recovered)
    CERiseCGE._write_atomic_csv(options.output, final)
    println("Wrote ", nrow(final), " rows with ", count(coalesce.(final.solver_valid, false)),
        " validated solutions to ", options.output)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    MaterializeRecoveredPolicyResults.main()
end
