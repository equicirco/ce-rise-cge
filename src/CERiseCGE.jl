"""
CERiseCGE defines the six-region calibration-bundle loader and model-side
scaffold for the empirical CE-RISE circular-economy CGE model built with JCGE.
"""
module CERiseCGE

using CSV
using DataFrames
using Ipopt
using JCGEBlocks
using JCGECalibrate
using JCGECore
using JCGEOutput
using JCGERuntime
using JuMP

const RuntimeExperiments = JCGERuntime.Experiments

export CalibrationBundle, available_bundles, datadir, bundle_dir
export load_calibration_bundle, default_calibration_bundle, calibration_summary, numeraire_closure
export region_codes, industry_codes, factor_codes, institution_codes, external_codes, investment_pool_codes
export family_codes, route_codes, service_target_codes, eol_target_codes, material_target_codes
export account_region_lookup
export MultiRegionOutline, multi_region_outline, outline_summary
export MultiRegionCalibration, multi_region_calibration, calibration_consistency
export calibration_option, calibration_option_number
export PolicyScenario, baseline_scenario, virgin_material_tax_scenario
export recycling_support_scenario, refurbishment_support_scenario
export repair_support_scenario, reuse_support_scenario
export MultiRegionBlock, MULTI_REGION_BLOCK_KINDS, multi_region_blocks, block_kind
export MultiRegionModelSpec, multi_region_model, run_spec, baseline, default_optimizer
export summary_row
export coefficient_template_status, quantity_bridge_status, route_family_table
export write_rows_csv

include("common/calibration.jl")
include("multi_region/core.jl")
include("multi_region/calibration.jl")
include("multi_region/scenarios.jl")
include("multi_region/blocks.jl")
include("multi_region/model.jl")
include("multi_region/results.jl")
include("multi_region/analytics.jl")
include("multi_region/io.jl")

end
