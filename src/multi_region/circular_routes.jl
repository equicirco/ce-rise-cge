"""
Circular service and end-of-life equations for the CE-RISE model.

The monetary SAM remains industry by industry.  Household purchases of NEW,
REF, REP, and REU products are therefore replaced only at final demand by a
family-specific CES service composite.  End-of-life availability is a
calibration-normalized, non-priced resource: each family has one EU-wide unit
which is allocated across the regional REF, REP, REU, REC, and INC lines.
This is deliberately separate from the physical satellite, which retains the
available tonne-based evidence.
"""

const _CIRCULAR_SERVICE_PRICE_VAR = :P_CIRCULAR_SERVICE
const _CIRCULAR_SERVICE_QUANTITY_VAR = :Q_CIRCULAR_SERVICE
const _CIRCULAR_EOL_FLOW_VAR = :EOL_FLOW
const _CIRCULAR_EOL_INDEX_VAR = :EOL_INDEX

_circular_eol_line_id(region::Symbol, family::Symbol, route::Symbol) =
    Symbol(:EOL_, region, :_, family, :_, route)

function _circular_route_configuration(bundle::CalibrationBundle, key::String)
    value = calibration_option_number(bundle, "circular_routes", key)
    value > 0.0 || error("circular_routes.$(key) must be strictly positive.")
    return value
end

function _circular_reference_price(calibration::MultiRegionCalibration,
    activity::Symbol)
    base_price = calibration_option_number(calibration.bundle, "normalization", "base_price")
    return base_price * (
        calibration.value_added_coefficient[activity] +
        sum(value for ((_, target), value) in calibration.intermediate_coefficient
            if target === activity)
    )
end

