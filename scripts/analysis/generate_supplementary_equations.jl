"""
Generate the model-derived equation listing for the Supplementary Information.

The mathematical content is produced directly by `JCGEOutput` from the
registered equation AST. This script does not rename symbols, replace terms,
or construct equations. Its sole presentation step inserts LaTeX line breaks
at additive operators so that long generated expressions fit the SI page.
"""

using CERiseCGE
using JCGECore
using JCGEOutput
using JCGERuntime
using DataFrames

const PROJECT_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const EQUATION_OUTPUT = joinpath(PROJECT_ROOT, "article", "generated",
    "si_model_equation_inventory.tex")

function _build_context(model::CERiseCGE.MultiRegionModelSpec)
    spec = CERiseCGE.run_spec(model)
    ctx = JCGERuntime.KernelContext()
    for block in spec.model.blocks
        JCGECore.build!(block, ctx, spec)
    end
    return ctx
end

"""Map each declared regional industry identifier to its region and product."""
function _activity_report_coordinates(model::CERiseCGE.MultiRegionModelSpec)
    coordinates = Dict{Symbol,Tuple{Symbol,Symbol}}()
    for ((region, product), activity) in model.calibration.product_by_region
        haskey(coordinates, activity) && error("Duplicate report coordinate for $(activity).")
        coordinates[activity] = (region, product)
    end
    return coordinates
end

"""Declare the two factor labels used by the calibrated regional factor sets."""
function _factor_report_coordinates(model::CERiseCGE.MultiRegionModelSpec)
    labels = (:LAB, :CAP)
    coordinates = Dict{Symbol,Tuple{Symbol,Symbol}}()
    for region in model.outline.regions
        factors = model.outline.factors_by_region[region]
        length(factors) == length(labels) || error(
            "The report mapping expects $(length(labels)) factors in $(region), found $(length(factors)).")
        for (factor, label) in zip(factors, labels)
            haskey(coordinates, factor) && error("Duplicate report coordinate for $(factor).")
            coordinates[factor] = (region, label)
        end
    end
    return coordinates
end

function _collect_domain_values!(values::Set{Symbol}, expr::JCGECore.EquationExpr)
    if expr isa JCGECore.EAdd
        foreach(term -> _collect_domain_values!(values, term), expr.terms)
    elseif expr isa JCGECore.EMul
        foreach(factor -> _collect_domain_values!(values, factor), expr.factors)
    elseif expr isa JCGECore.EPow
        _collect_domain_values!(values, expr.base)
        _collect_domain_values!(values, expr.exponent)
    elseif expr isa JCGECore.EDiv
        _collect_domain_values!(values, expr.numerator)
        _collect_domain_values!(values, expr.denominator)
    elseif expr isa JCGECore.ENeg || expr isa JCGECore.ELog
        _collect_domain_values!(values, expr.expr)
    elseif expr isa JCGECore.ESum || expr isa JCGECore.EProd
        union!(values, expr.domain)
        _collect_domain_values!(values, expr.expr)
    elseif expr isa JCGECore.EEq || expr isa JCGECore.ELe || expr isa JCGECore.EGe
        _collect_domain_values!(values, expr.lhs)
        _collect_domain_values!(values, expr.rhs)
    end
    return values
end

function _selected_domain_values(equations, labels::Dict{Symbol,Symbol})
    values = Set{Symbol}()
    for equation in equations
        payload = equation.payload
        payload isa NamedTuple || continue
        for field in (:expr, :objective_expr)
            expression = get(payload, field, nothing)
            expression isa JCGECore.EquationExpr || continue
            _collect_domain_values!(values, expression)
        end
    end
    return Dict(value => labels[value] for value in values if haskey(labels, value))
end

