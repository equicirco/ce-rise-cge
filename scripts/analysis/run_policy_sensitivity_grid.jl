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
const OUTPUT_FILE = joinpath(OUTPUT_DIR, "policy_sensitivity_grid.csv")
const WORKERS = 6

function main()
    isempty(ARGS) || ARGS == ["--dry-run"] || error(
        "Usage: julia --project=. scripts/analysis/run_policy_sensitivity_grid.jl [--dry-run]")
    bundle = default_calibration_bundle()
    profiles = sensitivity_profiles(bundle)
    wedges = policy_wedge_grid(bundle)
    expected_rows = length(profiles) * size(wedges, 1)
    println("Sensitivity profiles: ", length(profiles))
    println("Policy points per profile: ", size(wedges, 1))
    println("Expected policy-result rows: ", expected_rows)
    println("Distributed workers: ", WORKERS)

    if ARGS == ["--dry-run"]
        println("Dry run completed; no results were written.")
        return nothing
    end

    isfile(OUTPUT_FILE) && error(
        "Refusing to overwrite existing analysis output: $(OUTPUT_FILE)")
    mkpath(OUTPUT_DIR)
    results = run_configured_policy_sensitivity_grid(
        ; bundle=bundle,
        profiles=profiles,
        execution=:distributed,
        workers=WORKERS,
    )
    size(results, 1) == expected_rows || error(
        "Sensitivity grid returned $(size(results, 1)) rows; expected $(expected_rows).")
    CSV.write(OUTPUT_FILE, results)
    println("Wrote ", OUTPUT_FILE)
    return nothing
end

main()