"""
    circular_route_calibration(outline, calibration)

Derive the circular-route calibration exclusively from the bundled SAM and
route registry.  Service expenditure shares are the observed household shares
of the four service routes.  The EU-wide end-of-life allocation is normalized
within each product family; regional source weights follow household service
expenditure, while the within-region route weights follow calibrated route
activity output.  Shared REC and INC activities are allocated to families by
their regional service-expenditure shares.
"""
function circular_route_calibration(outline::MultiRegionOutline,
    calibration::MultiRegionCalibration)
    registry = outline.bundle.route_registry
    service_routes = (:NEW, :REF, :REP, :REU)
    eol_routes = (:REF, :REP, :REU, :REC, :INC)
    services = Symbol[]
    service_region = Dict{Symbol,Symbol}()
    service_family = Dict{Symbol,Symbol}()
    route_goods_by_service = Dict{Symbol,Dict{Symbol,Symbol}}()

    for group in groupby(registry, [:region, :family])
        region = Symbol(group.region[1])
        family = Symbol(group.family[1])
        service_accounts = unique([
            String(value) for value in group.service_account
            if !ismissing(value) && !isempty(String(value))
        ])
        service = Symbol(only(service_accounts))
        routes = Dict{Symbol,Symbol}()
        for route in service_routes
            rows = filter(row -> Symbol(row.route) === route, group)
            nrow(rows) == 1 || error("Circular service $(region), $(family) requires one $(route) route.")
            routes[route] = Symbol(only(rows.route_activity))
        end
        push!(services, service)
        service_region[service] = region
        service_family[service] = family
        route_goods_by_service[service] = routes
    end
    sort!(services)
    length(unique(services)) == length(services) ||
        error("Circular service identifiers must be unique.")

    nonservice_goods_by_region = Dict{Symbol,Vector{Symbol}}()
    service_share = Dict{Symbol,Float64}()
    route_share = Dict{Tuple{Symbol,Symbol},Float64}()
    service_expenditure = Dict{Symbol,Float64}()
    regional_service_expenditure = Dict{Symbol,Float64}(region => 0.0 for region in outline.regions)
    family_service_expenditure = Dict{Symbol,Float64}(family => 0.0 for family in outline.families)

    for service in services
        region = service_region[service]
        family = service_family[service]
        goods = collect(values(route_goods_by_service[service]))
        expenditure = sum(calibration.household_demand[good] for good in goods)
        expenditure > 0.0 || error("Circular service $(service) has non-positive household expenditure.")
        income = calibration.household_total[region]
        service_share[service] = expenditure / income
        service_expenditure[service] = expenditure
        regional_service_expenditure[region] += expenditure
        family_service_expenditure[family] += expenditure
        for good in goods
            route_share[(service, good)] = calibration.household_demand[good] / expenditure
        end
    end

    for region in outline.regions
        circular_goods = Set{Symbol}()
        for service in services
            service_region[service] === region || continue
            union!(circular_goods, values(route_goods_by_service[service]))
        end
        nonservice_goods_by_region[region] = [
            good for good in outline.industries_by_region[region]
            if !(good in circular_goods) && calibration.household_demand[good] > 0.0
        ]
        share_total = sum(calibration.household_share[good]
            for good in nonservice_goods_by_region[region]) +
            sum(service_share[service] for service in services if service_region[service] === region)
        isapprox(share_total, 1.0; atol=1.0e-10, rtol=1.0e-10) ||
            error("Household shares for $(region) do not exhaust disposable income.")
    end

    eol_lines_by_family = Dict{Symbol,Vector{Symbol}}()
    eol_line_activity = Dict{Symbol,Symbol}()
    eol_share = Dict{Tuple{Symbol,Symbol},Float64}()
    raw_eol_share = Dict{Tuple{Symbol,Symbol},Float64}()
    for family in outline.families
        family_service_expenditure[family] > 0.0 ||
            error("Circular family $(family) has no household service expenditure.")
        lines = Symbol[]
        for region in outline.regions
            service = only(filter(candidate ->
                service_region[candidate] === region && service_family[candidate] === family,
                services))
            source_weight = service_expenditure[service] / family_service_expenditure[family]
            regional_service_expenditure[region] > 0.0 ||
                error("Region $(region) has no circular-service expenditure.")
            route_base = Dict{Symbol,Float64}()
            activity_by_route = Dict{Symbol,Symbol}()
            for route in eol_routes
                rows = filter(row -> Symbol(row.region) === region &&
                    Symbol(row.family) === family && Symbol(row.route) === route,
                    registry)
                nrow(rows) == 1 || error("End-of-life line $(region), $(family), $(route) is not uniquely registered.")
                activity = Symbol(only(rows.route_activity))
                activity_by_route[route] = activity
                shared_processing = route in (:REC, :INC)
                activity_weight = shared_processing ?
                    service_expenditure[service] / regional_service_expenditure[region] : 1.0
                route_base[route] = calibration.activity_output[activity] * activity_weight
                route_base[route] > 0.0 ||
                    error("End-of-life route $(region), $(family), $(route) has non-positive calibration output.")
            end
            route_total = sum(values(route_base))
            for route in eol_routes
                line = _circular_eol_line_id(region, family, route)
                push!(lines, line)
                eol_line_activity[line] = activity_by_route[route]
                raw_eol_share[(family, line)] = source_weight * route_base[route] / route_total
            end
        end
        total = sum(raw_eol_share[(family, line)] for line in lines)
        isapprox(total, 1.0; atol=1.0e-12, rtol=1.0e-12) ||
            error("End-of-life shares for $(family) do not sum to one.")
        eol_lines_by_family[family] = sort!(lines)
        for line in lines
            eol_share[(family, line)] = raw_eol_share[(family, line)]
        end
    end

    eol_reference_price = Dict{Symbol,Float64}()
    eol_reference_total = Dict{Symbol,Float64}()
    for (line, activity) in eol_line_activity
        eol_reference_price[activity] = _circular_reference_price(calibration, activity)
        eol_reference_price[activity] > 0.0 ||
            error("Circular end-of-life activity $(activity) has a non-positive reference price.")
        family = only(filter(candidate -> line in eol_lines_by_family[candidate], outline.families))
        eol_reference_total[activity] = get(eol_reference_total, activity, 0.0) +
            eol_share[(family, line)]
    end
    all(value > 0.0 for value in values(eol_reference_total)) ||
        error("Every circular end-of-life activity must have a positive reference allocation.")

    return CircularRouteCalibration(
        services,
        service_region,
        service_family,
        route_goods_by_service,
        nonservice_goods_by_region,
        service_share,
        route_share,
        eol_lines_by_family,
        eol_line_activity,
        eol_share,
        eol_reference_price,
        eol_reference_total,
        _circular_route_configuration(outline.bundle, "eol_allocation_elasticity"),
        _circular_route_configuration(outline.bundle, "eol_productivity_elasticity"),
        _circular_route_configuration(outline.bundle, "service_elasticity"),
    )
end