function _collect_expression_indices!(values::Set{Symbol}, expr::JCGECore.EquationExpr)
    if expr isa JCGECore.EIndex
        push!(values, expr.name)
    elseif expr isa JCGECore.EVar || expr isa JCGECore.EParam
        isnothing(expr.idxs) || foreach(index ->
            index isa JCGECore.EquationExpr && _collect_expression_indices!(values, index),
            expr.idxs)
    elseif expr isa JCGECore.EAdd
        foreach(term -> _collect_expression_indices!(values, term), expr.terms)
    elseif expr isa JCGECore.EMul
        foreach(factor -> _collect_expression_indices!(values, factor), expr.factors)
    elseif expr isa JCGECore.EPow
        _collect_expression_indices!(values, expr.base)
        _collect_expression_indices!(values, expr.exponent)
    elseif expr isa JCGECore.EDiv
        _collect_expression_indices!(values, expr.numerator)
        _collect_expression_indices!(values, expr.denominator)
    elseif expr isa JCGECore.ENeg || expr isa JCGECore.ELog ||
            expr isa JCGECore.ESum || expr isa JCGECore.EProd
        _collect_expression_indices!(values, expr.expr)
    elseif expr isa JCGECore.EEq || expr isa JCGECore.ELe || expr isa JCGECore.EGe
        _collect_expression_indices!(values, expr.lhs)
        _collect_expression_indices!(values, expr.rhs)
    end
    return values
end

function _selected_index_projections(equations, projections::AbstractDict)
    used = Set{Symbol}()
    for equation in equations
        payload = equation.payload
        payload isa NamedTuple || continue
        for field in (:expr, :objective_expr)
            expression = get(payload, field, nothing)
            expression isa JCGECore.EquationExpr || continue
            _collect_expression_indices!(used, expression)
        end
    end
    return Dict(Symbol(index) => Tuple(Symbol.(positions))
        for (index, positions) in projections if Symbol(index) in used)
end

function _collect_reference_keys!(keys::Set{Tuple{Symbol,Symbol,Tuple}},
    expr::JCGECore.EquationExpr)
    if expr isa JCGECore.EVar || expr isa JCGECore.EParam
        isnothing(expr.idxs) && return keys
        kind = expr isa JCGECore.EVar ? :variable : :parameter
        push!(keys, (kind, expr.name, Tuple(expr.idxs)))
    elseif expr isa JCGECore.EAdd
        foreach(term -> _collect_reference_keys!(keys, term), expr.terms)
    elseif expr isa JCGECore.EMul
        foreach(factor -> _collect_reference_keys!(keys, factor), expr.factors)
    elseif expr isa JCGECore.EPow
        _collect_reference_keys!(keys, expr.base)
        _collect_reference_keys!(keys, expr.exponent)
    elseif expr isa JCGECore.EDiv
        _collect_reference_keys!(keys, expr.numerator)
        _collect_reference_keys!(keys, expr.denominator)
    elseif expr isa JCGECore.ENeg || expr isa JCGECore.ELog ||
            expr isa JCGECore.ESum || expr isa JCGECore.EProd
        _collect_reference_keys!(keys, expr.expr)
    elseif expr isa JCGECore.EEq || expr isa JCGECore.ELe || expr isa JCGECore.EGe
        _collect_reference_keys!(keys, expr.lhs)
        _collect_reference_keys!(keys, expr.rhs)
    end
    return keys
end

function _selected_reference_indices(equations,
    patterns::Dict{Symbol,Tuple{Vararg{Symbol}}},
    overrides::Dict{Tuple{Symbol,Symbol,Tuple},Tuple})
    keys = Set{Tuple{Symbol,Symbol,Tuple}}()
    for equation in equations
        payload = equation.payload
        payload isa NamedTuple || continue
        for field in (:expr, :objective_expr)
            expression = get(payload, field, nothing)
            expression isa JCGECore.EquationExpr || continue
            _collect_reference_keys!(keys, expression)
        end
    end
    selected = Dict{Tuple{Symbol,Symbol,Tuple},Tuple}()
    for key in keys
        if haskey(overrides, key)
            selected[key] = overrides[key]
            continue
        end
        positions = ()
        for value in key[3]
            value isa Symbol && haskey(patterns, value) || (positions = (); break)
            positions = (positions..., patterns[value])
        end
        isempty(positions) || (selected[key] = positions)
    end
    return selected
end

