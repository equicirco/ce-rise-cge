#!/usr/bin/env julia

"""
Combine direct-grid outcomes with summaries persisted by successful recovery stages.

Each recovery stage writes its endpoint summary when it first obtains a valid
solution. This script performs no additional model solves: it replaces only
the initially invalid 2% virgin-metal-tax rows with those persisted summaries.
"""

using CSV
using DataFrames
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const TAX_WEDGE = 0.02

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
    isdir(directory) || error("Recovered-summary directory is missing: $(directory)")
    paths = sort!(filter(path -> endswith(path, ".csv"), readdir(directory; join = true)))
    isempty(paths) && error("Recovered-summary directory contains no endpoint summaries.")
    tables = DataFrame[CSV.read(path, DataFrame) for path in paths]
    all(nrow(table) == 1 for table in tables) ||
        error("Every recovered endpoint summary must contain exactly one row.")
    recovered = vcat(tables...; cols = :union)
    required = Set([:sensitivity_profile, :instrument, :wedge, :solver_valid, :recovery_stage])
    required ⊆ Set(Symbol.(names(recovered))) ||
        error("Recovered endpoint summaries have no recognised policy-summary columns.")
    all(String(row.instrument) == "virgin_metal_tax" &&
        isapprox(Float64(row.wedge), TAX_WEDGE; atol = eps(TAX_WEDGE), rtol = 0.0) &&
        row.solver_valid for row in eachrow(recovered)) ||
        error("Recovered summaries must be valid 2% virgin-metal-tax endpoints.")
    targets = String.(recovered.sensitivity_profile)
    length(unique(targets)) == length(targets) ||
        error("Recovered endpoint summaries duplicate sensitivity profiles.")
    return recovered
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
    grid.recovery_stage = [row.solver_valid ? "declared_policy_path" : "unresolved"
        for row in eachrow(grid)]
    recovered_targets = Set(String.(recovered.sensitivity_profile))
    retained = grid[.!((String.(grid.instrument) .== "virgin_metal_tax") .&
        isapprox.(grid.wedge, TAX_WEDGE; atol = eps(TAX_WEDGE), rtol = 0.0) .&
        in.(String.(grid.sensitivity_profile), Ref(recovered_targets))), :]
    final = vcat(retained, recovered; cols = :union)
    sort!(final, [:sensitivity_profile, :instrument, :wedge])
    nrow(final) == nrow(grid) || error("Final table has $(nrow(final)) rows; expected $(nrow(grid)).")
    CERiseCGE._write_atomic_csv(options.output, final)
    println("Wrote ", nrow(final), " rows with ", count(coalesce.(final.solver_valid, false)),
        " validated solutions to ", options.output)
end

main()
