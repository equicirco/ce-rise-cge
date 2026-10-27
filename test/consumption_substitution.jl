module ConsumptionSubstitutionChecks

using Test
using CERiseCGE
using JCGEBlocks
using JCGECore
using JCGERuntime
using JuMP

const DEMAND_TAGS = Set((:regional_household_demand, :circular_service_price,
    :circular_service_demand, :circular_route_demand, :regional_consumption_ces_price,
    :regional_household_price_index, :common_household_price_index, :regional_circular_utility))

start(ctx, name) = JuMP.start_value(ctx.variables[name])
setstart(ctx, name, value) = JuMP.set_start_value(ctx.variables[name], value)
equation(ctx, tag, indices) = only(eq for eq in ctx.equations
    if eq.tag == tag && eq.payload.indices == indices)
rhs(ctx, tag, indices, lhs) = start(ctx, lhs) - equation(ctx, tag, indices).payload.residual

function ces_price(weights, prices, elasticity)
    return isone(elasticity) ? prod(prices .^ weights) :
        sum(weights .* prices .^ (1.0 - elasticity))^(1.0 / (1.0 - elasticity))
end

function spending(ctx, model, region; policy=false)
    outline = model.outline
    income = sum(start(ctx, JCGEBlocks.global_var(:pf, factor)) *
        start(ctx, JCGEBlocks.global_var(:F, factor, activity))
        for factor in outline.factors_by_region[region], activity in outline.industries_by_region[region])
    income -= start(ctx, JCGEBlocks.global_var(:Sp, region)) + start(ctx, JCGEBlocks.global_var(:Td, region))
    return income + (policy ? start(ctx, JCGEBlocks.global_var(:POLICY_TRANSFER, region)) : 0.0)
end

