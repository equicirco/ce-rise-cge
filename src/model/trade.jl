"""
Trade closure for the six-region CE-RISE model.

Primary and manufactured products clear in one EU market per product.  Every
region therefore faces the same EU seller price for a given traded product;
the only remaining product-source choice is between the EU market and ROW.
Repair, refurbishment, reuse, waste treatment, construction, trade,
transport, and other services remain regional.  Their observed net EU service
balance is held fixed solely to reproduce the calibration accounts; it is not
an endogenous trade or relocation mechanism.
"""

const EU_TRADED_PRODUCTS = (
    :AGRI_FOOD,
    :EXTRACTIVE,
    :BASIC_METALS,
    :METAL_COMPONENTS,
    :NEW_ELMA,
    :NEW_OFMA,
    :NEW_RATV,
    :OTHER_MANUFACTURING,
)

const REGIONAL_SERVICE_PRODUCTS = (
    :REP_ELMA,
    :REP_OFMA,
    :REP_RATV,
    :REF_ELMA,
    :REF_OFMA,
    :REF_RATV,
    :REU_ELMA,
    :REU_OFMA,
    :REU_RATV,
    :REC_EE,
    :INC_EE,
    :CONSTRUCTION,
    :UTIL_WASTE,
    :TRADE,
    :TRANSPORT,
    :OTHER_SERVICES,
    :PUBLIC_SOCIAL,
)

struct CommonEUTradeCalibration
    traded_products::Vector{Symbol}
    service_products::Vector{Symbol}
    eu_sale::Dict{Tuple{Symbol,Symbol},Float64}
    eu_purchase::Dict{Tuple{Symbol,Symbol},Float64}
    row_export_route::Dict{Tuple{Symbol,Symbol},Union{Nothing,JCGEBlocks.TradeRoute}}
    row_import_route::Dict{Tuple{Symbol,Symbol},Union{Nothing,JCGEBlocks.TradeRoute}}
    service_net_eu_export::Dict{Tuple{Symbol,Symbol},Float64}
    armington_scale::Dict{Tuple{Symbol,Symbol},Float64}
    armington_share::Dict{Tuple{Symbol,Symbol,Symbol},Float64}
    cet_scale::Dict{Tuple{Symbol,Symbol},Float64}
    cet_share::Dict{Tuple{Symbol,Symbol,Symbol},Float64}
end

struct CommonEUTradeBlock <: JCGECore.AbstractBlock
    name::Symbol
    regions::Vector{Symbol}
    products::Vector{Symbol}
    goods::Dict{Tuple{Symbol,Symbol},Symbol}
    calibration::CommonEUTradeCalibration
    row_routes::Vector{JCGEBlocks.TradeRoute}
    inventory::JCGEBlocks.InventoryTreatment
    params::NamedTuple
end

JCGEBlocks.inventory_treatment(block::CommonEUTradeBlock) = block.inventory

function _trade_route_map(calibration::MultiRegionCalibration)
    return Dict((route.product, route.origin, route.destination) => route
        for route in calibration.trade_routes)
end

function _two_source_scale_share(total::Float64, eu_value::Float64,
    row_value::Float64, exponent::Float64)
    total > 0.0 || error("Common EU trade calibration requires positive total sales or purchases.")
    eu_value > 0.0 || error("Common EU trade calibration requires positive EU value.")
    row_value > 0.0 || error("Common EU trade calibration requires positive ROW value.")
    isapprox(total, eu_value + row_value; atol=1.0e-8, rtol=1.0e-8) ||
        error("Common EU trade calibration does not add to its total.")
    if iszero(exponent)
        eu_share = eu_value / total
        row_share = row_value / total
        scale = total / (eu_value^eu_share * row_value^row_share)
        return scale, eu_share, row_share
    end
    return 1.0, (eu_value / total)^(1.0 - exponent),
        (row_value / total)^(1.0 - exponent)
end