function _add_report_mapping!(mappings::Vector{EquationReportMapping},
    context::JCGERuntime.KernelContext;
    source_block::Symbol,
    source_tag::Symbol,
    index_names::Tuple,
    coordinates_for,
    report_block::Symbol=source_block,
    report_tag::Symbol=source_tag,
    domain_labels::Dict{Symbol,Symbol}=Dict{Symbol,Symbol}(),
    index_projections::AbstractDict=Dict{Symbol,Tuple{Vararg{Symbol}}}(),
    reference_patterns::Dict{Symbol,Tuple{Vararg{Symbol}}}=Dict{Symbol,Tuple{Vararg{Symbol}}}(),
    reference_overrides::Dict{Tuple{Symbol,Symbol,Tuple},Tuple}=Dict{Tuple{Symbol,Symbol,Tuple},Tuple}())
    equations = [equation for equation in JCGERuntime.list_equations(context)
        if equation.block === source_block && equation.tag === source_tag]
    isempty(equations) && return nothing
    coordinates = Dict{Tuple,Tuple}()
    for equation in equations
        payload = equation.payload
        payload isa NamedTuple || error("$(source_block).$(source_tag) has no equation payload.")
        source_indices = Tuple(get(payload, :indices, ()))
        report_indices = Tuple(coordinates_for(source_indices))
        length(report_indices) == length(index_names) || error(
            "Report mapping for $(source_block).$(source_tag) produced $(length(report_indices)) indices; " *
            "$(length(index_names)) were declared.")
        haskey(coordinates, source_indices) && error(
            "Duplicate registered indices $(source_indices) in $(source_block).$(source_tag).")
        coordinates[source_indices] = report_indices
    end
    push!(mappings, EquationReportMapping(
        source_block = source_block,
        source_tag = source_tag,
        report_block = report_block,
        report_tag = report_tag,
        index_names = index_names,
        coordinates = coordinates,
        domain_values = _selected_domain_values(equations, domain_labels),
        index_projections = _selected_index_projections(equations, index_projections),
        reference_indices = _selected_reference_indices(equations, reference_patterns,
            reference_overrides),
    ))
    return nothing
end

function _route_by_activity(model::CERiseCGE.MultiRegionModelSpec)
    routes = Dict{Symbol,Symbol}()
    for goods in values(model.circular_routes.route_goods_by_service)
        for (route, activity) in goods
            haskey(routes, activity) && routes[activity] != route && error(
                "Conflicting route labels for $(activity).")
            routes[activity] = route
        end
    end
    for ((_, product), activity) in model.calibration.product_by_region
        product === :REC_EE && (routes[activity] = :REC)
        product === :INC_EE && (routes[activity] = :INC)
    end
    return routes
end

function _eol_line_report_coordinates(model::CERiseCGE.MultiRegionModelSpec,
    activity_coordinates::Dict{Symbol,Tuple{Symbol,Symbol}})
    routes = _route_by_activity(model)
    coordinates = Dict{Symbol,Tuple{Symbol,Symbol,Symbol}}()
    for (family, lines) in model.circular_routes.eol_lines_by_family
        for line in lines
            activity = model.circular_routes.eol_line_activity[line]
            region, _ = activity_coordinates[activity]
            route = get(routes, activity, nothing)
            route === nothing && error("No declared route label for EOL activity $(activity).")
            coordinates[line] = (region, family, route)
        end
    end
    return coordinates
end

function _physical_flow_report_coordinates(model::CERiseCGE.MultiRegionModelSpec)
    coordinates = Dict{Symbol,Tuple{Symbol,Symbol,Symbol,Symbol}}()
    for row in eachrow(model.outline.bundle.physical_flows)
        id = Symbol(:physical_, Symbol(row.region), :_, Symbol(row.family), :_,
            Symbol(row.route), :_, Symbol(row.flow_kind))
        coordinates[id] = (Symbol(row.region), Symbol(row.family), Symbol(row.route),
            Symbol(row.flow_kind))
    end
    return coordinates
end

