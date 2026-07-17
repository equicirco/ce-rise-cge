"""
Standard JCGE block assembly for the calibrated six-region model.

All coefficients and initial values are derived from `MultiRegionCalibration`.
The circular-economy route extensions are added only after this standard
multi-region baseline replicates the calibration data.
"""

const MULTI_REGION_BLOCK_KINDS = (
    :production,
    :physical_quantity_links,
    :factor_availability,
    :price_index,
    :private_saving,
    :household_demand,
    :government_demand,
    :fixed_investment,
    :trade,
    :external_account,
    :investment_pool,
    :market_clearing,
    :utility,
    :initial_values,
    :numeraire,
)

_regional_goods(outline::MultiRegionOutline) = outline.industries_by_region

function _output_tax_by_good(calibration::MultiRegionCalibration)
    return Dict(
        calibration.product_by_region[(region, product)] =>
            calibration.output_tax[(product, region)]
        for region in region_codes(calibration.bundle) for product in calibration.products
    )
end

function _initial_value_parameters(outline::MultiRegionOutline,
    calibration::MultiRegionCalibration)
    base_price = calibration_option_number(calibration.bundle, "normalization", "base_price")
    start = Dict{Symbol,Float64}()

    for region in outline.regions
        activities = outline.industries_by_region[region]
        factors = outline.factors_by_region[region]
        for activity in activities
            output = calibration.activity_output[activity]
            start[JCGEBlocks.global_var(:Z, activity)] = output
            start[JCGEBlocks.global_var(:Y, activity)] =
                calibration.value_added_coefficient[activity] * output
            start[JCGEBlocks.global_var(:py, activity)] = base_price
            start[JCGEBlocks.global_var(:pz, activity)] = base_price * (
                calibration.value_added_coefficient[activity] +
                sum(calibration.intermediate_coefficient[(commodity, activity)]
                    for commodity in activities))
            for factor in factors
                start[JCGEBlocks.global_var(:F, factor, activity)] =
                    calibration.factor_payment[(factor, activity)]
            end
            for commodity in activities
                start[JCGEBlocks.global_var(:X, commodity, activity)] =
                    calibration.intermediate_coefficient[(commodity, activity)] * output
            end
        end
        for factor in factors
            start[JCGEBlocks.global_var(:pf, factor)] = calibration.real_factor_price[factor]
        end
        for good in activities
            start[JCGEBlocks.global_var(:pq, good)] = base_price
            start[JCGEBlocks.global_var(:Xp, good)] = calibration.household_demand[good]
            start[JCGEBlocks.global_var(:Xg, good)] = calibration.government_demand[good]
            start[JCGEBlocks.global_var(:Xv, good)] = calibration.fixed_investment_demand[good]
            start[JCGEBlocks.global_var(:Q, good)] =
                sum(calibration.intermediate_coefficient[(good, activity)] *
                    calibration.activity_output[activity] for activity in activities) +
                calibration.household_demand[good] +
                calibration.government_demand[good] +
                calibration.fixed_investment_demand[good]
        end
        start[JCGEBlocks.global_var(:UU, region)] = prod(
            calibration.household_demand[good]^calibration.household_share[good]
            for good in activities
        )
        start[JCGEBlocks.global_var(:P_HH, region)] = base_price
        start[JCGEBlocks.global_var(:Td, region)] = calibration.direct_tax_value[region]
        start[JCGEBlocks.global_var(:Sp, region)] = calibration.private_saving[region]
        start[JCGEBlocks.global_var(:Sg, region)] = calibration.government_saving[region]
        start[JCGEBlocks.global_var(:FSAV, region)] = calibration.foreign_saving[region]
        start[JCGEBlocks.global_var(:INV, region)] = calibration.investment_spending[region]
        start[JCGEBlocks.global_var(:INV_POOL, region)] = calibration.investment_pool_transfer[region]
    end

    for route in calibration.trade_routes
        seller_price = (route.origin == :ROW || route.destination == :ROW) ?
            calibration.world_price[route.id] : base_price
        start[JCGEBlocks.global_var(:T, route.id)] = calibration.trade_value[route.id]
        start[JCGEBlocks.global_var(:pS, route.id)] = seller_price
        start[JCGEBlocks.global_var(:pD, route.id)] =
            calibration.delivery_wedge[route.id] * seller_price
    end

    for region in outline.regions, product in calibration.products
        good = calibration.product_by_region[(region, product)]
        start[JCGEBlocks.global_var(:Tz, good)] =
            calibration.production_tax_value[good]
    end
    physical_links = _physical_flow_link_data(outline.bundle, calibration)
    for quantity in physical_links.quantities
        start[JCGEBlocks.global_var(:physical_flow, quantity)] =
            1.0
    end
    start[:P_HH_COMMON] = base_price
    return (start = start,)
