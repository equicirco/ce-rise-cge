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
@test nrow(model.coefficient_template) == 132
@test nrow(model.quantity_template) == 126
@test length(model.calibration.products) == 25
@test length(model.calibration.trade_routes) == 1132
@test model.calibration.positive_lower == 1.0e-8
solver = solver_configuration(model)
@test solver.ipopt_bound_push_share == 0.01
@test solver.ipopt_bound_push > 0.0
@test solver.ipopt_bound_push < model.calibration.positive_lower
@test solver.equation_scaling_floor == 1.0
@test solver.ipopt_hessian_approximation == "limited-memory"
@test solver.ipopt_bound_mult_init_method == "mu-based"
@test solver.ipopt_mu_init == 1.0e-8
@test solver.ipopt_tolerance == 1.0e-8
@test solver.ipopt_acceptable_tolerance == 1.0e-8
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
blocks = multi_region_blocks(model.outline, model.calibration, model.scenario)
@test length(blocks.production) == 6
@test blocks.factor_availability isa JCGEBlocks.RegionalFactorAvailabilityBlock
@test blocks.trade isa JCGEBlocks.MultiRegionTradeBlock
@test blocks.market_clearing isa JCGEBlocks.RegionalCompositeMarketClearingBlock
@test blocks.numeraire isa JCGEBlocks.NumeraireBlock
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
        prod(
            model.calibration.household_demand[good]^model.calibration.household_share[good]
            for good in outline.industries_by_region[region]
        );
        atol = 1.0e-8,
    )
    for region in outline.regions
)
@test length(spec.model.blocks) == length(blocks.production) + length(MULTI_REGION_BLOCK_KINDS) - 1

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
@test count(equation -> equation.tag == :quantity_link, ctx.equations) == 78

baseline_result = run_baseline(model)
@test JuMP.termination_status(baseline_result.context.model) == JuMP.MOI.LOCALLY_SOLVED
@test JuMP.primal_status(baseline_result.context.model) == JuMP.MOI.FEASIBLE_POINT
@test baseline_result.summary.above_tol == 0

physical_spec = physical_satellite_spec(model)
@test nrow(physical_spec.quantity_bridge) == 126
@test nrow(physical_spec.coefficients) == 132
@test nrow(physical_spec.observed_flows) == 78
physical_readiness = physical_satellite_readiness(model)
@test !physical_readiness.ready
@test !physical_readiness.quantity_value_column
@test !physical_readiness.coefficient_value_column
@test physical_readiness.template_quantity_rows == 126
@test physical_readiness.template_coefficient_rows == 132
@test physical_readiness.model_anchor_rows == 84
@test physical_readiness.unbound_anchor_rows == 42
@test physical_readiness.observed_flow_rows == 78
@test physical_readiness.observed_new_output_rows == 18
@test physical_readiness.observed_anchor_ready
physical_indices = physical_quantity_indices(baseline_result, model)
@test nrow(physical_indices) == 126
@test count(==( :index_available), physical_indices.status) == 84
@test count(==( :requires_ce_account), physical_indices.status) == 48
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

summary = summary_row(model)
@test summary.regions == 6
@test summary.industries == 150
@test summary.observed_physical_flow_rows == 78
