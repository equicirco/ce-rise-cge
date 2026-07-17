"""
Calibration of the standard six-region monetary economy.

All numeric inputs are read from the calibration bundle.  The only numerical
normalisation is the base price declared in `model_configuration.tsv`.
"""

struct MultiRegionCalibration
    bundle::CalibrationBundle
    products::Vector{Symbol}
    product_by_region::Dict{Tuple{Symbol,Symbol},Symbol}
    activity_output::Dict{Symbol,Float64}
    marketed_output::Dict{Symbol,Float64}
    factor_payment::Dict{Tuple{Symbol,Symbol},Float64}
    factor_share::Dict{Tuple{Symbol,Symbol},Float64}
    factor_endowment::Dict{Symbol,Float64}
    real_factor_price::Dict{Symbol,Float64}
    production_scale::Dict{Symbol,Float64}
    value_added_coefficient::Dict{Symbol,Float64}
    intermediate_coefficient::Dict{Tuple{Symbol,Symbol},Float64}
    production_tax_value::Dict{Symbol,Float64}
    household_demand::Dict{Symbol,Float64}
    household_share::Dict{Symbol,Float64}
    household_demand_share::Dict{Tuple{Symbol,Symbol},Float64}
    household_total::Dict{Symbol,Float64}
    government_demand::Dict{Symbol,Float64}
    government_share::Dict{Tuple{Symbol,Symbol},Float64}
    fixed_investment_demand::Dict{Symbol,Float64}
    inventory_change::Dict{Symbol,Float64}
    inventory_spending::Dict{Symbol,Float64}
    direct_tax_value::Dict{Symbol,Float64}
    direct_tax_rate::Dict{Symbol,Float64}
    private_saving::Dict{Symbol,Float64}
    private_saving_share::Dict{Symbol,Float64}
    government_tax_revenue::Dict{Symbol,Float64}
    government_saving::Dict{Symbol,Float64}
    government_saving_share::Dict{Symbol,Float64}
    foreign_saving::Dict{Symbol,Float64}
    investment_spending::Dict{Symbol,Float64}
    investment_pool_transfer::Dict{Symbol,Float64}
    price_weight::Dict{Tuple{Symbol,Symbol},Float64}
    common_price_weight::Dict{Symbol,Float64}
    trade_routes::Vector{JCGEBlocks.TradeRoute}
    trade_goods::Dict{Tuple{Symbol,Symbol},Symbol}
    trade_value::Dict{Symbol,Float64}
    armington_scale::Dict{Tuple{Symbol,Symbol},Float64}
    armington_share::Dict{Symbol,Float64}
    armington_exponent::Dict{Tuple{Symbol,Symbol},Float64}
    cet_scale::Dict{Tuple{Symbol,Symbol},Float64}
    cet_share::Dict{Symbol,Float64}
    cet_exponent::Dict{Tuple{Symbol,Symbol},Float64}
    delivery_wedge::Dict{Symbol,Float64}
    world_price::Dict{Symbol,Float64}
    output_tax::Dict{Tuple{Symbol,Symbol},Float64}
    positive_lower::Float64
end

function calibration_option(bundle::CalibrationBundle, component::AbstractString, key::AbstractString)
    rows = filter(row -> String(row.component) == component && String(row.key) == key, bundle.configuration)
    nrow(rows) == 1 || error("Calibration bundle must contain one configuration value for $(component).$(key).")
    return String(only(rows.value))
end

calibration_option_number(bundle::CalibrationBundle, component::AbstractString, key::AbstractString) =
    parse(Float64, calibration_option(bundle, component, key))

function _account_code_map(bundle::CalibrationBundle, account_type::String)
    return Dict(
        (Symbol(row.region), Symbol(row.code)) => Symbol(row.account_id)
        for row in eachrow(bundle.accounts) if String(row.account_type) == account_type
    )
end

