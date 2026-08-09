#!/usr/bin/env julia

"""
Run the full six-region policy--sensitivity experiment design.

The script evaluates the five independently applied policy instruments at the
four declared wedge levels for every profile of the six-parameter behavioural
sensitivity grid. It uses six distributed Julia workers and writes one compact
result table only after the full grid has completed successfully.
"""

using CSV
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const OUTPUT_DIR = joinpath(ROOT_DIR, "results", "multi_region", "policy_sensitivity")
const DEFAULT_OUTPUT_FILE = joinpath(OUTPUT_DIR, "policy_sensitivity_grid.csv")
const WORKERS = 6

function command_options(args)
    if isempty(args)
        return (dry_run = false, output_file = DEFAULT_OUTPUT_FILE)
    elseif args == ["--dry-run"]
        return (dry_run = true, output_file = DEFAULT_OUTPUT_FILE)
    elseif length(args) == 2 && first(args) == "--output"
        return (dry_run = false, output_file = normpath(joinpath(ROOT_DIR, last(args))))
    end
    error("Usage: julia --project=. scripts/analysis/run_policy_sensitivity_grid.jl " *
          "[--dry-run | --output PATH]")
end

function main()
    options = command_options(ARGS)
    bundle = default_calibration_bundle()
    profiles = sensitivity_profiles(bundle)
    wedges = policy_wedge_grid(bundle)
    expected_rows = length(profiles) * size(wedges, 1)
    println("Sensitivity profiles: ", length(profiles))
    println("Policy points per profile: ", size(wedges, 1))
    println("Expected policy-result rows: ", expected_rows)
    println("Distributed workers: ", WORKERS)

    if options.dry_run
        println("Dry run completed; no results were written.")
        return nothing
    end

    isfile(options.output_file) && error(
        "Refusing to overwrite existing analysis output: $(options.output_file)")
    mkpath(dirname(options.output_file))
    results = run_configured_policy_sensitivity_grid(
        ; bundle=bundle,
        profiles=profiles,
        execution=:distributed,
        workers=WORKERS,
    )
    size(results, 1) == expected_rows || error(
        "Sensitivity grid returned $(size(results, 1)) rows; expected $(expected_rows).")
    valid_rows = count(results.solver_valid)
    println("Solver-valid policy rows: ", valid_rows, " of ", expected_rows)
    CSV.write(options.output_file, results)
    println("Wrote ", options.output_file)
    return nothing
end

main()
