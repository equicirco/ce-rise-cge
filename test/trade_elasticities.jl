using Test
using CERiseCGE
using JCGEBlocks
using JCGECore
using JCGERuntime
using JuMP

@testset "CET destination response and Armington sourcing" begin
    bundle = default_calibration_bundle()
    trade_tags = Set((:eu_cet_quantity, :eu_cet_allocation,
        :eu_armington_quantity, :eu_armington_allocation))

    # Exercise the registered model equations at calibrated quantities and
    # perturbed prices. No optimizer or policy-scenario run is needed.
    for sigma in (0.5, 1.0, 2.0), psi in (0.5, 1.0, 2.0)
        @testset "Armington=$sigma, CET=$psi" begin
            values = Dict(key => 1.0 for key in SENSITIVITY_PARAMETER_KEYS)
            values[("trade", "armington_elasticity")] = sigma
            values[("trade", "cet_transformation_elasticity")] = psi
            profile = SensitivityProfile(:trade_response_test,
                "Independent trade-elasticity regression check", values)
            model = multi_region_model(; bundle=sensitivity_bundle(profile; bundle))
            spec = run_spec(model)
            ctx = JCGERuntime.KernelContext(; model=JuMP.Model())
            for block in spec.model.blocks
                JCGECore.build!(block, ctx, spec)
            end
            filter!(equation -> equation.tag in trade_tags, ctx.equations)
            JCGERuntime.evaluate_start_residuals!(ctx)

            # All calibrated EU/ROW quantity aggregators and allocation
            # equations must reproduce their reference quantities.
            expected = 6 * length(CERiseCGE.EU_TRADED_PRODUCTS) * length(model.outline.regions)
            @test length(ctx.equations) == expected
            for equation in ctx.equations
                product, region = equation.payload.indices[1:2]
                good = model.calibration.product_by_region[(region, product)]
                scale = max(1.0, model.calibration.activity_output[good],
                    model.calibration.household_demand[good] +
                    model.calibration.government_demand[good] +
                    model.calibration.fixed_investment_demand[good])
                @test abs(equation.payload.residual) <= 1.0e-9 * scale
            end

            trade, _ = CERiseCGE.common_eu_trade_calibration(model.calibration)
            allocations = Dict((equation.tag, equation.payload.indices) => index
                for (index, equation) in enumerate(ctx.equations)
                if equation.tag in (:eu_cet_allocation, :eu_armington_allocation))
            base_prices = Dict(product => JuMP.start_value(ctx.variables[
                JCGEBlocks.global_var(:pEU, product)])
                for product in trade.traded_products)

            for price_factor in (0.99, 1.01)
                for product in trade.traded_products
                    JuMP.set_start_value(ctx.variables[JCGEBlocks.global_var(:pEU, product)],
                        base_prices[product] * price_factor)
                end
                JCGERuntime.evaluate_start_residuals!(ctx)
                for product in trade.traded_products, region in model.outline.regions
                    export_route = trade.row_export_route[(product, region)]
                    import_route = trade.row_import_route[(product, region)]
                    sale_eu = JuMP.start_value(ctx.variables[
                        JCGEBlocks.global_var(:EU_SALE, product, region)])
                    sale_row = JuMP.start_value(ctx.variables[
                        JCGEBlocks.global_var(:T, export_route.id)])
                    purchase_eu = JuMP.start_value(ctx.variables[
                        JCGEBlocks.global_var(:EU_PURCHASE, product, region)])
                    purchase_row = JuMP.start_value(ctx.variables[
                        JCGEBlocks.global_var(:T, import_route.id)])

                    # LHS quantities retain their calibrated starts. Subtract
                    # the residual to recover the allocation RHS at each price.
                    residual(tag, destination) = ctx.equations[
                        allocations[(tag, (product, region, destination))]].payload.residual
                    sales_ratio = (sale_eu - residual(:eu_cet_allocation, :EU)) /
                        (sale_row - residual(:eu_cet_allocation, :ROW))
                    purchases_ratio = (purchase_eu - residual(:eu_armington_allocation, :EU)) /
                        (purchase_row - residual(:eu_armington_allocation, :ROW))
                    sales_change = sales_ratio / (sale_eu / sale_row)
                    purchases_change = purchases_ratio / (purchase_eu / purchase_row)

                    @test isapprox(sales_change, price_factor^psi; rtol=1.0e-10)
                    @test isapprox(purchases_change, price_factor^(-sigma); rtol=1.0e-10)
                    @test price_factor > 1.0 ? sales_change > 1.0 : sales_change < 1.0
                    @test price_factor > 1.0 ? purchases_change < 1.0 : purchases_change > 1.0
                end
            end
        end
    end
end