function _product_structure(bundle::CalibrationBundle)
    regions = region_codes(bundle)
    industry_map = _account_code_map(bundle, "industry")
    products = Symbol[]
    for row in eachrow(bundle.accounts)
        String(row.account_type) == "industry" || continue
        Symbol(row.region) == first(regions) || continue
        push!(products, Symbol(row.code))
    end
    isempty(products) && error("Calibration bundle has no industries in its first model region.")
    for region in regions, product in products
        haskey(industry_map, (region, product)) ||
            error("Missing industry account for $(region), $(product).")
    end
    return products, industry_map
end

function _sam_value(bundle::CalibrationBundle, row::Symbol, column::Symbol)
    row_idx = get(bundle.sam.row_index, row, nothing)
    col_idx = get(bundle.sam.col_index, column, nothing)
    row_idx === nothing && error("SAM row $(row) is absent from the calibration bundle.")
    col_idx === nothing && error("SAM column $(column) is absent from the calibration bundle.")
    return bundle.sam.data[row_idx, col_idx]
end

function _sam_row_total(bundle::CalibrationBundle, row::Symbol)
    row_idx = get(bundle.sam.row_index, row, nothing)
    row_idx === nothing && error("SAM row $(row) is absent from the calibration bundle.")
    return sum(@view bundle.sam.data[row_idx, :])
end

function _configuration_roles(bundle::CalibrationBundle)
    household = Set(Symbol.(split(calibration_option(bundle, "final_demand", "household_codes"), ';')))
    return (
        household = household,
        government = Symbol(calibration_option(bundle, "final_demand", "government_code")),
        fixed_investment = Symbol(calibration_option(bundle, "final_demand", "fixed_investment_code")),
        inventory_change = Symbol(calibration_option(bundle, "final_demand", "inventory_change_code")),
    )
end

function _use_values(bundle::CalibrationBundle, products, product_by_region, roles)
    regions = Set(region_codes(bundle))
    intermediate = Dict{Tuple{Symbol,Symbol},Float64}()
    household = Dict{Symbol,Float64}()
    government = Dict{Symbol,Float64}()
    fixed_investment = Dict{Symbol,Float64}()
    inventory_by_origin = Dict{Tuple{Symbol,Symbol},Float64}()

    for row in eachrow(bundle.product_use_registry)
        product = Symbol(row.product)
        origin = Symbol(row.origin)
        destination = Symbol(row.destination)
        kind = Symbol(row.use_kind)
        value = Float64(row.value_meur)
        product in products || error("Unknown product $(product) in the product-use registry.")

        if kind === :inventory_change
            inventory_by_origin[(product, origin)] = get(inventory_by_origin, (product, origin), 0.0) + value
            continue
        end
        destination in regions || continue
        commodity = product_by_region[(destination, product)]
        if kind === :intermediate
            activity = Symbol(row.use_target)
            intermediate[(commodity, activity)] = get(intermediate, (commodity, activity), 0.0) + value
        elseif kind === :household
            household[commodity] = get(household, commodity, 0.0) + value
        elseif kind === :government
            government[commodity] = get(government, commodity, 0.0) + value
        elseif kind === :fixed_investment
            fixed_investment[commodity] = get(fixed_investment, commodity, 0.0) + value
        else
            error("Unsupported product-use kind $(kind).")
        end
    end
    return intermediate, household, government, fixed_investment, inventory_by_origin
end

function _trade_groups(routes::Vector{JCGEBlocks.TradeRoute})
    supply = Dict{Tuple{Symbol,Symbol},Vector{JCGEBlocks.TradeRoute}}()
    demand = Dict{Tuple{Symbol,Symbol},Vector{JCGEBlocks.TradeRoute}}()
    for route in routes
        route.origin == :ROW || push!(get!(supply, (route.product, route.origin), JCGEBlocks.TradeRoute[]), route)
        route.destination == :ROW || push!(get!(demand, (route.product, route.destination), JCGEBlocks.TradeRoute[]), route)
    end
    return supply, demand
end

function _calibrated_cd_scale(total::Float64, routes, values::Dict{Symbol,Float64})
    shares = Dict(route.id => values[route.id] / total for route in routes)
    log_scale = log(total) - sum(shares[route.id] * log(values[route.id]) for route in routes)
    return shares, exp(log_scale)