"""Return calibrated starts for the circular service and EOL variables."""
function circular_route_initial_values(outline::MultiRegionOutline,
    calibration::MultiRegionCalibration, routes::CircularRouteCalibration)
    base_price = calibration_option_number(calibration.bundle, "normalization", "base_price")
    starts = Dict{Symbol,Float64}()
    for service in routes.services
        goods = collect(values(routes.route_goods_by_service[service]))
        starts[JCGEBlocks.global_var(_CIRCULAR_SERVICE_PRICE_VAR, service)] = base_price
        starts[JCGEBlocks.global_var(_CIRCULAR_SERVICE_QUANTITY_VAR, service)] =
            sum(calibration.household_demand[good] for good in goods) / base_price
    end
    for (family, lines) in routes.eol_lines_by_family
        for line in lines
            starts[JCGEBlocks.global_var(_CIRCULAR_EOL_FLOW_VAR, line)] = 1.0
        end
    end
    for activity in keys(routes.eol_reference_total)
        starts[JCGEBlocks.global_var(_CIRCULAR_EOL_INDEX_VAR, activity)] = 1.0
    end
    for region in outline.regions
        nonservice_utility = prod(
            calibration.household_demand[good]^calibration.household_share[good]
            for good in routes.nonservice_goods_by_region[region]
        )
        service_utility = prod(
            starts[JCGEBlocks.global_var(_CIRCULAR_SERVICE_QUANTITY_VAR, service)]^
                routes.service_share[service]
            for service in routes.services if routes.service_region[service] === region
        )
        starts[JCGEBlocks.global_var(:UU, region)] = nonservice_utility * service_utility
    end
    return starts
end

struct EUWideEOLAllocationBlock <: JCGECore.AbstractBlock
    name::Symbol
    calibration::CircularRouteCalibration
    params::NamedTuple
end

struct EOLProductivityProductionBlock <: JCGECore.AbstractBlock
    name::Symbol
    activities::Vector{Symbol}
    factors::Vector{Symbol}
    commodities::Vector{Symbol}
    params::NamedTuple
end

struct CircularServiceDemandBlock <: JCGECore.AbstractBlock
    name::Symbol
    calibration::CircularRouteCalibration
    factors_by_region::Dict{Symbol,Vector{Symbol}}
    activities_by_region::Dict{Symbol,Vector{Symbol}}
    params::NamedTuple
end

struct CircularHouseholdPriceIndexBlock <: JCGECore.AbstractBlock
    name::Symbol
    calibration::CircularRouteCalibration
    regions::Vector{Symbol}
    params::NamedTuple
end

struct CircularHouseholdUtilityBlock <: JCGECore.AbstractBlock
    name::Symbol
    calibration::CircularRouteCalibration
    regions::Vector{Symbol}
    params::NamedTuple
end

function _ensure_circular_route_variable!(ctx::JCGERuntime.KernelContext, model,
    name::Symbol; lower::Union{Nothing,Float64}=nothing)
    haskey(ctx.variables, name) && return ctx.variables[name]
    variable = model isa JuMP.Model ?
        (lower === nothing ? JuMP.@variable(model, base_name=string(name)) :
         JuMP.@variable(model, lower_bound=lower, base_name=string(name))) :
        (name=name,)
    JCGERuntime.register_variable!(ctx, name, variable)
    return variable
end

function _register_circular_route_equation!(ctx::JCGERuntime.KernelContext,
    block::JCGECore.AbstractBlock, tag::Symbol, ids::Symbol...;
    info::String, expr, index_names::Union{Nothing,Tuple}=nothing)
    payload = (
        indices = ids,
        index_names = index_names,
        params = block.params,
        info = info,
        expr = expr,
        constraint = nothing,
    )
    JCGERuntime.register_equation!(ctx; tag=tag, block=block.name, payload=payload)
    return nothing
end

