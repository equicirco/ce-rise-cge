#!/usr/bin/env julia

"""
Run the CE-RISE empirical workflow through the calibration SAM and physical-satellite stages.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SCRIPT_DIR = @__DIR__

function run_script(script_name::AbstractString)
    script = joinpath(SCRIPT_DIR, script_name)
    cmd = `$(Base.julia_cmd()) $script`
    println("Running ", script_name)
    run(cmd)
end

function main()
    for script_name in [
        "aggregate_figaro_regions.jl",
        "prepare_sut.jl",
        "map_ce_rise_to_figaro.jl",
        "disaggregate_sut.jl",
        "extract_circular_parent_sectors.jl",
        "extract_circular_route_anchors.jl",
        "derive_circular_split_weights.jl",
        "build_intermediate_augmented_sut.jl",
        "build_stage1_initial_artifacts.jl",
        "build_stage2_integrated_artifacts.jl",
        "build_stage3_final_artifacts.jl",
        "build_stage4_balanced_sut.jl",
        "build_stage4b_symmetric_io.jl",
        "build_stage5_core_sam.jl",
        "build_stage6_closed_sam.jl",
        "build_stage7_model_scaffold.jl",
        "build_stage8_six_region_bundle.jl",
        "build_stage9_physical_satellite.jl",
        "validate_sut_totals.jl",
    ]
        run_script(script_name)
    end
end

main()