function _circular_metal_report_coordinates(model::CERiseCGE.MultiRegionModelSpec,
    activity_coordinates::Dict{Symbol,Tuple{Symbol,Symbol}})
    profile = model.circular_metal
    profile === nothing && return (recovery = Dict{Symbol,Tuple}(),
        observed_recycled = Dict{Symbol,Tuple}(), primary = Dict{Symbol,Tuple}(),
        recycled = Dict{Symbol,Tuple}(), demand = Dict{Symbol,Tuple}())
    structure = CERiseCGE._circular_metal_structure(model, profile)
    recovery = Dict{Symbol,Tuple}()
    for row in eachrow(model.outline.bundle.physical_flows)
        Symbol(row.route) === :REC || continue
        Symbol(row.flow_kind) === :route_input_mass || continue
        String(row.status) == "observed" || continue
        id = CERiseCGE._circular_recovery_input_id(Symbol(row.region), Symbol(row.family))
        recovery[id] = (Symbol(row.region), Symbol(row.family), :REC)
    end
    observed_recycled = Dict(id => (metadata.region, :REC)
        for (id, metadata) in structure.observed_recycled_metadata)
    primary = Dict(id => (metadata.region, metadata.material)
        for (id, metadata) in structure.primary_metadata)
    recycled = Dict(id => (metadata.region, metadata.material)
        for (id, metadata) in structure.recycled_supply_metadata)
    demand = Dict{Symbol,Tuple}()
    for region in model.outline.regions
        for material in (:primary, :recycled)
            for activity in model.outline.industries_by_region[region]
                _, product = activity_coordinates[activity]
                id = CERiseCGE._circular_industry_demand_id(region, material, activity)
                demand[id] = (region, material, product)
            end
            for role in (:households, :government, :investment)
                id = CERiseCGE._circular_final_demand_id(region, material, role)
                demand[id] = (region, material, role)
            end
        end
    end
    for trade_route in model.calibration.trade_routes
        trade_route.destination === :ROW || continue
        material = trade_route.product === :BASIC_METALS ? :primary :
            trade_route.product === :REC_EE ? :recycled : nothing
        material === nothing && continue
        id = CERiseCGE._circular_export_id(material, trade_route.id)
        demand[id] = (trade_route.origin, material, :ROW)
    end
    return (recovery = recovery, observed_recycled = observed_recycled, primary = primary,
        recycled = recycled, demand = demand)
end

function _register_reference_pattern!(patterns::Dict{Symbol,Tuple{Vararg{Symbol}}},
    source::Symbol, report_indices::Tuple)
    normalized = Tuple(Symbol.(report_indices))
    existing = get(patterns, source, nothing)
    isnothing(existing) || existing == normalized || error(
        "Conflicting report-reference mappings for $(source).")
    patterns[source] = normalized
    return nothing
end