function JCGECore.build!(block::EUWideEOLAllocationBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    lower = Float64(block.params.positive_lower)
    elasticity = Float64(block.params.elasticity)
    lower > 0.0 || error("EU-wide EOL allocation requires a positive lower bound.")
    elasticity > 0.0 || error("EU-wide EOL allocation elasticity must be positive.")
    model = ctx.model
    routes = block.calibration
    for family in sort!(collect(keys(routes.eol_lines_by_family)))
        lines = routes.eol_lines_by_family[family]
        relative_price = Dict{Symbol,JCGECore.EquationExpr}()
        weighted_price = Dict{Symbol,JCGECore.EquationExpr}()
        for line in lines
            activity = routes.eol_line_activity[line]
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(:pz, activity); lower=lower)
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(_CIRCULAR_EOL_FLOW_VAR, line); lower=0.0)
            relative_price[line] = EPow(
                EDiv(
                    EVar(:pz, Any[activity]),
                    EParam(:reference_price, Any[activity]),
                ),
                ENeg(EParam(:elasticity, Any[])),
            )
            weighted_price[line] = EMul([
                EParam(:share, Any[family, line]),
                relative_price[line],
            ])
        end
        denominator = EAdd(JCGECore.EquationExpr[weighted_price[line] for line in lines])
        for line in lines
            expr = EEq(
                EVar(_CIRCULAR_EOL_FLOW_VAR, Any[line]),
                EDiv(relative_price[line], denominator),
            )
            _register_circular_route_equation!(ctx, block, :eu_wide_eol_allocation,
                family, line;
                info="the normalized end-of-life allocation index follows relative activity prices in the EU-wide family market",
                expr=expr, index_names=(:family, :line))
        end
    end
    for activity in sort!(collect(keys(routes.eol_reference_total)))
        lines = sort!([line for (line, mapped_activity) in routes.eol_line_activity
            if mapped_activity === activity])
        _ensure_circular_route_variable!(ctx, model,
            JCGEBlocks.global_var(_CIRCULAR_EOL_INDEX_VAR, activity); lower=lower)
        allocation_terms = JCGECore.EquationExpr[]
        for line in lines
            family = only([candidate for candidate in keys(routes.eol_lines_by_family)
                if line in routes.eol_lines_by_family[candidate]])
            push!(allocation_terms, EMul([
                EParam(:share, Any[family, line]),
                EVar(_CIRCULAR_EOL_FLOW_VAR, Any[line]),
            ]))
        end
        expr = EEq(
            EVar(_CIRCULAR_EOL_INDEX_VAR, Any[activity]),
            EDiv(
                EAdd(allocation_terms),
                EParam(:reference_total, Any[activity]),
            ),
        )
        _register_circular_route_equation!(ctx, block, :eol_activity_availability,
            activity;
            info="route-specific end-of-life availability is normalized to its calibration allocation",
            expr=expr, index_names=(:activity,))
    end
    return nothing
end

function JCGECore.build!(block::EOLProductivityProductionBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Circular route production requires a positive lower bound.")
    for activity in block.activities
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:Y, activity); lower=lower)
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:Z, activity); lower=lower)
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:py, activity); lower=lower)
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:pz, activity); lower=lower)
        _ensure_circular_route_variable!(ctx, model,
            JCGEBlocks.global_var(_CIRCULAR_EOL_INDEX_VAR, activity); lower=lower)
        for factor in block.factors
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:pf, factor); lower=lower)
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(:F, factor, activity); lower=lower)
        end
        for commodity in block.commodities
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:pq, commodity); lower=lower)
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(:X, commodity, activity); lower=0.0)
        end
        technology = EEq(
            EVar(:Y, Any[activity]),
            EMul([
                EParam(:b, Any[activity]),
                EPow(
                    EVar(_CIRCULAR_EOL_INDEX_VAR, Any[activity]),
                    EParam(:eol_productivity_elasticity, Any[]),
                ),
                EProd(:factor, block.factors,
                    EPow(
                        EVar(:F, Any[EIndex(:factor), activity]),
                        EParam(:beta, Any[EIndex(:factor), activity]),
                    ),
                ),
            ]),
        )
        _register_circular_route_equation!(ctx, block, :eqpy, activity;
            info="circular-route value added follows calibrated Cobb-Douglas technology shifted by normalized end-of-life availability",
            expr=technology, index_names=(:activity,))
        for factor in block.factors
            factor_demand = EEq(
                EVar(:F, Any[factor, activity]),
                EDiv(
                    EMul([
                        EParam(:beta, Any[factor, activity]),
                        EVar(:py, Any[activity]),
                        EVar(:Y, Any[activity]),
                    ]),
                    EVar(:pf, Any[factor]),
                ),
            )
            _register_circular_route_equation!(ctx, block, :eqF, factor, activity;
                info="circular-route factor demand follows the calibrated value-added cost share",
                expr=factor_demand, index_names=(:factor, :activity))
        end
        for commodity in block.commodities
            intermediate = EEq(
                EVar(:X, Any[commodity, activity]),
                EMul([
                    EParam(:ax, Any[commodity, activity]),
                    EVar(:Z, Any[activity]),
                ]),
            )
            _register_circular_route_equation!(ctx, block, :eqX, commodity, activity;
                info="circular-route intermediate use follows its calibrated fixed coefficient",
                expr=intermediate, index_names=(:commodity, :activity))
        end
        output_link = EEq(
            EVar(:Y, Any[activity]),
            EMul([
                EParam(:ay, Any[activity]),
                EVar(:Z, Any[activity]),
            ]),
        )
        _register_circular_route_equation!(ctx, block, :eqY, activity;
            info="circular-route value added is a calibrated share of gross output",
            expr=output_link, index_names=(:activity,))
        price = EEq(
            EVar(:pz, Any[activity]),
            EAdd([
                EMul([
                    EParam(:ay, Any[activity]),
                    EVar(:py, Any[activity]),
                ]),
                ESum(:commodity, block.commodities, EMul([
                    EParam(:ax, Any[EIndex(:commodity), activity]),
                    EVar(:pq, Any[EIndex(:commodity)]),
                ])),
            ]),
        )
        _register_circular_route_equation!(ctx, block, :eqpzs, activity;
            info="circular-route output price equals value-added and intermediate-input costs",
            expr=price, index_names=(:activity,))
    end
    return nothing