@testset "Upper consumption CES calibration and demand responses" begin
    bundle = default_calibration_bundle()
    @test length(sensitivity_profiles(bundle)) == 2187
    @test length(sensitivity_profiles(bundle)) * size(policy_wedge_grid(bundle), 1) == 43740
    for sigma in (0.5, 1.0, 2.0), route_sigma in (0.5, 1.0, 2.0), policy in (false, true)
        @testset "Upper=$sigma, access=$route_sigma, policy=$policy" begin
            values = Dict(key => 1.0 for key in SENSITIVITY_PARAMETER_KEYS)
            values[("final_demand", "consumption_elasticity")] = sigma
            values[("circular_routes", "service_elasticity")] = route_sigma
            profile = SensitivityProfile(:consumption_check, "Consumption-equation check", values)
            scenario = policy ? eu_wide_policy_scenario(:refurbishment_support, -0.02; bundle) : baseline_scenario()
            model = multi_region_model(; bundle=sensitivity_bundle(profile; bundle), scenario)
            calibration = model.calibration
            routes = model.circular_routes
            @test routes.consumption_elasticity == sigma
            @test routes.service_elasticity == route_sigma
            spec = run_spec(model)
            @test spec.closure.numeraire == :P_HH_COMMON
            ctx = JCGERuntime.KernelContext(; model=JuMP.Model())
            for block in spec.model.blocks
                JCGECore.build!(block, ctx, spec)
            end
            filter!(eq -> eq.tag in DEMAND_TAGS, ctx.equations)
            JCGERuntime.evaluate_start_residuals!(ctx)
            references = Dict(region => spending(ctx, model, region; policy) for region in model.outline.regions)
            utility_reference = Dict(region => start(ctx, JCGEBlocks.global_var(:UU, region))
                for region in model.outline.regions)
            if !policy
                # All upper/lower elasticities reproduce the same calibration;
                # the explicit unitary branches are exercised too.
                for eq in ctx.equations
                    @test abs(eq.payload.residual) <= 1.0e-7 * max(1.0,
                        maximum(Base.values(utility_reference)), maximum(Base.values(references)))
                end
                @test !haskey(ctx.variables, JCGEBlocks.global_var(:POLICY_TRANSFER, :DE))
            end

            # Perturb purchaser prices and disposable income independently.
            # This evaluates registered equations, without invoking a solver.
            for region in model.outline.regions
                if policy
                    setstart(ctx, JCGEBlocks.global_var(:POLICY_TRANSFER, region), -0.05 * references[region])
                end
                for (index, good) in enumerate(routes.nonservice_goods_by_region[region])
                    setstart(ctx, JCGEBlocks.global_var(:pq, good), 1.02 + 0.02 * mod(index, 3))
                end
            end
            for service in routes.services
                goods = routes.route_goods_by_service[service]
                effective = Dict{Symbol,Float64}()
                for (route, good) in goods
                    price = Dict(:NEW => 1.1, :REF => 0.8, :REP => 0.9, :REU => 0.95)[route]
                    setstart(ctx, JCGEBlocks.global_var(:pq, good), price)
                    effective[route] = price * CERiseCGE._route_policy_multiplier(scenario, route)
                end
                ordered = sort!(collect(keys(goods)))
                price = ces_price([routes.route_share[(service, goods[route])] for route in ordered],
                    [effective[route] for route in ordered], route_sigma)
                setstart(ctx, JCGEBlocks.global_var(:P_CIRCULAR_SERVICE, service), price)
            end
            for region in model.outline.regions
                services = filter(service -> routes.service_region[service] == region, routes.services)
                other = routes.nonservice_goods_by_region[region]
                weights = [calibration.household_share[good] for good in other]
                append!(weights, [routes.service_share[service] for service in services])
                prices = [start(ctx, JCGEBlocks.global_var(:pq, good)) for good in other]
                append!(prices, [start(ctx, JCGEBlocks.global_var(:P_CIRCULAR_SERVICE, service)) for service in services])
                setstart(ctx, JCGEBlocks.global_var(:P_HH_CES, region), ces_price(weights, prices, sigma))
                setstart(ctx, JCGEBlocks.global_var(:P_HH, region), sum(weights .* prices))
            end
            setstart(ctx, :P_HH_COMMON, sum(calibration.common_price_weight[region] *
                start(ctx, JCGEBlocks.global_var(:P_HH, region)) for region in model.outline.regions))
            JCGERuntime.evaluate_start_residuals!(ctx)

            for region in model.outline.regions
                expenditure = spending(ctx, model, region; policy)
                index = start(ctx, JCGEBlocks.global_var(:P_HH_CES, region))
                purchases = 0.0
                for good in routes.nonservice_goods_by_region[region]
                    name = JCGEBlocks.global_var(:Xp, good)
                    price = start(ctx, JCGEBlocks.global_var(:pq, good))
                    quantity = rhs(ctx, :regional_household_demand, (good, region), name)
                    @test quantity ≈ calibration.household_share[good] * expenditure / index * (index / price)^sigma
                    if isone(sigma)
                        @test price * quantity / expenditure ≈ calibration.household_share[good]
                    end
                    setstart(ctx, name, quantity)
                    purchases += price * quantity
                end
                for service in filter(service -> routes.service_region[service] == region, routes.services)
                    name = JCGEBlocks.global_var(:Q_CIRCULAR_SERVICE, service)
                    price = start(ctx, JCGEBlocks.global_var(:P_CIRCULAR_SERVICE, service))
                    quantity = rhs(ctx, :circular_service_demand, (service,), name)
                    @test quantity ≈ routes.service_share[service] * expenditure / index * (index / price)^sigma
                    share = price * quantity / expenditure
                    if sigma > 1.0
                        @test (share - routes.service_share[service]) * (price - index) < 0.0
                    elseif sigma < 1.0
                        @test (share - routes.service_share[service]) * (price - index) > 0.0
                    else
                        @test share ≈ routes.service_share[service]
                    end
                    setstart(ctx, name, quantity)
                    purchases += price * quantity
                end
                @test purchases ≈ expenditure
                @test abs(equation(ctx, :regional_consumption_ces_price, (region,)).payload.residual) < 1.0e-10
                @test abs(equation(ctx, :regional_household_price_index, (region,)).payload.residual) < 1.0e-10
            end

            # Within-family quantities still obey their own CES and exhaust
            # each family's endogenous upper-level allocation.
            JCGERuntime.evaluate_start_residuals!(ctx)
            for service in routes.services
                price = start(ctx, JCGEBlocks.global_var(:P_CIRCULAR_SERVICE, service))
                quantity = start(ctx, JCGEBlocks.global_var(:Q_CIRCULAR_SERVICE, service))
                purchases = 0.0
                for (route, good) in routes.route_goods_by_service[service]
                    purchaser_price = start(ctx, JCGEBlocks.global_var(:pq, good)) *
                        CERiseCGE._route_policy_multiplier(scenario, route)
                    name = JCGEBlocks.global_var(:Xp, good)
                    route_quantity = rhs(ctx, :circular_route_demand, (service, good), name)
                    @test route_quantity ≈ routes.route_share[(service, good)] *
                        (purchaser_price / price)^(-route_sigma) * quantity
                    setstart(ctx, name, route_quantity)
                    purchases += purchaser_price * route_quantity
                end
                @test purchases ≈ price * quantity
                @test abs(equation(ctx, :circular_service_price, (service,)).payload.residual) < 1.0e-10
            end
            JCGERuntime.evaluate_start_residuals!(ctx)
            for region in model.outline.regions
                expected = utility_reference[region] * spending(ctx, model, region; policy) /
                    references[region] / start(ctx, JCGEBlocks.global_var(:P_HH_CES, region))
                @test rhs(ctx, :regional_circular_utility, (region,), JCGEBlocks.global_var(:UU, region)) ≈ expected
            end
        end
    end
end

end