function _model_report_mappings(context::JCGERuntime.KernelContext,
    model::CERiseCGE.MultiRegionModelSpec)
    mappings = EquationReportMapping[]
    activity_coordinates = _activity_report_coordinates(model)
    factor_coordinates = _factor_report_coordinates(model)
    activity_labels = Dict(activity => product for (activity, (_, product)) in activity_coordinates)
    factor_labels = Dict(factor => label for (factor, (_, label)) in factor_coordinates)
    domain_labels = merge(activity_labels, factor_labels)
    eol_line_coordinates = _eol_line_report_coordinates(model, activity_coordinates)
    service_coordinates = Dict(service => (model.circular_routes.service_region[service],
        model.circular_routes.service_family[service]) for service in model.circular_routes.services)
    physical_coordinates = _physical_flow_report_coordinates(model)
    metal_coordinates = _circular_metal_report_coordinates(model, activity_coordinates)
    reference_patterns = Dict{Symbol,Tuple{Vararg{Symbol}}}()
    for activity in keys(activity_coordinates)
        _register_reference_pattern!(reference_patterns, activity, (:region, :product))
    end
    for factor in keys(factor_coordinates)
        _register_reference_pattern!(reference_patterns, factor, (:region, :factor))
    end
    for line in keys(eol_line_coordinates)
        _register_reference_pattern!(reference_patterns, line, (:region, :family, :route))
    end
    for service in keys(service_coordinates)
        _register_reference_pattern!(reference_patterns, service, (:region, :family))
    end
    for id in keys(physical_coordinates)
        _register_reference_pattern!(reference_patterns, id, (:region, :family, :route, :flow_kind))
    end
    for (coordinates, names) in (
        (metal_coordinates.recovery, (:region, :family, :route)),
        (metal_coordinates.observed_recycled, (:region, :route)),
        (metal_coordinates.primary, (:region, :material)),
        (metal_coordinates.recycled, (:region, :material)),
        (metal_coordinates.demand, (:region, :material, :use)),
    )
        for id in keys(coordinates)
            _register_reference_pattern!(reference_patterns, id, names)
        end
    end
    eol_reference_overrides = Dict{Tuple{Symbol,Symbol,Tuple},Tuple}()
    eol_availability_reference_overrides = Dict{Tuple{Symbol,Symbol,Tuple},Tuple}()
    for (family, lines) in model.circular_routes.eol_lines_by_family
        for line in lines
            eol_reference_overrides[(:parameter, :share, (family, line))] =
                ((:family,), (:region, :route))
            activity = model.circular_routes.eol_line_activity[line]
            eol_availability_reference_overrides[(:parameter, :share, (family, activity))] =
                ((:family,), (:region, :product))
        end
    end
    metal_demand_reference_overrides = Dict{Tuple{Symbol,Symbol,Tuple},Tuple}()
    for trade_route in model.calibration.trade_routes
        trade_route.destination === :ROW || continue
        material = trade_route.product === :BASIC_METALS ? :primary :
            trade_route.product === :REC_EE ? :recycled : nothing
        material === nothing && continue
        export_id = CERiseCGE._circular_export_id(material, trade_route.id)
        haskey(metal_coordinates.demand, export_id) || continue
        metal_demand_reference_overrides[(:variable, :T, (trade_route.id,))] =
            ((:region,), (:material,), (:use,))
    end
    add_mapping(; kwargs...) = _add_report_mapping!(mappings, context;
        domain_labels=domain_labels, reference_patterns=reference_patterns, kwargs...)

    product_region = source -> begin
        good, region = source
        mapped_region, product = activity_coordinates[good]
        mapped_region === region || error("$(good) is not assigned to $(region).")
        return (product, region)
    end
    for (block, tag) in (
        (:regional_composite_market, :regional_composite_market),
        (:regional_fixed_investment, :regional_fixed_investment),
        (:regional_government_demand, :regional_government_demand),
        (:regional_government_demand, :regional_output_tax),
        (:regional_household_demand, :regional_household_demand),
    )
        add_mapping(; source_block=block, source_tag=tag,
            index_names=(:product, :region), coordinates_for=product_region,
            index_projections=Dict(:good => (:product,), :region => (:region,)),
        )
    end
    factor_region = source -> begin
        factor, region = source
        mapped_region, label = factor_coordinates[factor]
        mapped_region === region || error("$(factor) is not assigned to $(region).")
        return (label, region)
    end
    for tag in (:factor_availability, :fixed_real_factor_price)
        add_mapping(; source_block=:regional_factor_availability,
            source_tag=tag, index_names=(:factor, :region),
            coordinates_for=factor_region,
            index_projections=Dict(:factor => (:factor,), :region => (:region,)))
    end
    region_only = source -> (only(source),)
    for (block, tag) in (
        (:regional_government_demand, :regional_direct_tax),
        (:regional_private_saving, :regional_private_saving),
    )
        add_mapping(; source_block=block, source_tag=tag, index_names=(:region,),
            coordinates_for=region_only,
            index_projections=Dict(:region => (:region,)))
    end

    # Standard production and the EOL-productivity variant share the same
    # declared regional activity, factor, and input-product coordinates.
    # Only their technology terms differ; the report keeps those families
    # separate while using the same compact index vocabulary.
    for region in model.outline.regions
        for source_block in (Symbol(:production_, region),
            Symbol(:eol_productivity_production_, region))
            standard_production = startswith(String(source_block), "production_")
            activity_index = standard_production ? :i : :activity
            factor_index = standard_production ? :h : :factor
            input_index = standard_production ? :j : :commodity
            report_block = standard_production ? :production : :eol_productivity_production
            product = source -> begin
                mapped_region, label = activity_coordinates[only(source)]
                mapped_region === region || error("$(only(source)) is not assigned to $(region).")
                return (label, region)
            end
            for tag in (:eqpy, :eqY, :eqpzs)
                add_mapping(; source_block=source_block, source_tag=tag,
                    report_block=report_block, index_names=(:product, :region),
                    coordinates_for=product,
                    index_projections=Dict(activity_index => (:product, :region)))
            end
            factor_product = source -> begin
                factor, activity = source
                factor_region, factor_label = factor_coordinates[factor]
                activity_region, product_label = activity_coordinates[activity]
                factor_region === region && activity_region === region || error(
                    "Cross-region factor or activity in $(source_block).")
                return (factor_label, product_label, region)
            end
            add_mapping(; source_block=source_block, source_tag=:eqF,
                report_block=report_block, index_names=(:factor, :product, :region),
                coordinates_for=factor_product,
                index_projections=Dict(factor_index => (:factor,),
                    activity_index => (:product, :region)))
            input_product = source -> begin
                input, activity = source
                input_region, input_label = activity_coordinates[input]
                activity_region, product_label = activity_coordinates[activity]
                input_region === region && activity_region === region || error(
                    "Cross-region input or activity in $(source_block).")
                return (input_label, product_label, region)
            end
            add_mapping(; source_block=source_block, source_tag=:eqX,
                report_block=report_block, index_names=(:input_product, :product, :region),
                coordinates_for=input_product,
                index_projections=Dict(input_index => (:input_product,),
                    activity_index => (:product, :region)))
        end
    end

    for region in model.outline.regions
        source_block = Symbol(:material_composite_production_, region)
        product = activity -> begin
            mapped_region, label = activity_coordinates[only(activity)]
            mapped_region === region || error("$(only(activity)) is not assigned to $(region).")
            return (label, region)
        end
        for tag in (:eqpy, :eqY, :eqpzs, :material_composite_price)
            add_mapping(; source_block=source_block, source_tag=tag,
                report_block=:material_composite_production, index_names=(:product, :region),
                coordinates_for=product,
                index_projections=Dict(:activity => (:product, :region)))
        end
        factor_product = source -> begin
            factor, activity = source
            factor_region, factor_label = factor_coordinates[factor]
            activity_region, product_label = activity_coordinates[activity]
            factor_region === region && activity_region === region || error(
                "Cross-region factor or activity in $(source_block).")
            return (factor_label, product_label, region)
        end
        add_mapping(; source_block=source_block, source_tag=:eqF,
            report_block=:material_composite_production,
            index_names=(:factor, :product, :region), coordinates_for=factor_product,
            index_projections=Dict(:factor => (:factor,),
                :activity => (:product, :region)),
        )
        commodity_product = source -> begin
            commodity, activity = source
            commodity_region, commodity_label = activity_coordinates[commodity]
            activity_region, product_label = activity_coordinates[activity]
            commodity_region === region && activity_region === region || error(
                "Cross-region commodity or activity in $(source_block).")
            return (commodity_label, product_label, region)
        end
        add_mapping(; source_block=source_block, source_tag=:eqX,
            report_block=:material_composite_production,
            index_names=(:input_product, :product, :region),
            coordinates_for=commodity_product,
            index_projections=Dict(:commodity => (:input_product,),
                :activity => (:product, :region)))
        add_mapping(; source_block=source_block,
            source_tag=:material_composite_demand,
            report_block=:material_composite_production,
            index_names=(:product, :material, :region),
            coordinates_for=source -> begin
                activity, commodity = source
                activity_region, product_label = activity_coordinates[activity]
                commodity_region, material = activity_coordinates[commodity]
                activity_region === region && commodity_region === region || error(
                    "Cross-region material composite in $(source_block).")
                (product_label, material, region)
            end,
            index_projections=Dict(:activity => (:product, :region),
                :commodity => (:material,)))
    end

    add_mapping(; source_block=:eu_wide_eol_allocation,
        source_tag=:eu_wide_eol_allocation, index_names=(:region, :family, :route),
        coordinates_for=source -> eol_line_coordinates[last(source)],
        index_projections=Dict(:family => (:family,),
            :line => (:region, :family, :route)),
        reference_overrides=eol_reference_overrides)
    add_mapping(; source_block=:eu_wide_eol_allocation,
        source_tag=:eol_activity_availability, index_names=(:region, :product),
        coordinates_for=source -> activity_coordinates[only(source)],
        index_projections=Dict(:activity => (:region, :product)),
        reference_overrides=eol_availability_reference_overrides)

    for tag in (:circular_service_price, :circular_service_demand)
        add_mapping(; source_block=:regional_circular_service_demand,
            source_tag=tag, index_names=(:region, :family),
            coordinates_for=source -> service_coordinates[only(source)],
            index_projections=Dict(:service => (:region, :family)))
    end
    service_route_coordinates = Dict{Tuple{Symbol,Symbol},Tuple{Symbol,Symbol,Symbol}}()
    for (service, goods) in model.circular_routes.route_goods_by_service
        region, family = service_coordinates[service]
        for (route, good) in goods
            service_route_coordinates[(service, good)] = (region, family, route)
        end
    end
    add_mapping(; source_block=:regional_circular_service_demand,
        source_tag=:circular_route_demand, index_names=(:region, :family, :route),
        coordinates_for=source -> service_route_coordinates[source],
        index_projections=Dict(:service => (:region, :family),
            :good => (:region, :family, :route)))

    add_mapping(; source_block=:observed_physical_flow_links,
        source_tag=:quantity_link, index_names=(:region, :family, :route, :flow_kind),
        coordinates_for=source -> physical_coordinates[only(source)],
        index_projections=Dict(:quantity => (:region, :family, :route, :flow_kind)))
    add_mapping(; source_block=:observed_recycling_throughput,
        source_tag=:quantity_link, index_names=(:region, :family, :route),
        coordinates_for=source -> metal_coordinates.recovery[only(source)],
        index_projections=Dict(:quantity => (:region, :family, :route)))
    add_mapping(; source_block=:observed_recycled_metal_output,
        source_tag=:quantity_transformation, index_names=(:region, :route),
        coordinates_for=source -> metal_coordinates.observed_recycled[only(source)],
        index_projections=Dict(:output => (:region, :route)))
    add_mapping(; source_block=:primary_metal_output,
        source_tag=:quantity_link, index_names=(:region, :material),
        coordinates_for=source -> metal_coordinates.primary[only(source)],
        index_projections=Dict(:quantity => (:region, :material)))
    add_mapping(; source_block=:recycled_metal_output,
        source_tag=:quantity_link, index_names=(:region, :material),
        coordinates_for=source -> metal_coordinates.recycled[only(source)],
        index_projections=Dict(:quantity => (:region, :material)))
    add_mapping(;
        source_block=:metal_demand_from_primary_and_recycled_metal_use,
        source_tag=:quantity_link, index_names=(:region, :material, :use),
        coordinates_for=source -> metal_coordinates.demand[only(source)],
        index_projections=Dict(:quantity => (:region, :material, :use)),
        reference_overrides=metal_demand_reference_overrides)
    return mappings