end

function _circular_disposable_income_expr(region::Symbol,
    factors::Vector{Symbol}, activities::Vector{Symbol};
    include_policy_transfer::Bool=false)
    terms = JCGECore.EquationExpr[
        ESum(:factor, factors, ESum(:activity, activities, EMul([
            EVar(:pf, Any[EIndex(:factor)]),
            EVar(:F, Any[EIndex(:factor), EIndex(:activity)]),
        ]))),
        ENeg(EVar(:Sp, Any[region])),
        ENeg(EVar(:Td, Any[region])),
    ]
    include_policy_transfer && push!(terms,
        EVar(_CIRCULAR_POLICY_TRANSFER_VAR, Any[region]))
    return EAdd(terms)
end

function JCGECore.build!(block::CircularServiceDemandBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    routes = block.calibration
    lower = Float64(block.params.positive_lower)
    elasticity = Float64(block.params.elasticity)
    lower > 0.0 || error("Circular service demand requires a positive lower bound.")
    elasticity > 0.0 || error("Circular service elasticity must be positive.")
    is_cobb_douglas = isapprox(elasticity, 1.0; atol=1.0e-12, rtol=0.0)
    for service in routes.services
        region = routes.service_region[service]
        factors = block.factors_by_region[region]
        activities = block.activities_by_region[region]
        goods = sort!(collect(values(routes.route_goods_by_service[service])))
        _ensure_circular_route_variable!(ctx, model,
            JCGEBlocks.global_var(_CIRCULAR_SERVICE_PRICE_VAR, service); lower=lower)
        _ensure_circular_route_variable!(ctx, model,
            JCGEBlocks.global_var(_CIRCULAR_SERVICE_QUANTITY_VAR, service); lower=lower)
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:Sp, region); lower=nothing)
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:Td, region); lower=nothing)
        block.params.include_policy_transfer &&
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(_CIRCULAR_POLICY_TRANSFER_VAR, region); lower=nothing)
        for factor in factors, activity in activities
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:pf, factor); lower=lower)
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:F, factor, activity); lower=0.0)
        end
        for good in goods
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:pq, good); lower=lower)
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:Xp, good); lower=0.0)
        end
        price_rhs = if is_cobb_douglas
            EMul([
                EPow(
                    _effective_route_price_expr(block, route, good),
                    EParam(:route_share, Any[service, good]),
                )
                for (route, good) in routes.route_goods_by_service[service]
            ])
        else
            EPow(
                EAdd(JCGECore.EquationExpr[
                    EMul([
                    EParam(:route_share, Any[service, good]),
                    EPow(
                        _effective_route_price_expr(block, route, good),
                        EAdd([EConst(1.0), ENeg(EParam(:elasticity, Any[]))]),
                    ),
                ]) for (route, good) in routes.route_goods_by_service[service]
                ]),
                EDiv(EConst(1.0),
                    EAdd([EConst(1.0), ENeg(EParam(:elasticity, Any[]))])),
            )
        end
        service_price = EEq(
            EVar(_CIRCULAR_SERVICE_PRICE_VAR, Any[service]),
            price_rhs,
        )
        _register_circular_route_equation!(ctx, block, :circular_service_price, service;
            info="the family-specific circular-service price is the CES price index of NEW, REF, REP, and REU routes",
            expr=service_price, index_names=(:service,))
        service_demand = EEq(
            EVar(_CIRCULAR_SERVICE_QUANTITY_VAR, Any[service]),
            EDiv(
                EMul([
                    EParam(:service_share, Any[service]),
                    _circular_disposable_income_expr(region, factors, activities;
                        include_policy_transfer=block.params.include_policy_transfer),
                ]),
                EVar(_CIRCULAR_SERVICE_PRICE_VAR, Any[service]),
            ),
        )
        _register_circular_route_equation!(ctx, block, :circular_service_demand, service;
            info="households allocate their calibrated expenditure share to the family-specific circular-service composite",
            expr=service_demand, index_names=(:service,))
        for (route, good) in routes.route_goods_by_service[service]
            demand_rhs = is_cobb_douglas ?
                EMul([
                    EParam(:route_share, Any[service, good]),
                    EDiv(
                        EVar(_CIRCULAR_SERVICE_PRICE_VAR, Any[service]),
                        _effective_route_price_expr(block, route, good),
                    ),
                    EVar(_CIRCULAR_SERVICE_QUANTITY_VAR, Any[service]),
                ]) :
                EMul([
                    EParam(:route_share, Any[service, good]),
                    EPow(
                        EDiv(
                            _effective_route_price_expr(block, route, good),
                            EVar(_CIRCULAR_SERVICE_PRICE_VAR, Any[service]),
                        ),
                        ENeg(EParam(:elasticity, Any[])),
                    ),
                    EVar(_CIRCULAR_SERVICE_QUANTITY_VAR, Any[service]),
                ])
            route_demand = EEq(EVar(:Xp, Any[good]), demand_rhs)
            _register_circular_route_equation!(ctx, block, :circular_route_demand, service, good;
                info="CES circular-service demand allocates household expenditure across the four route goods",
                expr=route_demand, index_names=(:service, :good))
        end
    end
    return nothing
