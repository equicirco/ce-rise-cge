using Test
using DataFrames: nrow
using CERiseCGE
using JCGEBlocks
using JCGECore
using JCGEOutput
using JCGERuntime
using JuMP

bundle = default_calibration_bundle()

@test available_bundles() == (:eu_2016_six_region,)
policy_grid = policy_wedge_grid(bundle)
@test nrow(policy_grid) == 20
@test Set(policy_grid.instrument) == Set(CIRCULAR_POLICY_INSTRUMENTS)
for instrument in CIRCULAR_POLICY_INSTRUMENTS
    rows = filter(row -> row.instrument === instrument, eachrow(policy_grid))
    @test [row.sequence for row in rows] == [1, 2, 3, 4]
    @test abs.([row.wedge for row in rows]) == [0.0025, 0.005, 0.01, 0.02]
end
sensitivity_grid = sensitivity_parameter_grid(bundle)
@test nrow(sensitivity_grid) == 18
@test Set((row.component, row.key) for row in eachrow(sensitivity_grid)) ==
    Set(SENSITIVITY_PARAMETER_KEYS)
for (component, key) in SENSITIVITY_PARAMETER_KEYS
    rows = sort!(collect(filter(row -> row.component == component && row.key == key,
        eachrow(sensitivity_grid))); by = row -> row.sequence)
    @test [row.sequence for row in rows] == [1, 2, 3]
    @test [row.value for row in rows] == [0.5, 1.0, 2.0]
end
sensitivity_cases = sensitivity_profiles(bundle)
@test length(sensitivity_cases) == 729
@test sensitivity_cases[1].name == :sensitivity_001
@test all(value == 0.5 for value in values(sensitivity_cases[1].values))
unit_profile = only(filter(profile -> all(value == 1.0 for value in values(profile.values)),
    sensitivity_cases))
unit_bundle = sensitivity_bundle(unit_profile; bundle=bundle)
@test calibration_option_number(unit_bundle, "trade", "armington_elasticity") == 1.0
@test calibration_option_number(unit_bundle, "circular_metal", "material_substitution_elasticity") == 1.0
recycling_scenarios = policy_sweep_scenarios(:recycling_support; bundle=bundle)
@test policy_wedge.(recycling_scenarios, :recycling_support) == [-0.0025, -0.005, -0.01, -0.02]
@test length(unique(scenario.name for scenario in recycling_scenarios)) == 4
@test region_codes(bundle) == [:DE, :FR, :IT, :PL, :SK, :REU]
@test length(industry_codes(bundle)) == 150
@test length(factor_codes(bundle)) == 12
@test length(institution_codes(bundle)) == 18
@test length(external_codes(bundle)) == 6
@test investment_pool_codes(bundle) == [:INV_POOL]
@test family_codes(bundle) == [:ELMA, :OFMA, :RATV]
@test route_codes(bundle) == [:NEW, :REF, :REP, :REU, :REC, :INC]

outline = multi_region_outline(; bundle = bundle)
@test outline.sets.activities == outline.industries
@test outline.sets.commodities == outline.industries
@test all(length(outline.industries_by_region[region]) == 25 for region in outline.regions)
@test all(length(outline.factors_by_region[region]) == 2 for region in outline.regions)
@test all(length(outline.institutions_by_region[region]) == 3 for region in outline.regions)
@test all(length(outline.externals_by_region[region]) == 1 for region in outline.regions)

model = multi_region_model(; bundle = bundle)
recycling_sweep_models = policy_sweep_models(:recycling_support; bundle=bundle)
@test length(recycling_sweep_models) == 4
@test [policy_wedge(model.scenario, :recycling_support)
    for model in recycling_sweep_models] == [-0.0025, -0.005, -0.01, -0.02]
tax_sweep_models = policy_sweep_models(:virgin_metal_tax; bundle=bundle)
@test all(isapprox.(CERiseCGE._policy_continuation_wedges(tax_sweep_models),
    [0.0025, 0.005, 0.0075, 0.01, 0.0125, 0.015, 0.0175, 0.02];
    atol=1.0e-12, rtol=0.0))
failure_rows = CERiseCGE._sensitivity_failure_table(
    unit_profile, bundle, collect(CIRCULAR_POLICY_INSTRUMENTS), ErrorException("test failure"))