end

function _top_level_terms(text::AbstractString)
    chars = collect(text)
    terms = String[]
    depth = 0
    start = firstindex(chars)
    for position in eachindex(chars)
        char = chars[position]
        if char == '{'
            depth += 1
        elseif char == '}'
            depth -= 1
        elseif depth == 0 && position > firstindex(chars) && position < lastindex(chars) &&
                char in ('+', '-') && chars[position - 1] == ' ' && chars[position + 1] == ' '
            push!(terms, strip(String(chars[start:position - 1])))
            start = position
        end
    end
    push!(terms, strip(String(chars[start:end])))
    return terms
end

function _top_level_products(text::AbstractString)
    chars = collect(text)
    terms = String[]
    depth = 0
    start = firstindex(chars)
    for position in eachindex(chars)
        char = chars[position]
        if char == '{'
            depth += 1
        elseif char == '}'
            depth -= 1
        elseif depth == 0 && position > firstindex(chars) &&
                _starts_with(chars, position, "\\cdot")
            push!(terms, strip(String(chars[start:position - 1])))
            start = position
        end
    end
    push!(terms, strip(String(chars[start:end])))
    return terms
end

function _pack_terms(terms::Vector{String}; width::Int)
    isempty(terms) && return String[]
    chunks = String[]
    current = first(terms)
    for term in terms[2:end]
        candidate = string(current, " ", term)
        if ncodeunits(candidate) > width
            push!(chunks, current)
            current = term
        else
            current = candidate
        end
    end
    push!(chunks, current)
    return chunks
