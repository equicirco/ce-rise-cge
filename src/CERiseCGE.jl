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
export load_calibration_bundle, default_calibration_bundle, calibration_summary, numeraire_closure, closure_accounting_targets
export region_codes, industry_codes, factor_codes, institution_codes, external_codes, investment_pool_codes
export family_codes, route_codes, service_target_codes, eol_target_codes, material_target_codes
export account_region_lookup
export MultiRegionOutline, multi_region_outline, outline_summary
export MultiRegionCalibration, multi_region_calibration, calibration_consistency
export calibration_option, calibration_option_number
export PolicyScenario, baseline_scenario, CIRCULAR_POLICY_INSTRUMENTS
export SensitivityProfile, SENSITIVITY_PARAMETER_KEYS
export eu_wide_policy_scenario, policy_wedge, policy_wedge_grid, policy_sweep_scenarios, validate_policy_scenario
export sensitivity_parameter_grid, sensitivity_profiles, sensitivity_bundle
export MULTI_REGION_BLOCK_KINDS, multi_region_blocks
export MultiRegionModelSpec, multi_region_model, solver_configuration, run_spec, baseline, run_baseline, run_policy_scenario, run_policy_path, policy_sweep_models, run_configured_policy_sweep, run_configured_policy_sensitivity_grid, solution_start_values, default_optimizer
export summary_row, policy_fiscal_totals, policy_sweep_summary
export coefficient_template_status, quantity_bridge_status, route_family_table
export PhysicalSatelliteSpec, PhysicalSatelliteReadiness, physical_satellite_spec, physical_satellite_readiness
export observed_physical_flows, physical_flow_anchors, observed_physical_quantity_links, physical_quantity_indices
export physical_flow_reference, physical_calibration_driver_report, physical_flow_projection
export physical_mass_balance_requirements, physical_baseline_report
export CircularMetalProfile, circular_metal_parameter_schema, circular_metal_profile, circular_metal_baseline_profile
export circular_metal_blocks, circular_metal_initial_values, circular_metal_coverage, circular_metal_projection
export circular_metal_calibration_report
export circular_material_structure, circular_material_blocks, circular_material_initial_values
export CircularRouteCalibration, circular_route_calibration, circular_route_blocks, circular_route_initial_values
export circular_policy_blocks, circular_policy_initial_values
export write_rows_csv

include("common/calibration.jl")
include("model/core.jl")
include("model/calibration.jl")
include("model/circular_metal_types.jl")
include("model/circular_routes_types.jl")
include("model/scenarios.jl")
include("model/trade.jl")
include("model/blocks.jl")
include("model/model.jl")
include("model/results.jl")
include("model/analytics.jl")
include("model/io.jl")
include("model/physical_satellite.jl")
include("model/circular_metal.jl")
include("model/circular_routes.jl")
include("model/circular_policy.jl")

end