end

function _calibrate_trade!(routes, values, supply, demand, products, product_by_region,
    activity_output, inventory_change, intermediate, household, government, fixed_investment,
    armington_exponent, cet_exponent, base_delivery_wedge, base_world_price, output_tax)
    goods = Dict{Tuple{Symbol,Symbol},Symbol}()
    armington_scale = Dict{Tuple{Symbol,Symbol},Float64}()
    armington_share = Dict{Symbol,Float64}()
    cet_scale = Dict{Tuple{Symbol,Symbol},Float64}()
    cet_share = Dict{Symbol,Float64}()
    delivery_wedge = Dict(route.id => base_delivery_wedge for route in routes)
    world_price = Dict(route.id => base_world_price for route in routes if route.origin == :ROW || route.destination == :ROW)

    for ((product, destination), group) in demand
        good = product_by_region[(destination, product)]
        goods[(product, destination)] = good
        total = sum(values[route.id] for route in group)
        total > 0.0 || error("Trade demand for $(product), $(destination) is not positive.")
        expected = get(household, good, 0.0) + get(government, good, 0.0) + get(fixed_investment, good, 0.0) +
                   sum(get(intermediate, (good, product_by_region[(destination, activity_product)]), 0.0) for activity_product in products)
        isapprox(total, expected; rtol = 1.0e-6, atol = 1.0e-6) ||
            error("Trade-demand calibration mismatch for $(product), $(destination): $(total) versus $(expected).")
        exponent = armington_exponent[(product, destination)]
        if iszero(exponent)
            shares, scale = _calibrated_cd_scale(total, group, values)
            merge!(armington_share, shares)
            armington_scale[(product, destination)] = scale
        else
            armington_scale[(product, destination)] = 1.0
            for route in group
                ratio = values[route.id] / total
                armington_share[route.id] = ratio^(1.0 - exponent)
            end
        end
    end

    for ((product, origin), group) in supply
        activity = product_by_region[(origin, product)]
        goods[(product, origin)] = activity
        observed = sum(values[route.id] for route in group)
        inventory = get(inventory_change, activity, 0.0)
        expected = activity_output[activity] - inventory
        expected > 0.0 || error("Marketed output for $(product), $(origin) is not positive.")
        isapprox(observed, expected; rtol = 1.0e-6, atol = 1.0e-6) ||
            error("Trade-supply calibration mismatch for $(product), $(origin): $(observed) versus $(expected).")
        exponent = cet_exponent[(product, origin)]
        haskey(output_tax, (product, origin)) ||
            error("Missing calibrated output-tax rate for $(product), $(origin).")
        if iszero(exponent)
            shares, scale = _calibrated_cd_scale(observed, group, values)
            merge!(cet_share, shares)
            cet_scale[(product, origin)] = scale
        else
            cet_scale[(product, origin)] = 1.0
            for route in group
                ratio = values[route.id] / observed
                cet_share[route.id] = ratio^(1.0 - exponent)
            end
        end
    end

    return goods, armington_scale, armington_share, cet_scale, cet_share,
           delivery_wedge, world_price, output_tax
end