end

function _multiline_sum(text::AbstractString; width::Int, alignment::AbstractString)
    terms = _top_level_terms(text)
    length(terms) <= 1 && return String(text)
    chunks = _pack_terms(terms; width=width)
    length(chunks) <= 1 && return String(text)
    return join([first(chunks); [string(alignment, "{}", chunk) for chunk in chunks[2:end]]],
        string("\\\\", '\n'))
end

function _multiline_product(text::AbstractString; width::Int, alignment::AbstractString)
    terms = _top_level_products(text)
    length(terms) <= 1 && return String(text)
    chunks = _pack_terms(terms; width=width)
    length(chunks) <= 1 && return String(text)
    return join([first(chunks); [string(alignment, "{}", chunk) for chunk in chunks[2:end]]],
        string("\\\\", '\n'))
end

function _starts_with(chars::Vector{Char}, position::Int, token::AbstractString)
    token_chars = collect(token)
    last_position = position + length(token_chars) - 1
    last_position <= length(chars) || return false
    return chars[position:last_position] == token_chars
end

function _braced_group(chars::Vector{Char}, opening::Int)
    chars[opening] == '{' || error("Expected a braced LaTeX group.")
    depth = 0
    for position in opening:length(chars)
        char = chars[position]
        char == '{' && (depth += 1)
        char == '}' && (depth -= 1)
        depth == 0 && return String(chars[opening + 1:position - 1]), position
    end
    error("Unbalanced LaTeX group in generated equation report.")