_route_flow_value(calibration::MultiRegionCalibration, route) =
    route === nothing ? 0.0 : calibration.trade_value[route.id]

"""Aggregate bilateral calibration flows into EU-pool and ROW routes."""
function common_eu_trade_calibration(calibration::MultiRegionCalibration)
    products = calibration.products
    Set(products) == Set(vcat(collect(EU_TRADED_PRODUCTS), collect(REGIONAL_SERVICE_PRODUCTS))) ||
        error("The common-EU trade classification must cover each calibrated product exactly once.")
    isempty(intersect(Set(EU_TRADED_PRODUCTS), Set(REGIONAL_SERVICE_PRODUCTS))) ||
        error("A product cannot be both EU traded and a regional service.")

    regions = region_codes(calibration.bundle)
    route_map = _trade_route_map(calibration)
    eu_sale = Dict{Tuple{Symbol,Symbol},Float64}()
    eu_purchase = Dict{Tuple{Symbol,Symbol},Float64}()
    row_export_route = Dict{Tuple{Symbol,Symbol},Union{Nothing,JCGEBlocks.TradeRoute}}()
    row_import_route = Dict{Tuple{Symbol,Symbol},Union{Nothing,JCGEBlocks.TradeRoute}}()
    service_net_eu_export = Dict{Tuple{Symbol,Symbol},Float64}()
    armington_scale = Dict{Tuple{Symbol,Symbol},Float64}()
    armington_share = Dict{Tuple{Symbol,Symbol,Symbol},Float64}()
    cet_scale = Dict{Tuple{Symbol,Symbol},Float64}()
    cet_share = Dict{Tuple{Symbol,Symbol,Symbol},Float64}()

    for product in products, region in regions
        row_export = get(route_map, (product, region, :ROW), nothing)
        row_import = get(route_map, (product, :ROW, region), nothing)
        row_export_route[(product, region)] = row_export
        row_import_route[(product, region)] = row_import

        eu_sales = sum(_route_flow_value(calibration,
            get(route_map, (product, region, destination), nothing)) for destination in regions)
        eu_purchases = sum(_route_flow_value(calibration,
            get(route_map, (product, origin, region), nothing)) for origin in regions)
        if product in EU_TRADED_PRODUCTS
            eu_sale[(product, region)] = eu_sales
            eu_purchase[(product, region)] = eu_purchases
            marketed = calibration.marketed_output[calibration.product_by_region[(region, product)]]
            demand = calibration.household_demand[calibration.product_by_region[(region, product)]] +
                calibration.government_demand[calibration.product_by_region[(region, product)]] +
                calibration.fixed_investment_demand[calibration.product_by_region[(region, product)]] +
                sum(calibration.intermediate_coefficient[
                    (calibration.product_by_region[(region, product)],
                     calibration.product_by_region[(region, activity_product)])] *
                    calibration.activity_output[calibration.product_by_region[(region, activity_product)]]
                    for activity_product in products)
            row_export === nothing && error("Missing ROW export route for EU-traded $(product), $(region).")
            row_import === nothing && error("Missing ROW import route for EU-traded $(product), $(region).")
            export_value = _route_flow_value(calibration, row_export)
            import_value = _route_flow_value(calibration, row_import)
            cet_scale[(product, region)], cet_share[(product, region, :EU)],
            cet_share[(product, region, :ROW)] = _two_source_scale_share(
                marketed, eu_sales, export_value,
                calibration.cet_exponent[(product, region)])
            armington_scale[(product, region)], armington_share[(product, region, :EU)],
            armington_share[(product, region, :ROW)] = _two_source_scale_share(
                demand, eu_purchases, import_value,
                calibration.armington_exponent[(product, region)])
        else
            service_net_eu_export[(product, region)] = eu_sales - eu_purchases
        end
    end

    for product in EU_TRADED_PRODUCTS
        isapprox(sum(eu_sale[(product, region)] for region in regions),
            sum(eu_purchase[(product, region)] for region in regions);
            atol=1.0e-6, rtol=1.0e-10) ||
            error("EU pooled market does not balance in the calibration for $(product).")
    end
    for product in REGIONAL_SERVICE_PRODUCTS
        isapprox(sum(service_net_eu_export[(product, region)] for region in regions), 0.0;
            atol=1.0e-6, rtol=1.0e-10) ||
            error("Fixed EU service balances do not sum to zero for $(product).")
    end
    row_routes = [route for route in calibration.trade_routes
        if route.origin === :ROW || route.destination === :ROW]
    return CommonEUTradeCalibration(
        collect(EU_TRADED_PRODUCTS), collect(REGIONAL_SERVICE_PRODUCTS), eu_sale,
        eu_purchase, row_export_route, row_import_route, service_net_eu_export,
        armington_scale, armington_share, cet_scale, cet_share), row_routes