function multi_region_calibration(bundle::CalibrationBundle = default_calibration_bundle())
    regions = region_codes(bundle)
    products, product_by_region = _product_structure(bundle)
    factors_by_code = _account_code_map(bundle, "factor")
    institutions_by_code = _account_code_map(bundle, "institution")
    roles = _configuration_roles(bundle)
    base_price = calibration_option_number(bundle, "normalization", "base_price")
    base_price > 0.0 || error("normalization.base_price must be strictly positive.")

    intermediate, household_demand, government_demand, fixed_investment_demand,
    inventory_by_origin = _use_values(
        bundle, products, product_by_region, roles)
    inventory_by_origin = Dict(key => value / base_price for (key, value) in inventory_by_origin)
    inventory_change = Dict{Symbol,Float64}()
    inventory_spending = Dict(region => 0.0 for region in regions)
    for region in regions, product in products
        good = product_by_region[(region, product)]
        change = get(inventory_by_origin, (product, region), 0.0)
        inventory_change[good] = change
        inventory_spending[region] += change
    end

    activity_output = Dict{Symbol,Float64}()
    factor_payment = Dict{Tuple{Symbol,Symbol},Float64}()
    factor_share = Dict{Tuple{Symbol,Symbol},Float64}()
    factor_endowment = Dict{Symbol,Float64}()
    real_factor_price = Dict{Symbol,Float64}()
    production_scale = Dict{Symbol,Float64}()
    value_added_coefficient = Dict{Symbol,Float64}()
    intermediate_coefficient = Dict{Tuple{Symbol,Symbol},Float64}()
    production_tax_value = Dict{Symbol,Float64}()
    marketed_output = Dict{Symbol,Float64}()
    output_tax_rate = Dict{Tuple{Symbol,Symbol},Float64}()

    for region in regions
        activities = [product_by_region[(region, product)] for product in products]
        factors = [factors_by_code[(region, :LAB)], factors_by_code[(region, :CAP)]]
        government_account = institutions_by_code[(region, :GOV)]
        for activity in activities
            output = _sam_row_total(bundle, activity)
            output > 0.0 || error("Activity $(activity) has non-positive calibration output.")
            activity_output[activity] = output / base_price
            value_added = 0.0
            for factor in factors
                payment = _sam_value(bundle, factor, activity)
                payment > 0.0 || error("Factor $(factor) has non-positive payment in $(activity).")
                factor_payment[(factor, activity)] = payment / base_price
                value_added += payment / base_price
            end
            value_added > 0.0 || error("Activity $(activity) has non-positive factor value added.")
            for factor in factors
                factor_share[(factor, activity)] = factor_payment[(factor, activity)] / value_added
            end
            value_added_coefficient[activity] = value_added / activity_output[activity]
            production_tax_value[activity] = _sam_value(bundle, government_account, activity) / base_price
            for commodity in activities
                input_value = get(intermediate, (commodity, activity), 0.0) / base_price
                intermediate_coefficient[(commodity, activity)] = input_value / activity_output[activity]
            end
            production_scale[activity] = value_added /
                prod(factor_payment[(factor, activity)]^factor_share[(factor, activity)] for factor in factors)
            product = only(filter(p -> product_by_region[(region, p)] == activity, products))
            marketed_output[activity] = activity_output[activity] - get(inventory_change, activity, 0.0)
            net_output_value = activity_output[activity] - production_tax_value[activity]
            net_output_value > 0.0 ||
                error("Activity $(activity) has non-positive output net of production taxes.")
            output_tax_rate[(product, region)] = production_tax_value[activity] / net_output_value
        end
        for factor in factors
            factor_endowment[factor] = sum(factor_payment[(factor, activity)] for activity in activities)
            real_factor_price[factor] = base_price
        end
    end

    household_total = Dict{Symbol,Float64}()
    household_share = Dict{Symbol,Float64}()
    household_demand_share = Dict{Tuple{Symbol,Symbol},Float64}()
    price_weight = Dict{Tuple{Symbol,Symbol},Float64}()
    for region in regions
        goods = [product_by_region[(region, product)] for product in products]
        total = sum(get(household_demand, good, 0.0) for good in goods) / base_price
        total > 0.0 || error("Household consumption is not positive in $(region).")
        household_total[region] = total
        for good in goods
            demand = get(household_demand, good, 0.0) / base_price
            demand > 0.0 || error("Household demand for $(good) is not positive.")
            household_demand[good] = demand
            household_share[good] = demand / total
            household_demand_share[(good, region)] = household_share[good]
            price_weight[(good, region)] = household_share[good]
            government_demand[good] = get(government_demand, good, 0.0) / base_price
            fixed_investment_demand[good] = get(fixed_investment_demand, good, 0.0) / base_price
        end
    end
    all_household = sum(values(household_total))
    common_price_weight = Dict(region => household_total[region] / all_household for region in regions)

    direct_tax_value = Dict{Symbol,Float64}()
    direct_tax_rate = Dict{Symbol,Float64}()
    private_saving = Dict{Symbol,Float64}()
    private_saving_share = Dict{Symbol,Float64}()
    government_tax_revenue = Dict{Symbol,Float64}()
    government_saving = Dict{Symbol,Float64}()
    government_saving_share = Dict{Symbol,Float64}()
    government_share = Dict{Tuple{Symbol,Symbol},Float64}()
    for region in regions
        household_account = institutions_by_code[(region, :HH)]
        government_account = institutions_by_code[(region, :GOV)]
        activities = [product_by_region[(region, product)] for product in products]
        factors = [factors_by_code[(region, :LAB)], factors_by_code[(region, :CAP)]]
        factor_income = sum(factor_payment[(factor, activity)] for factor in factors for activity in activities)
        direct_tax_value[region] = _sam_value(bundle, government_account, household_account) / base_price
        direct_tax_value[region] >= 0.0 ||
            error("Direct taxes must be non-negative in $(region).")
        direct_tax_value[region] < factor_income ||
            error("Direct taxes exhaust factor income in $(region).")
        direct_tax_rate[region] = direct_tax_value[region] / factor_income
        disposable_income = factor_income - direct_tax_value[region]
        private_saving[region] = disposable_income - household_total[region]
        private_saving_share[region] = private_saving[region] / disposable_income
        government_tax_revenue[region] = direct_tax_value[region] +
            sum(production_tax_value[activity] for activity in activities)
        government_tax_revenue[region] > 0.0 ||
            error("Government tax revenue is not positive in $(region).")
        government_total = sum(government_demand[good] for good in activities)
        government_total > 0.0 || error("Government consumption is not positive in $(region).")
        for good in activities
            government_share[(good, region)] = government_demand[good] / government_total
        end
        government_saving[region] = government_tax_revenue[region] - government_total
        government_saving_share[region] = government_saving[region] / government_tax_revenue[region]
    end

    trade_routes = JCGEBlocks.TradeRoute[]
    trade_value = Dict{Symbol,Float64}()
    for row in eachrow(bundle.trade_registry)
        product = Symbol(row.product)
        origin = Symbol(row.origin)
        destination = Symbol(row.destination)
        product in products || error("Unknown trade product $(product).")
        origin == :ROW || origin in regions || error("Unknown trade origin $(origin).")
        destination == :ROW || destination in regions || error("Unknown trade destination $(destination).")
        id = Symbol("TRD_", product, "_", origin, "_", destination)
        route = JCGEBlocks.trade_route(id, product, origin, destination)
        push!(trade_routes, route)
        value = Float64(row.marketed_value_meur) / base_price
        value > 0.0 || error("Trade flow $(id) is not positive.")
        trade_value[id] = value
    end
    length(unique(route.id for route in trade_routes)) == length(trade_routes) || error("Trade registry has duplicate routes.")

    armington_sigma = calibration_option_number(bundle, "trade", "armington_elasticity")
    cet_psi = calibration_option_number(bundle, "trade", "cet_transformation_elasticity")
    armington_sigma > 0.0 || error("trade.armington_elasticity must be positive.")
    cet_psi > 0.0 || error("trade.cet_transformation_elasticity must be positive.")
    armington_exponent = Dict((product, region) => JCGECalibrate.rho_from_sigma(armington_sigma) for product in products for region in regions)
    cet_exponent = Dict((product, region) => JCGECalibrate.rho_from_sigma(cet_psi) for product in products for region in regions)
    supply_groups, demand_groups = _trade_groups(trade_routes)
    trade_goods, armington_scale, armington_share, cet_scale, cet_share,
    delivery_wedge, world_price, output_tax = _calibrate_trade!(
        trade_routes,
        trade_value,
        supply_groups,
        demand_groups,
        products,
        product_by_region,
        activity_output,
        inventory_change,
        intermediate,
        household_demand,
        government_demand,
        fixed_investment_demand,
        armington_exponent,
        cet_exponent,
        calibration_option_number(bundle, "trade", "delivery_wedge"),
        calibration_option_number(bundle, "trade", "row_world_price"),
        output_tax_rate,
    )

    foreign_saving = Dict{Symbol,Float64}()
    investment_spending = Dict{Symbol,Float64}()
    investment_pool_transfer = Dict{Symbol,Float64}()
    for region in regions
        row_import_value = sum(
            world_price[route.id] * trade_value[route.id]
            for route in trade_routes if route.origin == :ROW && route.destination == region)
        row_export_value = sum(
            world_price[route.id] * trade_value[route.id]
            for route in trade_routes if route.origin == region && route.destination == :ROW)
        foreign_saving[region] = row_import_value - row_export_value
        goods = [product_by_region[(region, product)] for product in products]
        investment_spending[region] = sum(
            fixed_investment_demand[good] + get(inventory_change, good, 0.0)
            for good in goods)
        investment_pool_transfer[region] = investment_spending[region] -
            private_saving[region] - government_saving[region] - foreign_saving[region]
    end

    return MultiRegionCalibration(
        bundle,
        products,
        product_by_region,
        activity_output,
        marketed_output,
        factor_payment,
        factor_share,
        factor_endowment,
        real_factor_price,
        production_scale,
        value_added_coefficient,
        intermediate_coefficient,
        production_tax_value,
        household_demand,
        household_share,
        household_demand_share,
        household_total,
        government_demand,
        government_share,
        fixed_investment_demand,
        inventory_change,
        inventory_spending,
        direct_tax_value,
        direct_tax_rate,
        private_saving,
        private_saving_share,
        government_tax_revenue,
        government_saving,
        government_saving_share,
        foreign_saving,
        investment_spending,
        investment_pool_transfer,
        price_weight,
        common_price_weight,
        trade_routes,
        trade_goods,
        trade_value,
        armington_scale,
        armington_share,
        armington_exponent,
        cet_scale,
        cet_share,
        cet_exponent,
        delivery_wedge,
        world_price,
        output_tax,
        calibration_option_number(bundle, "numerical", "positive_lower"),
    )