@test nrow(failure_rows) == 20
@test all(.!failure_rows.solver_valid)
@test all(failure_rows.solver_message .== "test failure")
@test nrow(model.coefficient_template) == 138
@test nrow(bundle.circular_metal_baseline) == 12
@test nrow(model.quantity_template) == 126
@test length(model.calibration.products) == 25
@test length(model.calibration.trade_routes) == 1132
@test model.calibration.positive_lower == 1.0e-8
routes = model.circular_routes
@test length(routes.services) == 18
@test sum(length, values(routes.eol_lines_by_family)) == 90
@test length(routes.eol_reference_total) == 66
@test routes.service_elasticity == 1.0
@test routes.eol_allocation_elasticity == 1.0
@test routes.eol_productivity_elasticity == 1.0
@test all(isapprox(sum(routes.eol_share[(family, line)]
    for line in routes.eol_lines_by_family[family]), 1.0; atol=1.0e-12)
    for family in outline.families)
solver = solver_configuration(model)
@test solver.ipopt_bound_push_share == 0.01
@test solver.ipopt_bound_push > 0.0
@test solver.ipopt_bound_push < model.calibration.positive_lower
@test solver.equation_scaling_floor == 1.0
@test solver.ipopt_hessian_approximation == "limited-memory"
@test solver.ipopt_bound_mult_init_method == "mu-based"
@test solver.ipopt_mu_init == 1.0e-8
@test solver.ipopt_tolerance == 1.0e-8
@test solver.ipopt_acceptable_tolerance == 10.0
@test solver.ipopt_acceptable_dual_infeasibility_tolerance == 10.0
@test solver.ipopt_acceptable_constraint_violation_tolerance == 1.0e-4
@test solver.ipopt_acceptable_complementarity_tolerance == 10.0
@test solver.ipopt_acceptable_iterations == 1
@test solver.baseline_residual_tolerance == 1.0e-4
@test solver.scaled_residual_tolerance == 1.0e-4
@test solver.bound_violation_tolerance == 1.0e-8
@test length(model.calibration.inventory_change) == 150
@test all(haskey(model.calibration.inventory_change, activity) for activity in outline.industries)
@test all(
    isapprox(
        model.calibration.marketed_output[activity],
        model.calibration.activity_output[activity] - model.calibration.inventory_change[activity];
        atol = 1.0e-10,
    )
    for activity in outline.industries
)

consistency = calibration_consistency(model.calibration)
@test consistency.max_abs_industry_cost_residual <= 1.0e-6
@test consistency.max_abs_trade_supply_residual <= 1.0e-5
@test consistency.max_abs_trade_demand_residual <= 1.0e-6

spec = run_spec(model)
@test spec.scenario.name == :baseline
@test spec.closure.numeraire == :P_HH_COMMON
@test spec.closure.kind == :price_index
@test numeraire_closure(bundle).numeraire == spec.closure.numeraire
@test numeraire_closure(bundle).kind == spec.closure.kind
accounting_targets = closure_accounting_targets(bundle)
@test accounting_targets.investment_pool == :INV_POOL
@test accounting_targets.market_region == :DE
@test accounting_targets.market_good == :IND_DE_AGRI_FOOD
@test !JCGECore.is_enforced(
    spec.closure,
    :regional_investment_pool,
    :investment_pool_clearing,
)
@test !JCGECore.is_enforced(
    spec.closure,
    :regional_composite_market,
    :regional_composite_market,
    :IND_DE_AGRI_FOOD,
    :DE,
)
@test length(JCGECore.accounting_checks(spec.closure)) == 2
blocks = multi_region_blocks(model.outline, model.calibration, model.scenario;
    circular_routes = model.circular_routes,
    circular_metal = model.circular_metal)