end

function JCGECore.build!(block::CircularHouseholdPriceIndexBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    routes = block.calibration
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Circular household price index requires a positive lower bound.")
    services_by_region = Dict(region => Symbol[] for region in block.regions)
    for service in routes.services
        push!(services_by_region[routes.service_region[service]], service)
    end
    for region in block.regions
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:P_HH, region); lower=lower)
        terms = JCGECore.EquationExpr[]
        for good in routes.nonservice_goods_by_region[region]
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:pq, good); lower=lower)
            push!(terms, EMul([
                EParam(:nonservice_share, Any[good]),
                EVar(:pq, Any[good]),
            ]))
        end
        for service in services_by_region[region]
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(_CIRCULAR_SERVICE_PRICE_VAR, service); lower=lower)
            push!(terms, EMul([
                EParam(:service_share, Any[service]),
                EVar(_CIRCULAR_SERVICE_PRICE_VAR, Any[service]),
            ]))
        end
        price_index = EEq(EVar(:P_HH, Any[region]), EAdd(terms))
        _register_circular_route_equation!(ctx, block, :regional_household_price_index, region;
            info="regional household price index combines non-circular goods with circular-service composite prices",
            expr=price_index, index_names=(:region,))
    end
    _ensure_circular_route_variable!(ctx, model, :P_HH_COMMON; lower=lower)
    common = EEq(
        EVar(:P_HH_COMMON, Any[]),
        ESum(:region, block.regions, EMul([
            EParam(:common_weight, Any[EIndex(:region)]),
            EVar(:P_HH, Any[EIndex(:region)]),
        ])),
    )
    _register_circular_route_equation!(ctx, block, :common_household_price_index;
        info="the common household-consumption price index is the calibrated regional weighted average",
        expr=common)
    return nothing
end