end

function calibration_consistency(calibration::MultiRegionCalibration = multi_region_calibration())
    bundle = calibration.bundle
    regions = region_codes(bundle)
    products = calibration.products
    input_residuals = Float64[]
    for region in regions, product in products
        activity = calibration.product_by_region[(region, product)]
        inputs = sum(
            calibration.intermediate_coefficient[(commodity, activity)] * calibration.activity_output[activity]
            for commodity in [calibration.product_by_region[(region, p)] for p in products]
        )
        reconstructed = inputs + calibration.value_added_coefficient[activity] * calibration.activity_output[activity] + calibration.production_tax_value[activity]
        push!(input_residuals, reconstructed - calibration.activity_output[activity])
    end
    supply, demand = _trade_groups(calibration.trade_routes)
    supply_residuals = Float64[]
    for ((product, origin), routes) in supply
        activity = calibration.product_by_region[(origin, product)]
        actual = sum(calibration.trade_value[route.id] for route in routes)
        expected = calibration.activity_output[activity] - get(calibration.inventory_change, activity, 0.0)
        push!(supply_residuals, actual - expected)
    end
    demand_residuals = Float64[]
    for ((product, destination), routes) in demand
        commodity = calibration.product_by_region[(destination, product)]
        actual = sum(calibration.trade_value[route.id] for route in routes)
        expected = calibration.household_demand[commodity] + calibration.government_demand[commodity] + calibration.fixed_investment_demand[commodity] +
            sum(calibration.intermediate_coefficient[(commodity, calibration.product_by_region[(destination, activity_product)])] * calibration.activity_output[calibration.product_by_region[(destination, activity_product)]] for activity_product in products)
        push!(demand_residuals, actual - expected)
    end
    return (
        max_abs_industry_cost_residual = maximum(abs, input_residuals),
        max_abs_trade_supply_residual = maximum(abs, supply_residuals),
        max_abs_trade_demand_residual = maximum(abs, demand_residuals),
    )
end