@test length(blocks.production) == 13
@test blocks.material_composite !== nothing
@test length(blocks.material_composite.production) == 6
@test blocks.circular_routes.eol_allocation isa CERiseCGE.EUWideEOLAllocationBlock
@test length(blocks.circular_routes.eol_production) == 6
@test blocks.circular_routes.service_demand isa CERiseCGE.CircularServiceDemandBlock
@test blocks.factor_availability isa JCGEBlocks.RegionalFactorAvailabilityBlock
@test blocks.trade isa JCGEBlocks.MultiRegionTradeBlock
@test blocks.market_clearing isa JCGEBlocks.RegionalCompositeMarketClearingBlock
@test blocks.numeraire isa JCGEBlocks.NumeraireBlock
@test blocks.price_index isa CERiseCGE.CircularHouseholdPriceIndexBlock
@test blocks.utility isa CERiseCGE.CircularHouseholdUtilityBlock
@test blocks.circular_policy === nothing
@test blocks.physical_quantity_links isa JCGEBlocks.QuantityLinkBlock
@test length(blocks.physical_quantity_links.quantities) == 78
@test JCGEBlocks.inventory_treatment(blocks.trade) == JCGEBlocks.inventory_treatment(blocks.investment_pool)
@test JCGEBlocks.inventory_treatment(blocks.trade) == JCGEBlocks.inventory_treatment(blocks.market_clearing)
@test JCGEBlocks.inventory_treatment(blocks.trade).mode == :stock_change
@test JCGEBlocks.inventory_treatment(blocks.trade).parameter == :inventory_change
initial_values = blocks.initial_values.params.start
@test all(
    isapprox(
        initial_values[JCGEBlocks.global_var(:UU, region)],
        prod(model.calibration.household_demand[good]^model.calibration.household_share[good]
            for good in routes.nonservice_goods_by_region[region]) *
        prod(initial_values[JCGEBlocks.global_var(:Q_CIRCULAR_SERVICE, service)]^
            routes.service_share[service]
            for service in routes.services if routes.service_region[service] === region);
        atol = 1.0e-8,
    )
    for region in outline.regions
)
@test any(block -> block isa CERiseCGE.EUWideEOLAllocationBlock, spec.model.blocks)
@test any(block -> block isa CERiseCGE.CircularServiceDemandBlock, spec.model.blocks)
material = circular_material_structure(model)
@test length(material.activities) == 146
@test material.elasticity == 1.0
@test all(length(material.activities_by_region[region]) > 0 for region in outline.regions)
@test all(isapprox(
    material.share[(activity, material.primary_good[activity])] +
    material.share[(activity, material.recycled_good[activity])],
    1.0;
    atol = 1.0e-12,
) for activity in material.activities)
expected_primary_tax_activities = Set(
    goods[:NEW]
    for goods in values(routes.route_goods_by_service)
    if haskey(material.primary_good, goods[:NEW])
)
expected_recycled_support_activities = Set(
    goods[route]
    for goods in values(routes.route_goods_by_service)
    for route in (:NEW, :REF, :REP)
    if haskey(material.recycled_good, goods[route])
)
@test CERiseCGE._policy_primary_tax_activities(routes, material) ==
    expected_primary_tax_activities
@test CERiseCGE._policy_recycled_support_activities(routes, material) ==
    expected_recycled_support_activities

ctx = JCGERuntime.KernelContext(model = JuMP.Model())
for block in spec.model.blocks
    JCGECore.build!(block, ctx, spec)
end
@test JuMP.lower_bound(
    ctx.variables[JCGEBlocks.global_var(:Z, :IND_SK_REP_OFMA)],
) == model.calibration.positive_lower
@test haskey(ctx.variables,
    JCGEBlocks.global_var(:physical_flow, first(blocks.physical_quantity_links.quantities)))
bounded_starts = [
    (JuMP.lower_bound(variable), JuMP.start_value(variable))
    for variable in values(ctx.variables)
    if variable isa JuMP.VariableRef && JuMP.has_lower_bound(variable) &&
       JuMP.start_value(variable) !== nothing
]
@test all(start >= lower for (lower, start) in bounded_starts)
JCGERuntime.compile_equations!(ctx; closure = spec.closure, compile_objective = false)
checks = Set(JCGECore.accounting_checks(spec.closure))
checked_equations = [
    equation for equation in ctx.equations
    if get(equation.payload, :closure_condition, nothing) in checks
]
@test length(checked_equations) == 2
@test all(
    get(equation.payload, :condition_role, nothing) == :accounting_check &&
    get(equation.payload, :constraint, nothing) === nothing
    for equation in checked_equations
)
@test any(get(equation.payload, :constraint, nothing) !== nothing for equation in ctx.equations)
expected_quantity_links = length(blocks.physical_quantity_links.quantities) +
    sum(length(block.quantities) for block in blocks.circular_metal
        if block isa JCGEBlocks.QuantityLinkBlock)
@test count(equation -> equation.tag == :quantity_link, ctx.equations) == expected_quantity_links