end

"""
    multi_region_blocks(outline, calibration, scenario)

Return the standard six-region model as a named collection of generic JCGE
blocks. The policy scenarios are declared in this repository but become
solvable only once their circular-economy extension blocks are added.
"""
function multi_region_blocks(outline::MultiRegionOutline,
    calibration::MultiRegionCalibration,
    scenario::PolicyScenario)
    calibration.bundle.name == outline.bundle.name ||
        error("Model outline and calibration bundle differ.")
    scenario.name === :baseline ||
        error("Policy scenarios require the circular-economy extension blocks, which are not yet assembled.")

    regions = outline.regions
    goods_by_region = _regional_goods(outline)
    base_price = calibration_option_number(calibration.bundle, "normalization", "base_price")
    positive_lower = calibration.positive_lower
    inventory = JCGEBlocks.inventory_treatment(:stock_change)

    production_params = (
        b = calibration.production_scale,
        beta = calibration.factor_share,
        ay = calibration.value_added_coefficient,
        ax = calibration.intermediate_coefficient,
        positive_lower = positive_lower,
    )
    production = Any[
        JCGEBlocks.production(
            Symbol(:production_, region),
            outline.industries_by_region[region],
            outline.factors_by_region[region],
            outline.industries_by_region[region];
            form = :cd_leontief,
            params = production_params,
        )
        for region in regions
    ]
    physical_quantity_links = observed_physical_quantity_links(
        outline.bundle,
        calibration,
    )

    price_index = JCGEBlocks.regional_price_index(
        :household_price_index,
        regions,
        goods_by_region;
        price_var = :pq,
        index_var = :P_HH,
        common_index_var = :P_HH_COMMON,
        params = (
            weight = calibration.price_weight,
            common_weight = calibration.common_price_weight,
            positive_lower = positive_lower,
        ),
    )
    factor_availability = JCGEBlocks.regional_factor_availability(
        :regional_factor_availability,
        regions,
        outline.factors_by_region,
        outline.industries_by_region;
        factor_input = :F,
        factor_price = :pf,
        price_index = :P_HH,
        params = (
            endowment = calibration.factor_endowment,
            real_price = calibration.real_factor_price,
            positive_lower = positive_lower,
        ),
    )
    private_saving = JCGEBlocks.regional_private_saving_income(
        :regional_private_saving,
        regions,
        outline.factors_by_region,
        outline.industries_by_region;
        factor_input = :F,
        factor_price = :pf,
        saving_var = :Sp,
        direct_tax_var = :Td,
        params = (ssp = calibration.private_saving_share, positive_lower = positive_lower),
    )
    household_demand = JCGEBlocks.regional_household_income_demand(
        :regional_household_demand,
        regions,
        goods_by_region,
        outline.factors_by_region,
        outline.industries_by_region;
        factor_input = :F,
        factor_price = :pf,
        composite_price = :pq,
        consumption_var = :Xp,
        saving_var = :Sp,
        direct_tax_var = :Td,
        params = (alpha = calibration.household_demand_share, positive_lower = positive_lower),
    )
    government_demand = JCGEBlocks.regional_government_demand(
        :regional_government_demand,
        regions,
        goods_by_region,
        outline.factors_by_region,
        outline.industries_by_region;
        factor_input = :F,
        factor_price = :pf,
        output_var = :Z,
        output_price = :pz,
        composite_price = :pq,
        consumption_var = :Xg,
        direct_tax_var = :Td,
        output_tax_var = :Tz,
        saving_var = :Sg,
        params = (
            tau_d = calibration.direct_tax_rate,
            tau_z = _output_tax_by_good(calibration),
            mu = calibration.government_share,
            ssg = calibration.government_saving_share,
            positive_lower = positive_lower,
        ),
    )
    fixed_investment = JCGEBlocks.regional_fixed_investment_demand(
        :regional_fixed_investment,
        regions,
        goods_by_region;
        quantity_var = :Xv,
        params = (quantity = calibration.fixed_investment_demand,),
    )
    trade = JCGEBlocks.multiregion_trade(
        :bilateral_trade,
        regions,
        calibration.trade_routes,
        calibration.trade_goods;
        output_var = :Z,
        output_price_var = :pz,
        composite_var = :Q,
        composite_price_var = :pq,
        flow_var = :T,
        seller_price_var = :pS,
        delivered_price_var = :pD,
        inventory = inventory,
        params = (
            armington_scale = calibration.armington_scale,
            armington_share = calibration.armington_share,
            armington_exponent = calibration.armington_exponent,
            cet_scale = calibration.cet_scale,
            cet_share = calibration.cet_share,
            cet_exponent = calibration.cet_exponent,
            output_tax = calibration.output_tax,
            delivery_wedge = calibration.delivery_wedge,
            world_price = calibration.world_price,
            inventory_change = calibration.inventory_change,
            positive_lower = positive_lower,
        ),
    )
    external_account = JCGEBlocks.regional_external_account(
        :regional_external_account,
        regions,
        calibration.trade_routes;
        flow_var = :T,
        seller_price_var = :pS,
        foreign_saving_var = :FSAV,
    )
    investment_pool = JCGEBlocks.regional_investment_pool(
        :regional_investment_pool,
        regions,
        goods_by_region;
        private_saving_var = :Sp,
        government_saving_var = :Sg,
        foreign_saving_var = :FSAV,
        investment_quantity_var = :Xv,
        composite_price_var = :pq,
        investment_spending_var = :INV,
        pool_transfer_var = :INV_POOL,
        inventory = inventory,
        params = (
            inventory_change = calibration.inventory_change,
            positive_lower = positive_lower,
        ),
    )
    market_clearing = JCGEBlocks.regional_composite_market_clearing(
        :regional_composite_market,
        regions,
        goods_by_region,
        outline.industries_by_region;
        composite_var = :Q,
        intermediate_var = :X,
        household_var = :Xp,
        government_var = :Xg,
        fixed_investment_var = :Xv,
        inventory = inventory,
        params = (
            inventory_change = calibration.inventory_change,
            positive_lower = positive_lower,
        ),
    )
    utility = JCGEBlocks.utility_regional(
        :regional_household_utility,
        goods_by_region,
        (alpha = calibration.household_share,),
    )
    initial_values = JCGEBlocks.initial_values(
        :calibrated_initial_values,
        _initial_value_parameters(outline, calibration),
    )
    numeraire = JCGEBlocks.numeraire(
        :numeraire,
        outline.closure.kind,
        outline.closure.numeraire,
        base_price,
    )

    return (
        production = production,
        physical_quantity_links = physical_quantity_links,
        factor_availability = factor_availability,
        price_index = price_index,
        private_saving = private_saving,
        household_demand = household_demand,
        government_demand = government_demand,
        fixed_investment = fixed_investment,
        trade = trade,
        external_account = external_account,
        investment_pool = investment_pool,
        market_clearing = market_clearing,
        utility = utility,
        initial_values = initial_values,
        numeraire = numeraire,
    )
end