end

function common_eu_trade(name::Symbol, regions::Vector{Symbol},
    goods::Dict{Tuple{Symbol,Symbol},Symbol}, calibration::MultiRegionCalibration;
    inventory::JCGEBlocks.InventoryTreatment,
    params::NamedTuple)
    structure, row_routes = common_eu_trade_calibration(calibration)
    return CommonEUTradeBlock(name, copy(regions), copy(calibration.products), copy(goods),
        structure, row_routes, inventory, params)
end

_eu_sale_id(product::Symbol, region::Symbol) = JCGEBlocks.global_var(:EU_SALE, product, region)
_eu_purchase_id(product::Symbol, region::Symbol) = JCGEBlocks.global_var(:EU_PURCHASE, product, region)
_eu_price_id(product::Symbol) = JCGEBlocks.global_var(:pEU, product)

function _ensure_trade_variable!(ctx::JCGERuntime.KernelContext, model,
    name::Symbol; lower::Float64)
    haskey(ctx.variables, name) && return ctx.variables[name]
    variable = model isa JuMP.Model ? JuMP.@variable(model, lower_bound=lower,
        base_name=string(name)) : (name=name,)
    JCGERuntime.register_variable!(ctx, name, variable)
    return variable
end

function _register_trade_equation!(ctx::JCGERuntime.KernelContext,
    block::CommonEUTradeBlock, tag::Symbol, ids::Symbol...; info::String, expr,
    index_names::Tuple)
    JCGERuntime.register_equation!(ctx; tag=tag, block=block.name, payload=(
        indices=ids, index_names=index_names, params=block.params, info=info,
        expr=expr, constraint=nothing))
    return nothing
end

function _common_trade_quantity_expr(scale::Float64, eu_share::Float64,
    row_share::Float64, exponent::Float64, eu_quantity, row_quantity)
    if iszero(exponent)
        return EMul([
            EConst(scale),
            EPow(eu_quantity, EConst(eu_share)),
            EPow(row_quantity, EConst(row_share)),
        ])
    end
    return EMul([
        EConst(scale),
        EPow(EAdd([
            EMul([EConst(eu_share), EPow(eu_quantity, EConst(exponent))]),
            EMul([EConst(row_share), EPow(row_quantity, EConst(exponent))]),
        ]), EConst(1.0 / exponent)),
    ])
end

function _common_trade_allocation_expr(scale::Float64, share::Float64,
    exponent::Float64, aggregate, aggregate_price, source_price, multiplier::Float64)
    if iszero(exponent)
        return EMul([EConst(share * multiplier),
            EDiv(aggregate_price, source_price), aggregate])
    end
    return EMul([
        EPow(EDiv(EMul([
            EConst(scale^exponent * share * multiplier), aggregate_price]), source_price),
            EConst(1.0 / (1.0 - exponent))),
        aggregate,
    ])
end