zero_policy_scenario = eu_wide_policy_scenario(:virgin_metal_tax, 0.0; bundle = bundle)
@test zero_policy_scenario.name == :policy_zero
@test zero_policy_scenario.target_regions == outline.regions
@test policy_wedge(zero_policy_scenario, :virgin_metal_tax) == 0.0
@test validate_policy_scenario(zero_policy_scenario, outline) === nothing
zero_policy_model = multi_region_model(; bundle = bundle, scenario = zero_policy_scenario)
zero_policy_blocks = multi_region_blocks(
    zero_policy_model.outline,
    zero_policy_model.calibration,
    zero_policy_model.scenario;
    circular_routes = zero_policy_model.circular_routes,
    circular_metal = zero_policy_model.circular_metal,
)
@test zero_policy_blocks.circular_policy !== nothing

baseline_result = run_baseline(model)
@test JuMP.termination_status(baseline_result.context.model) == JuMP.MOI.ALMOST_LOCALLY_SOLVED
@test JuMP.primal_status(baseline_result.context.model) == JuMP.MOI.NEARLY_FEASIBLE_POINT
@test baseline_result.summary.above_tol == 0
@test baseline_result.scaled_summary.above_tol == 0
@test baseline_result.bound_summary.above_tol == 0
@test all(isapprox(
    JuMP.value(baseline_result.context.variables[
        JCGEBlocks.global_var(:P_CIRCULAR_SERVICE, service)
    ]), 1.0; atol=1.0e-7, rtol=1.0e-7)
    for service in routes.services)
@test all(isapprox(
    JuMP.value(baseline_result.context.variables[
        JCGEBlocks.global_var(:Q_CIRCULAR_SERVICE, service)
    ]),
    sum(model.calibration.household_demand[good]
        for good in values(routes.route_goods_by_service[service]));
    atol=1.0e-5, rtol=1.0e-8)
    for service in routes.services)
@test all(isapprox(
    JuMP.value(baseline_result.context.variables[
        JCGEBlocks.global_var(:EOL_FLOW, line)
    ]), 1.0;
    atol=solver.baseline_residual_tolerance, rtol=1.0e-5)
    for family in outline.families for line in routes.eol_lines_by_family[family])
@test all(isapprox(
    JuMP.value(baseline_result.context.variables[
        JCGEBlocks.global_var(:EOL_INDEX, activity)
    ]), 1.0; atol=solver.baseline_residual_tolerance, rtol=1.0e-5)
    for activity in keys(routes.eol_reference_total))
@test all(isapprox(
    JuMP.value(baseline_result.context.variables[
        JCGEBlocks.global_var(:P_MATERIAL_COMPOSITE, activity)
    ]), 1.0;
    atol = 1.0e-7, rtol = 1.0e-7,
) for activity in material.activities)
@test all(isapprox(
    JuMP.value(baseline_result.context.variables[
        JCGEBlocks.global_var(:X, good, activity)
    ]),
    model.calibration.intermediate_coefficient[(good, activity)] *
        model.calibration.activity_output[activity];
    atol = 1.0e-3, rtol = 1.0e-9,
) for activity in material.activities for good in (
    material.primary_good[activity], material.recycled_good[activity]))

zero_policy_result = run_policy_scenario(zero_policy_model)
@test JuMP.termination_status(zero_policy_result.context.model) == JuMP.MOI.ALMOST_LOCALLY_SOLVED
@test zero_policy_result.summary.above_tol == 0
@test zero_policy_result.scaled_summary.above_tol == 0
@test zero_policy_result.bound_summary.above_tol == 0

tax_smoke_model = multi_region_model(; bundle = bundle,
    scenario = eu_wide_policy_scenario(:virgin_metal_tax, 0.01; bundle = bundle))
tax_smoke_result = run_policy_scenario(tax_smoke_model)
@test JuMP.termination_status(tax_smoke_result.context.model) == JuMP.MOI.ALMOST_LOCALLY_SOLVED
@test tax_smoke_result.scaled_summary.above_tol == 0
@test tax_smoke_result.bound_summary.above_tol == 0
tax_revenue = sum(
    JuMP.value(tax_smoke_result.context.variables[
        JCGEBlocks.global_var(:POLICY_REVENUE, region)
    ])
    for region in outline.regions
)
tax_transfer = sum(
    JuMP.value(tax_smoke_result.context.variables[
        JCGEBlocks.global_var(:POLICY_TRANSFER, region)
    ])
    for region in outline.regions
)
@test tax_revenue > 0.0
@test isapprox(tax_revenue, tax_transfer; atol = 1.0e-8, rtol = 1.0e-10)
tax_sweep = policy_sweep_summary(baseline_result, model,
    [(model = tax_smoke_model, result = tax_smoke_result)])
