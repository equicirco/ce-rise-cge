using Test
using DataFrames: nrow
using CERiseCGE

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
@test [block_kind(block) for block in spec.model.blocks] == collect(MULTI_REGION_BLOCK_KINDS)

summary = summary_row(model)
@test summary.regions == 6
@test summary.industries == 150