end

function _format_long_fractions(text::AbstractString; width::Int)
    chars = collect(text)
    rendered = IOBuffer()
    position = firstindex(chars)
    while position <= lastindex(chars)
        if _starts_with(chars, position, "\\frac{")
            numerator, numerator_end = _braced_group(chars, position + 5)
            denominator_start = numerator_end + 1
            denominator, denominator_end = _braced_group(chars, denominator_start)
            numerator = _format_long_fractions(numerator; width=width)
            denominator = _format_long_fractions(denominator; width=width)
            denominator_terms = _top_level_terms(denominator)
            if length(denominator_terms) > 1 && ncodeunits(denominator) > width
                denominator = "\\begin{aligned}\n" *
                    _multiline_sum(denominator; width=width, alignment="") *
                    "\n\\end{aligned}"
            end
            print(rendered, "\\frac{", numerator, "}{", denominator, "}")
            position = denominator_end + 1
        else
            print(rendered, chars[position])
            position += 1
        end
    end
    return String(take!(rendered))
end

function _wrap_equation_line(line::AbstractString; width::Int=132)
    formatted = _format_long_fractions(line; width=width)
    for relation in (" &= ", " &\\le ", " &\\ge ")
        location = findfirst(relation, formatted)
        isnothing(location) && continue
        lhs = formatted[firstindex(formatted):first(location) - 1]
        rhs_start = last(location) + 1
        rhs = formatted[rhs_start:end]
        wrapped_rhs = _multiline_sum(rhs; width=width, alignment="&\\quad ")
        wrapped_rhs == rhs && (wrapped_rhs = _multiline_product(rhs;
            width=width, alignment="&\\quad "))
        return string(lhs, relation, wrapped_rhs)
    end
    return formatted
end

function _format_for_si(report::AbstractString)
    lines = split(report, '\n'; keepempty=true)
    return join([_wrap_equation_line(line) for line in lines], "\n")
end

function main()
    isdir(dirname(EQUATION_OUTPUT)) || error("Missing article generated directory.")
    model = CERiseCGE.multi_region_model()
    context = _build_context(model)
    report = JCGEOutput.render_equation_report(context; format=:latex, view=:indexed,
        report_mappings=_model_report_mappings(context, model))
    write(EQUATION_OUTPUT, _format_for_si(report))
    println("Wrote $(EQUATION_OUTPUT).")
end

main()