@test nrow(tax_sweep) == 1
@test only(tax_sweep.fiscal_basis_kind) === :tax_revenue
@test only(tax_sweep.fiscal_basis_million_eur) > 0.0

recycling_seed_model = multi_region_model(; bundle = bundle,
    scenario = eu_wide_policy_scenario(:recycling_support, -0.005; bundle = bundle))
recycling_target_model = multi_region_model(; bundle = bundle,
    scenario = eu_wide_policy_scenario(:recycling_support, -0.01; bundle = bundle))
recycling_path = run_policy_path([recycling_seed_model, recycling_target_model])
@test length(recycling_path) == 2
recycling_seed_result = recycling_path[1].result
recycling_target_result = recycling_path[2].result
@test JuMP.termination_status(recycling_seed_result.context.model) == JuMP.MOI.ALMOST_LOCALLY_SOLVED
@test JuMP.termination_status(recycling_target_result.context.model) == JuMP.MOI.ALMOST_LOCALLY_SOLVED
@test recycling_target_result.scaled_summary.above_tol == 0
@test recycling_target_result.bound_summary.above_tol == 0
recycling_sweep = policy_sweep_summary(baseline_result, model, recycling_path)
@test nrow(recycling_sweep) == 2
@test all(recycling_sweep.instrument .== :recycling_support)
@test all(recycling_sweep.fiscal_basis_kind .== :support_expenditure)
@test all(recycling_sweep.support_expenditure_million_eur .> 0.0)
@test all(recycling_sweep.scaled_residuals_above_tolerance .== 0)
@test all(recycling_sweep.bound_violations_above_tolerance .== 0)

physical_spec = physical_satellite_spec(model)
@test nrow(physical_spec.quantity_bridge) == 126
@test nrow(physical_spec.coefficients) == 138
@test nrow(physical_spec.observed_flows) == 78
physical_readiness = physical_satellite_readiness(model)
@test !physical_readiness.ready
@test !physical_readiness.quantity_value_column
@test !physical_readiness.coefficient_value_column
@test physical_readiness.template_quantity_rows == 126
@test physical_readiness.template_coefficient_rows == 138
@test physical_readiness.model_anchor_rows == 84
@test physical_readiness.unbound_anchor_rows == 42
@test physical_readiness.observed_flow_rows == 78
@test physical_readiness.observed_new_output_rows == 18
@test physical_readiness.observed_anchor_ready
physical_indices = physical_quantity_indices(baseline_result, model)
@test nrow(physical_indices) == 126
@test count(==( :index_available), physical_indices.status) == 84
@test count(==( :requires_ce_account), physical_indices.status) == 42
@test all(value -> isfinite(value) && value > 0.0, skipmissing(physical_indices.model_quantity_index))
physical_requirements = physical_mass_balance_requirements(model)
@test nrow(physical_requirements) == 78
@test count(==( :end_of_life_allocation), physical_requirements.balance) == 18
@test count(==( :life_extension_yield), physical_requirements.balance) == 54
@test count(==( :recycling_metal_yield), physical_requirements.balance) == 6
physical_flows = observed_physical_flows(model)
@test nrow(physical_flows) == 78
@test count(row -> row.route == "NEW" && row.flow_kind == "new_product_output", eachrow(physical_flows)) == 18
@test all(row -> row.physical_unit == "tonnes" && row.status == "observed" && row.value_tonnes > 0.0, eachrow(physical_flows))
physical_anchors = physical_flow_anchors(model)
@test length(physical_anchors) == 78
@test all(anchor -> anchor isa SatelliteAnchor && anchor.unit == "tonnes" &&
    anchor.base_quantity > 0.0 && anchor.base_driver == 1.0, physical_anchors)
physical_projection = physical_flow_projection(baseline_result, model)
@test nrow(physical_projection) == 78
@test all(==( :projected), physical_projection.status)
@test all(value -> isfinite(value) && value > 0.0, physical_projection.projected_tonnes)
@test all(isapprox(row.model_quantity_index, 1.0; atol = 1.0e-12, rtol = 0.0)
    for row in eachrow(physical_projection))
