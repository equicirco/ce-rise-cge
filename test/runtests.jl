using Test
using DataFrames: nrow
using CERiseCGE
using JCGEBlocks
using JCGECore
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
@test nrow(model.coefficient_template) == 138
@test nrow(model.quantity_template) == 132
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
@test solver.ipopt_tolerance == 1.0e-6
@test solver.ipopt_acceptable_tolerance == 1.0e-6
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

baseline_result = run_baseline(model)
@test JuMP.termination_status(baseline_result.context.model) == JuMP.MOI.LOCALLY_SOLVED
@test JuMP.primal_status(baseline_result.context.model) == JuMP.MOI.FEASIBLE_POINT
@test baseline_result.summary.above_tol == 0

summary = summary_row(model)
@test summary.regions == 6
@test summary.industries == 150