function JCGECore.build!(block::CommonEUTradeBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    JCGEBlocks._validate_inventory_treatment!(block, spec)
    model = ctx.model
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Common EU trade requires a strictly positive lower bound.")
    calibration = block.calibration

    for product in calibration.traded_products
        _ensure_trade_variable!(ctx, model, _eu_price_id(product); lower=lower)
        for region in block.regions
            good = block.goods[(product, region)]
            export_route = calibration.row_export_route[(product, region)]
            import_route = calibration.row_import_route[(product, region)]
            _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:Z, good); lower=lower)
            _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:pz, good); lower=lower)
            _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:Q, good); lower=lower)
            _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:pq, good); lower=lower)
            _ensure_trade_variable!(ctx, model, _eu_sale_id(product, region); lower=lower)
            _ensure_trade_variable!(ctx, model, _eu_purchase_id(product, region); lower=lower)
            for route in (export_route, import_route)
                _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:T, route.id); lower=lower)
                _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:pS, route.id); lower=lower)
                _register_trade_equation!(ctx, block, :row_trade_price, route.id;
                    info="ROW trade price is fixed at the calibrated world price",
                    expr=EEq(EVar(:pS, Any[route.id]), EParam(:world_price, Any[route.id])),
                    index_names=(:route,))
            end
            inventory = JCGEBlocks._inventory_is_stock_change(block.inventory) ?
                JCGEBlocks._inventory_parameter_expr(block.inventory, block.params, good) : EConst(0.0)
            marketed = EAdd([EVar(:Z, Any[good]), ENeg(inventory)])
            cet_scale = calibration.cet_scale[(product, region)]
            cet_exponent = block.params.cet_exponent[(product, region)]
            cet_quantity = _common_trade_quantity_expr(cet_scale,
                calibration.cet_share[(product, region, :EU)],
                calibration.cet_share[(product, region, :ROW)], cet_exponent,
                EVar(:EU_SALE, Any[product, region]), EVar(:T, Any[export_route.id]))
            _register_trade_equation!(ctx, block, :eu_cet_quantity, product, region;
                info="marketed output is allocated between the common EU market and ROW through a calibrated CET transformation",
                expr=EEq(marketed, cet_quantity), index_names=(:product, :region))
            output_tax = block.params.output_tax[(product, region)]
            output_tax > -1.0 || error("Output-tax multiplier must be positive.")
            for (destination, quantity, price, key) in (
                (:EU, EVar(:EU_SALE, Any[product, region]), EVar(:pEU, Any[product]), :EU),
                (:ROW, EVar(:T, Any[export_route.id]), EVar(:pS, Any[export_route.id]), :ROW),
            )
                allocation = _common_trade_allocation_expr(cet_scale,
                    calibration.cet_share[(product, region, key)], cet_exponent, marketed,
                    EVar(:pz, Any[good]), price, 1.0 + output_tax)
                _register_trade_equation!(ctx, block, :eu_cet_allocation, product, region, destination;
                    info="sales allocation follows the calibrated CET first-order condition",
                    expr=EEq(quantity, allocation), index_names=(:product, :region, :destination))
            end
            armington_scale = calibration.armington_scale[(product, region)]
            armington_exponent = block.params.armington_exponent[(product, region)]
            armington_quantity = _common_trade_quantity_expr(armington_scale,
                calibration.armington_share[(product, region, :EU)],
                calibration.armington_share[(product, region, :ROW)], armington_exponent,
                EVar(:EU_PURCHASE, Any[product, region]), EVar(:T, Any[import_route.id]))
            _register_trade_equation!(ctx, block, :eu_armington_quantity, product, region;
                info="regional composite demand combines common-EU and ROW supply through a calibrated Armington nest",
                expr=EEq(EVar(:Q, Any[good]), armington_quantity),
                index_names=(:product, :region))
            for (origin, quantity, price, key) in (
                (:EU, EVar(:EU_PURCHASE, Any[product, region]), EVar(:pEU, Any[product]), :EU),
                (:ROW, EVar(:T, Any[import_route.id]), EVar(:pS, Any[import_route.id]), :ROW),
            )
                allocation = _common_trade_allocation_expr(armington_scale,
                    calibration.armington_share[(product, region, key)], armington_exponent,
                    EVar(:Q, Any[good]), EVar(:pq, Any[good]), price, 1.0)
                _register_trade_equation!(ctx, block, :eu_armington_allocation, product, region, origin;
                    info="sourcing allocation follows the calibrated Armington first-order condition",
                    expr=EEq(quantity, allocation), index_names=(:product, :region, :origin))
            end
        end
        _register_trade_equation!(ctx, block, :eu_market_clearing, product;
            info="common-EU supply equals common-EU demand at one no-arbitrage product price",
            expr=EEq(EAdd([EVar(:EU_SALE, Any[product, region]) for region in block.regions]),
                EAdd([EVar(:EU_PURCHASE, Any[product, region]) for region in block.regions])),
            index_names=(:product,))
    end

    for product in calibration.service_products, region in block.regions
        good = block.goods[(product, region)]
        export_route = calibration.row_export_route[(product, region)]
        import_route = calibration.row_import_route[(product, region)]
        _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:Z, good); lower=lower)
        _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:pz, good); lower=lower)
        _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:Q, good); lower=lower)
        _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:pq, good); lower=lower)
        for route in (export_route, import_route)
            route === nothing && continue
            _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:T, route.id); lower=lower)
            _ensure_trade_variable!(ctx, model, JCGEBlocks.global_var(:pS, route.id); lower=lower)
            _register_trade_equation!(ctx, block, :fixed_row_service_flow, route.id;
                info="regional service ROW flow remains fixed at its calibrated level",
                expr=EEq(EVar(:T, Any[route.id]), EParam(:trade_value, Any[route.id])),
                index_names=(:route,))
            _register_trade_equation!(ctx, block, :row_trade_price, route.id;
                info="ROW trade price is fixed at the calibrated world price",
                expr=EEq(EVar(:pS, Any[route.id]), EParam(:world_price, Any[route.id])),
                index_names=(:route,))
        end
        output_tax = block.params.output_tax[(product, region)]
        price = EEq(EVar(:pq, Any[good]), EMul([
            EConst(1.0 + output_tax), EVar(:pz, Any[good])]))
        _register_trade_equation!(ctx, block, :regional_service_price, product, region;
            info="regional service price equals its local producer price plus the calibrated output tax",
            expr=price, index_names=(:product, :region))
        inventory = JCGEBlocks._inventory_is_stock_change(block.inventory) ?
            JCGEBlocks._inventory_parameter_expr(block.inventory, block.params, good) : EConst(0.0)
        balance_terms = JCGECore.EquationExpr[
            EVar(:Z, Any[good]),
            ENeg(inventory),
            ENeg(EConst(calibration.service_net_eu_export[(product, region)])),
        ]
        export_route === nothing || push!(balance_terms, ENeg(EVar(:T, Any[export_route.id])))
        import_route === nothing || push!(balance_terms, EVar(:T, Any[import_route.id]))
        balance = EEq(EAdd(balance_terms), EVar(:Q, Any[good]))
        _register_trade_equation!(ctx, block, :regional_service_market, product, region;
            info="regional service output clears its local market after fixed calibrated EU net service transfers and ROW trade",
            expr=balance, index_names=(:product, :region))
    end
    return nothing
end

function common_eu_trade_initial_values(calibration::MultiRegionCalibration)
    structure, _ = common_eu_trade_calibration(calibration)
    starts = Dict{Symbol,Float64}()
    for product in structure.traded_products
        starts[_eu_price_id(product)] = 1.0
        for region in region_codes(calibration.bundle)
            starts[_eu_sale_id(product, region)] = structure.eu_sale[(product, region)]
            starts[_eu_purchase_id(product, region)] = structure.eu_purchase[(product, region)]
        end
    end
    return starts
end