@test all(isapprox(row.projected_tonnes, row.benchmark_tonnes; atol = 1.0e-9, rtol = 1.0e-12)
    for row in eachrow(physical_projection))
physical_reference = physical_flow_reference(baseline_result, model)
@test physical_reference isa SatelliteReference
@test physical_reference.id == :baseline
@test length(physical_reference.drivers) == nrow(physical_projection)
physical_driver_report = physical_calibration_driver_report(baseline_result, model)
@test nrow(physical_driver_report) == nrow(physical_projection)
@test all(isfinite, physical_driver_report.relative_difference)
physical_report = physical_baseline_report(baseline_result, model)
@test physical_report.readiness == physical_readiness
@test nrow(physical_report.observed_flows) == 78
@test nrow(physical_report.quantity_indices) == 126
@test nrow(physical_report.flow_projection) == 78
@test physical_report.flow_reference.id == physical_reference.id
@test physical_report.flow_reference.drivers == physical_reference.drivers
@test nrow(physical_report.calibration_driver_report) == nrow(physical_projection)

metal_schema = circular_metal_parameter_schema(model)
@test nrow(metal_schema) == 12
metal_profile = circular_metal_baseline_profile(model)
@test metal_profile isa CircularMetalProfile
@test all(value == 0.001 for (id, value) in metal_profile.value if endswith(String(id), "ALL_METAL_external_price"))
@test all(value == 0.25 for (id, value) in metal_profile.value if endswith(String(id), "ALL_RECOVERY_yield_metal_ee"))
@test_throws ErrorException circular_metal_profile(model,
    Dict(first(keys(metal_profile.value)) => 0.5))
metal_model = multi_region_model(; bundle = bundle, circular_metal = metal_profile)
metal_spec = run_spec(metal_model)
metal_blocks = multi_region_blocks(metal_model.outline, metal_model.calibration,
    metal_model.scenario; circular_metal = metal_profile)
@test length(metal_blocks.circular_metal) == 6
@test length(metal_spec.model.blocks) == length(spec.model.blocks)
metal_coverage = circular_metal_coverage(metal_model)
@test metal_coverage.complete == Bool[true, false, true, false, false]
metal_result = run_baseline(metal_model; tol = 1.0e-4)
@test JuMP.termination_status(metal_result.context.model) == JuMP.MOI.ALMOST_LOCALLY_SOLVED
@test metal_result.summary.above_tol == 0
metal_projection = circular_metal_projection(metal_result, metal_model)
@test all(isfinite, metal_projection.tonnes)
@test all(row -> row.quantity_kind === :metal_inventory_change || row.tonnes >= -1.0e-2,
    eachrow(metal_projection))
@test count(==( :observed_recycled_metal_output), metal_projection.quantity_kind) == 6
@test count(==( :recycled_metal_output), metal_projection.quantity_kind) == 6
@test count(==( :primary_metal_output), metal_projection.quantity_kind) == 6
@test sum(metal_projection.tonnes[metal_projection.quantity_kind .== :primary_metal_output]) > 0.0
@test count(==( :external_metal_import), metal_projection.quantity_kind) == 1
@test count(==( :other_industry_metal_demand), metal_projection.quantity_kind) > 0
@test count(==( :ce_route_metal_demand), metal_projection.quantity_kind) > 0
@test count(==( :external_metal_export), metal_projection.quantity_kind) > 0
metal_supply = sum(metal_projection.tonnes[in.(metal_projection.quantity_kind,
    Ref([:external_metal_import, :primary_metal_output, :recycled_metal_output]))])
metal_demand = sum(metal_projection.tonnes[in.(metal_projection.quantity_kind,
    Ref([:ce_route_metal_demand, :other_industry_metal_demand, :final_metal_demand,
        :external_metal_export, :metal_inventory_change]))])
@test isapprox(metal_supply, metal_demand; atol = 1.0e-6, rtol = 1.0e-10)
metal_report = circular_metal_calibration_report(metal_result, metal_model)
@test nrow(metal_report) > 160
@test maximum(abs, metal_report.absolute_error_tonnes) < 1.0
metal_physical_report = physical_baseline_report(metal_result, metal_model)
@test metal_physical_report.circular_metal !== nothing
@test nrow(metal_physical_report.circular_metal.projection) == nrow(metal_projection)

summary = summary_row(model)
@test summary.regions == 6
@test summary.industries == 150
@test summary.observed_physical_flow_rows == 78