function JCGECore.build!(block::CircularHouseholdUtilityBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    routes = block.calibration
    services_by_region = Dict(region => Symbol[] for region in block.regions)
    for service in routes.services
        push!(services_by_region[routes.service_region[service]], service)
    end
    for region in block.regions
        terms = JCGECore.EquationExpr[]
        _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:UU, region); lower=0.0)
        for good in routes.nonservice_goods_by_region[region]
            _ensure_circular_route_variable!(ctx, model, JCGEBlocks.global_var(:Xp, good); lower=0.0)
            push!(terms, EPow(
                EVar(:Xp, Any[good]),
                EParam(:nonservice_share, Any[good]),
            ))
        end
        for service in services_by_region[region]
            _ensure_circular_route_variable!(ctx, model,
                JCGEBlocks.global_var(_CIRCULAR_SERVICE_QUANTITY_VAR, service); lower=0.0)
            push!(terms, EPow(
                EVar(_CIRCULAR_SERVICE_QUANTITY_VAR, Any[service]),
                EParam(:service_share, Any[service]),
            ))
        end
        utility = EEq(EVar(:UU, Any[region]), EMul(terms))
        _register_circular_route_equation!(ctx, block, :regional_circular_utility, region;
            info="regional household utility combines non-circular consumption with family-specific circular services",
            expr=utility, index_names=(:region,))
    end
    objective = ESum(:region, block.regions, EVar(:UU, Any[EIndex(:region)]))
    JCGERuntime.register_equation!(ctx; tag=:objective, block=block.name, payload=(
        indices=(), index_names=nothing, params=block.params,
        info="maximize aggregate regional household utility", expr=nothing,
        constraint=nothing, objective_expr=objective, objective_sense=:Max,
    ))
    return nothing
end

"""Create model-local blocks for circular service demand and EOL allocation."""
function circular_route_blocks(outline::MultiRegionOutline,
    calibration::MultiRegionCalibration, routes::CircularRouteCalibration;
    scenario::PolicyScenario=baseline_scenario(),
    include_policy_transfer::Bool=false,
    excluded_eol_activities::Set{Symbol}=Set{Symbol}())
    lower = calibration.positive_lower
    eol_activities_by_region = Dict(region => Symbol[] for region in outline.regions)
    lookup = account_region_lookup(outline.bundle)
    for activity in keys(routes.eol_reference_total)
        activity in excluded_eol_activities && continue
        region = lookup[activity]
        push!(eol_activities_by_region[region], activity)
    end
    for activities in values(eol_activities_by_region)
        sort!(activities)
    end
    eol_allocation = EUWideEOLAllocationBlock(
        :eu_wide_eol_allocation,
        routes,
        (
            share = routes.eol_share,
            reference_price = routes.eol_reference_price,
            reference_total = routes.eol_reference_total,
            elasticity = routes.eol_allocation_elasticity,
            positive_lower = lower,
        ),
    )
    eol_production = Any[
        EOLProductivityProductionBlock(
            Symbol(:eol_productivity_production_, region),
            eol_activities_by_region[region],
            outline.factors_by_region[region],
            outline.industries_by_region[region],
            (
                b = calibration.production_scale,
                beta = calibration.factor_share,
                ay = calibration.value_added_coefficient,
                ax = calibration.intermediate_coefficient,
                eol_productivity_elasticity = routes.eol_productivity_elasticity,
                positive_lower = lower,
            ),
        )
        for region in outline.regions
    ]
    service_demand = CircularServiceDemandBlock(
        :regional_circular_service_demand,
        routes,
        outline.factors_by_region,
        outline.industries_by_region,
        (
            service_share = routes.service_share,
            route_share = routes.route_share,
            elasticity = routes.service_elasticity,
            scenario = scenario,
            include_policy_transfer = include_policy_transfer,
            positive_lower = lower,
        ),
    )
    price_index = CircularHouseholdPriceIndexBlock(
        :regional_circular_household_price_index,
        routes,
        outline.regions,
        (
            nonservice_share = calibration.household_share,
            service_share = routes.service_share,
            common_weight = calibration.common_price_weight,
            positive_lower = lower,
        ),
    )
    utility = CircularHouseholdUtilityBlock(
        :regional_circular_household_utility,
        routes,
        outline.regions,
        (
            nonservice_share = calibration.household_share,
            service_share = routes.service_share,
        ),
    )
    return (
        eol_allocation = eol_allocation,
        eol_production = eol_production,
        service_demand = service_demand,
        price_index = price_index,
        utility = utility,
        eol_activities_by_region = eol_activities_by_region,
    )
end
