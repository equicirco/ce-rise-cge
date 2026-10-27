using Test
using CERiseCGE
using JCGEBlocks
using JCGECore
using JCGERuntime
using JuMP

@testset "Primary-metal tax with and without recycled inputs" begin
    source = default_calibration_bundle()
    single = :IND_SK_NEW_OFMA
    mixed = :IND_DE_NEW_ELMA
    untaxed = :IND_SK_REP_OFMA
    scenarios = [baseline_scenario();
        [eu_wide_policy_scenario(:virgin_metal_tax, wedge; bundle=source)
            for wedge in (0.0, 0.0025, 0.005, 0.01, 0.02)];
        eu_wide_policy_scenario(:recycling_support, -0.02; bundle=source)]

    start(ctx, name) = JuMP.start_value(ctx.variables[name])
    equation(ctx, tag, indices) = only(filter(eq ->
        eq.tag === tag && eq.payload.indices == indices, ctx.equations))
    rhs(ctx, tag, indices, name) = start(ctx, name) -
        equation(ctx, tag, indices).payload.residual

    for elasticity in (0.5, 1.0, 2.0), scenario in scenarios
        @testset "Metal elasticity=$elasticity, $(scenario.name)" begin
            parameters = Dict(key => 1.0 for key in SENSITIVITY_PARAMETER_KEYS)
            parameters[("circular_metal", "material_substitution_elasticity")] = elasticity
            profile = SensitivityProfile(:primary_tax_test,
                "Primary-only and mixed-metal tax regression check", parameters)
            model = multi_region_model(; bundle=sensitivity_bundle(profile; bundle=source), scenario)
            calibration = model.calibration
            structure = circular_material_structure(model)
            routes = model.circular_routes
            eligible = CERiseCGE._policy_primary_tax_activities(routes, structure)
            supported = CERiseCGE._policy_recycled_support_activities(routes, structure)
            expected = Set(goods[:NEW] for goods in values(routes.route_goods_by_service))
            @test eligible == expected
            @test length(eligible) == 18
            @test single in eligible && mixed in eligible && untaxed ∉ eligible
            @test single ∉ supported && mixed in supported
            @test !haskey(structure.recycled_good, single)
            sk_primary = calibration.product_by_region[(:SK, :BASIC_METALS)]
            sk_recycled = calibration.product_by_region[(:SK, :REC_EE)]
            @test calibration.intermediate_coefficient[(sk_primary, single)] > 0.0
            @test calibration.intermediate_coefficient[(sk_recycled, single)] == 0.0
            @test CERiseCGE._material_input_goods(structure, single) == (sk_primary,)

            spec = run_spec(model)
            ctx = JCGERuntime.KernelContext(; model=JuMP.Model())
            for block in spec.model.blocks
                JCGECore.build!(block, ctx, spec)
            end
            filter!(eq -> eq.tag in (:material_composite_price, :material_composite_demand,
                :eqX, :eqpzs, :circular_policy_revenue, :circular_policy_support,
                :circular_policy_transfer), ctx.equations)
            JCGERuntime.evaluate_start_residuals!(ctx)

            tax = policy_wedge(scenario, :virgin_metal_tax)
            support = -policy_wedge(scenario, :recycling_support)
            base_price = calibration_option_number(model.outline.bundle, "normalization", "base_price")
            for activity in (single, mixed)
                goods = CERiseCGE._material_input_goods(structure, activity)
                prices = [base_price * (good === structure.primary_good[activity] ?
                    1.0 + tax : 1.0 - support) for good in goods]
                expected_price = length(goods) == 1 ? only(prices) :
                    isone(elasticity) ? prod(price^structure.share[(activity, good)]
                        for (good, price) in zip(goods, prices)) :
                    sum(structure.share[(activity, good)] * price^(1.0 - elasticity)
                        for (good, price) in zip(goods, prices))^(1.0 / (1.0 - elasticity))
                price_id = JCGEBlocks.global_var(:P_MATERIAL_COMPOSITE, activity)
                @test isapprox(rhs(ctx, :material_composite_price, (activity,), price_id),
                    expected_price; rtol=1.0e-12)
                JuMP.set_start_value(ctx.variables[price_id], expected_price)
                JCGERuntime.evaluate_start_residuals!(ctx)
                @test abs(equation(ctx, :material_composite_price, (activity,)).payload.residual) <= 1.0e-12
                output = calibration.activity_output[activity]
                expected_cost = start(ctx, JCGEBlocks.global_var(:pz, activity)) +
                    structure.coefficient[activity] * (expected_price - base_price)
                @test isapprox(rhs(ctx, :eqpzs, (activity,), JCGEBlocks.global_var(:pz, activity)),
                    expected_cost; rtol=1.0e-10)
                quantities = [rhs(ctx, :material_composite_demand, (activity, good),
                    JCGEBlocks.global_var(:X, good, activity)) for good in goods]
                @test isapprox(sum(prices .* quantities),
                    expected_price * structure.coefficient[activity] * output; rtol=1.0e-10)
                if activity === single
                    @test isapprox(only(quantities),
                        calibration.intermediate_coefficient[(sk_primary, single)] * output; rtol=1.0e-12)
                    @test rhs(ctx, :eqX, (sk_recycled, single),
                        JCGEBlocks.global_var(:X, sk_recycled, single)) == 0.0
                end
            end
            @test abs(equation(ctx, :eqpzs, (untaxed,)).payload.residual) <= 1.0e-9

            if scenario.name !== :baseline
                for region in model.outline.regions
                    primary = calibration.product_by_region[(region, :BASIC_METALS)]
                    recycled = calibration.product_by_region[(region, :REC_EE)]
                    region_new = [goods[:NEW] for (service, goods) in routes.route_goods_by_service
                        if routes.service_region[service] === region]
                    expected_revenue = tax * sum(base_price * start(ctx,
                        JCGEBlocks.global_var(:X, primary, activity)) for activity in region_new)
                    expected_support = support * sum(base_price * start(ctx,
                        JCGEBlocks.global_var(:X, recycled, activity))
                        for activity in structure.activities_by_region[region] if activity in supported)
                    revenue_id = JCGEBlocks.global_var(:POLICY_REVENUE, region)
                    support_id = JCGEBlocks.global_var(:POLICY_SUPPORT, region)
                    transfer_id = JCGEBlocks.global_var(:POLICY_TRANSFER, region)
                    @test isapprox(rhs(ctx, :circular_policy_revenue, (region,), revenue_id),
                        expected_revenue; atol=1.0e-10, rtol=1.0e-12)
                    @test isapprox(rhs(ctx, :circular_policy_support, (region,), support_id),
                        expected_support; atol=1.0e-10, rtol=1.0e-12)
                    JuMP.set_start_value(ctx.variables[revenue_id], expected_revenue)
                    JuMP.set_start_value(ctx.variables[support_id], expected_support)
                    JuMP.set_start_value(ctx.variables[transfer_id], expected_revenue - expected_support)
                end
                JCGERuntime.evaluate_start_residuals!(ctx)
                @test all(abs(eq.payload.residual) <= 1.0e-9 for eq in ctx.equations
                    if eq.tag === :circular_policy_transfer)

                if tax > 0.0
                    # Fiscal receipts follow current purchases, including the
                    # formerly omitted primary-only activity, rather than a
                    # fixed calibration-value transfer.
                    input_id = JCGEBlocks.global_var(:X, sk_primary, single)
                    initial = start(ctx, input_id)
                    revenue_id = JCGEBlocks.global_var(:POLICY_REVENUE, :SK)
                    revenue = start(ctx, revenue_id)
                    JuMP.set_start_value(ctx.variables[input_id], 1.25 * initial)
                    JCGERuntime.evaluate_start_residuals!(ctx)
                    @test isapprox(rhs(ctx, :circular_policy_revenue, (:SK,), revenue_id),
                        revenue + tax * base_price * 0.25 * initial; rtol=1.0e-12)
                end
            end
        end
    end
end
