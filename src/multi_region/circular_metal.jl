"""
Physical accounting for one EU-wide `METAL` market.

Every monetary use and output of `BASIC_METALS` is converted with one fixed
external METAL price.  This gives a common physical unit to all industries,
the CE-RISE routes, final demand, and extra-European exports.  Domestic
primary supply is the corresponding physical output of `BASIC_METALS`.
Recovered METAL is added from the observed recycling throughput and its
recovery-yield sensitivity; external imports close the physical balance.
"""

"""Return the physical coefficients needed by the baseline METAL market."""
function circular_metal_parameter_schema(model::MultiRegionModelSpec)
    required = Set(["external_price", "recovery_yield"])
    return filter(row -> String(row.coefficient_kind) in required,
        copy(model.coefficient_template))
end

function _circular_profile_value(value, id::Symbol)
    value isa Real || error("Circular-metal parameter $(id) must be numeric.")
    number = Float64(value)
    isfinite(number) || error("Circular-metal parameter $(id) must be finite.")
    number >= 0.0 || error("Circular-metal parameter $(id) must be non-negative.")
    return number
end

function _circular_profile_ids(model::MultiRegionModelSpec)
    return Symbol.(circular_metal_parameter_schema(model).coefficient_id)
end

"""
    circular_metal_profile(model, values)

Validate the physical sensitivity inputs for the baseline METAL market.  The
external-price entry is provided once per region in the input template but all
six values must be identical because the model has one EU-wide METAL price.
"""
function circular_metal_profile(model::MultiRegionModelSpec, values::AbstractDict)
    schema = circular_metal_parameter_schema(model)
    required = Symbol.(schema.coefficient_id)
    kinds = Dict(Symbol(row.coefficient_id) => Symbol(row.coefficient_kind)
        for row in eachrow(schema))
    profile = Dict{Symbol,Float64}()
    for id in required
        raw = get(values, id, nothing)
        raw === nothing && error("Circular-metal sensitivity profile is missing $(id).")
        value = _circular_profile_value(raw, id)
        kinds[id] === :external_price && value <= 0.0 &&
            error("Circular-metal external price $(id) must be strictly positive.")
        profile[id] = value
    end
    supplied = Set(Symbol.(collect(keys(values))))
    extra = setdiff(supplied, Set(required))
    isempty(extra) || error("Circular-metal sensitivity profile has unknown coefficients: $(join(string.(sort!(collect(extra))), ", ")).")
    return CircularMetalProfile(profile)
end

"""Load a circular-metal sensitivity profile from coefficient_id/value rows."""
function circular_metal_profile(model::MultiRegionModelSpec, table::DataFrame)
    required_columns = Set([:coefficient_id, :value])
    required_columns ⊆ Set(Symbol.(names(table))) ||
        error("Circular-metal sensitivity table requires coefficient_id and value columns.")
    values = Dict{Symbol,Any}()
    for row in eachrow(table)
        id = Symbol(row.coefficient_id)
        haskey(values, id) && error("Circular-metal sensitivity table repeats $(id).")
        values[id] = row.value
    end
    return circular_metal_profile(model, values)
end

"""Load the declared six-region calibration profile for the physical METAL market."""
function circular_metal_baseline_profile(model::MultiRegionModelSpec)
    table = model.outline.bundle.circular_metal_baseline
    nrow(table) > 0 || error("The calibration bundle has no circular-metal baseline profile.")
    return circular_metal_profile(model, table)
end

const _CIRCULAR_METAL_VAR = :physical_tonnes
const _CIRCULAR_METAL_PRICE_VAR = :P_METAL
const _CIRCULAR_METAL_IMPORT_VAR = :METAL_IMPORT

_circular_recovery_input_id(region::Symbol, family::Symbol) =
    Symbol(:metal_recovery_input_, region, :_, family)
_circular_recycled_id(region::Symbol) = Symbol(:metal_recycled_, region)
_circular_primary_id(region::Symbol) = Symbol(:metal_primary_, region)
_circular_industry_demand_id(region::Symbol, activity::Symbol) =
    Symbol(:metal_industry_demand_, region, :_, activity)
_circular_final_demand_id(region::Symbol, role::Symbol) =
    Symbol(:metal_final_demand_, region, :_, role)
_circular_export_id(route::Symbol) = Symbol(:metal_export_, route)
_circular_inventory_id(region::Symbol) = Symbol(:metal_inventory_change_, region)

"""Model-local clearing block for the EU-wide physical METAL market."""
struct SharedMetalMarketBlock <: JCGECore.AbstractBlock
    name::Symbol
    demand::Vector{Symbol}
    primary_supply::Vector{Symbol}
    recycled_supply::Vector{Symbol}
    fixed_demand::Vector{Symbol}
    quantity_var::Symbol
    price_var::Symbol
    import_var::Symbol
    params::NamedTuple
end

function _ensure_shared_metal_variable!(ctx::JCGERuntime.KernelContext, model,
    name::Symbol; lower::Float64)
    haskey(ctx.variables, name) && return ctx.variables[name]
    variable = model isa JuMP.Model ?
        JuMP.@variable(model, lower_bound=lower, base_name=string(name)) :
        (name=name,)
    JCGERuntime.register_variable!(ctx, name, variable)
    return variable
end

function _register_shared_metal_equation!(ctx::JCGERuntime.KernelContext,
    block::SharedMetalMarketBlock, tag::Symbol, ids::Symbol...;
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

function _require_shared_metal_quantity!(ctx::JCGERuntime.KernelContext,
    quantity_var::Symbol, id::Symbol, role::AbstractString)
    name = JCGEBlocks.global_var(quantity_var, id)
    haskey(ctx.variables, name) || error("$(role) requires physical quantity $(name) from an earlier block.")
    return nothing
end

function JCGECore.build!(block::SharedMetalMarketBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Shared metal market requires a strictly positive price lower bound.")
    external_price = Float64(block.params.external_price)
    external_price > 0.0 || error("Shared metal market requires a strictly positive external price.")

    _ensure_shared_metal_variable!(ctx, model, block.price_var; lower=lower)
    _ensure_shared_metal_variable!(ctx, model, block.import_var; lower=0.0)
    _register_shared_metal_equation!(ctx, block, :external_price;
        info="the EU-wide METAL price equals the fixed external METAL price",
        expr=EEq(EVar(block.price_var, Any[]), EParam(:external_price, Any[])))

    for quantity in block.primary_supply
        _require_shared_metal_quantity!(ctx, block.quantity_var, quantity,
            "Shared metal market")
    end
    for quantity in block.recycled_supply
        _require_shared_metal_quantity!(ctx, block.quantity_var, quantity,
            "Shared metal market")
    end
    for quantity in block.demand
        _require_shared_metal_quantity!(ctx, block.quantity_var, quantity,
            "Shared metal market")
    end

    supply = JCGECore.EquationExpr[
        EVar(block.import_var, Any[]),
        [EVar(block.quantity_var, Any[quantity]) for quantity in block.primary_supply]...,
        [EVar(block.quantity_var, Any[quantity]) for quantity in block.recycled_supply]...,
    ]
    demand = JCGECore.EquationExpr[
        [EVar(block.quantity_var, Any[quantity]) for quantity in block.demand]...,
        [EParam(:fixed_demand, Any[quantity]) for quantity in block.fixed_demand]...,
    ]
    isempty(demand) && error("Shared metal market requires at least one source of METAL demand.")
    _register_shared_metal_equation!(ctx, block, :market_clearing;
        info="external imports, domestic primary METAL, and recycled METAL equal EU physical METAL demand and extra-European exports",
        expr=EEq(EAdd(supply), EAdd(demand)))
    return nothing
end

function _circular_route_activity_lookup(bundle::CalibrationBundle)
    return Dict(
        (Symbol(row.region), Symbol(row.family), Symbol(row.route)) => Symbol(row.route_activity)
        for row in eachrow(bundle.route_registry)
    )
end

function _circular_coefficient_lookup(bundle::CalibrationBundle)
    return Dict(
        (Symbol(row.region), Symbol(row.family), Symbol(row.route_or_pool), Symbol(row.coefficient_kind)) =>
            Symbol(row.coefficient_id)
        for row in eachrow(bundle.physical_coefficients)
    )
end

function _observed_recycling_rows(bundle::CalibrationBundle)
    return [row for row in eachrow(bundle.physical_flows)
        if String(row.status) == "observed" && Symbol(row.route) === :REC &&
           Symbol(row.flow_kind) === :route_input_mass && Float64(row.value_tonnes) > 0.0]
end

function _route_metadata_by_activity(bundle::CalibrationBundle)
    metadata = Dict{Symbol,NamedTuple}()
    for row in eachrow(bundle.route_registry)
        route = Symbol(row.route)
        route in (:NEW, :REF, :REP, :REU) || continue
        activity = Symbol(row.route_activity)
        metadata[activity] = (family = Symbol(row.family), route = route)
    end
    return metadata
end

function _common_external_price(model::MultiRegionModelSpec,
    profile::CircularMetalProfile, coefficient_id)
    prices = Float64[]
    for region in model.outline.regions
        id = get(coefficient_id, (region, :ALL, :METAL, :external_price), nothing)
        id === nothing && error("Circular-metal profile has no external-price identifier for $(region).")
        push!(prices, profile.value[id])
    end
    unique_prices = unique(prices)
    length(unique_prices) == 1 || error(
        "The EU-wide METAL market requires the same external price in every region.")
    return only(unique_prices)
end

function _circular_metal_structure(model::MultiRegionModelSpec,
    profile::CircularMetalProfile)
    bundle = model.outline.bundle
    calibration = model.calibration
    route_activity = _circular_route_activity_lookup(bundle)
    coefficient_id = _circular_coefficient_lookup(bundle)
    external_price = _common_external_price(model, profile, coefficient_id)

    recovery_driver = Dict{Symbol,Symbol}()
    recovery_coefficient = Dict{Symbol,Float64}()
    recovery_initial = Dict{Symbol,Float64}()
    recycled_inputs = Dict{Symbol,Vector{Symbol}}()
    recycled_coefficient = Dict{Tuple{Symbol,Symbol},Float64}()
    recycled_initial = Dict{Symbol,Float64}()
    recycled_metadata = Dict{Symbol,NamedTuple}()
    for row in _observed_recycling_rows(bundle)
        region, family = Symbol(row.region), Symbol(row.family)
        activity = get(route_activity, (region, family, :REC), nothing)
        activity === nothing && error("Observed recycling flow $(region), $(family) has no recycling activity.")
        output = get(calibration.activity_output, activity, nothing)
        output === nothing &&
            error("Observed recycling flow $(region), $(family) has no recycling-activity output.")
        output > 0.0 ||
            error("Observed recycling flow $(region), $(family) has no positive recycling-activity output.")
        quantity = _circular_recovery_input_id(region, family)
        recovery_driver[quantity] = JCGEBlocks.global_var(:Z, activity)
        recovery_coefficient[quantity] = Float64(row.value_tonnes) / output
        recovery_initial[quantity] = Float64(row.value_tonnes)
    end
    for region in model.outline.regions
        inputs = sort!([quantity for quantity in keys(recovery_driver)
            if startswith(String(quantity), string("metal_recovery_input_", region, "_"))])
        isempty(inputs) && continue
        id = get(coefficient_id, (region, :ALL, :REC, :recovery_yield), nothing)
        id === nothing && error("Circular-metal profile has no recovery-yield identifier for $(region).")
        output = _circular_recycled_id(region)
        recycled_inputs[output] = inputs
        recycled_initial[output] = 0.0
        for input in inputs
            recycled_coefficient[(output, input)] = profile.value[id]
            recycled_initial[output] += profile.value[id] * recovery_initial[input]
        end
        recycled_metadata[output] = (region = region,)
    end

    primary_driver = Dict{Symbol,Symbol}()
    primary_coefficient = Dict{Symbol,Float64}()
    primary_initial = Dict{Symbol,Float64}()
    primary_metadata = Dict{Symbol,NamedTuple}()
    demand_driver = Dict{Symbol,Symbol}()
    demand_initial = Dict{Symbol,Float64}()
    demand_metadata = Dict{Symbol,NamedTuple}()
    inventory_demand = Dict{Symbol,Float64}()
    route_metadata = _route_metadata_by_activity(bundle)
    for region in model.outline.regions
        basic_metals = calibration.product_by_region[(region, :BASIC_METALS)]
        primary = _circular_primary_id(region)
        primary_driver[primary] = JCGEBlocks.global_var(:Z, basic_metals)
        primary_coefficient[primary] = 1.0 / external_price
        primary_initial[primary] = calibration.activity_output[basic_metals] / external_price
        primary_metadata[primary] = (region = region, activity = basic_metals)

        for activity in model.outline.industries_by_region[region]
            quantity = _circular_industry_demand_id(region, activity)
            monetary_use = calibration.intermediate_coefficient[(basic_metals, activity)] *
                calibration.activity_output[activity]
            demand_driver[quantity] = JCGEBlocks.global_var(:X, basic_metals, activity)
            demand_initial[quantity] = monetary_use / external_price
            route = get(route_metadata, activity, nothing)
            demand_metadata[quantity] = route === nothing ? (
                quantity_kind = :other_industry_metal_demand,
                region = region,
                family = missing,
                route = missing,
            ) : (
                quantity_kind = :ce_route_metal_demand,
                region = region,
                family = route.family,
                route = route.route,
            )
        end
        for (role, variable, monetary_use) in (
            (:households, :Xp, calibration.household_demand[basic_metals]),
            (:government, :Xg, calibration.government_demand[basic_metals]),
            (:investment, :Xv, calibration.fixed_investment_demand[basic_metals]),
        )
            quantity = _circular_final_demand_id(region, role)
            demand_driver[quantity] = JCGEBlocks.global_var(variable, basic_metals)
            demand_initial[quantity] = monetary_use / external_price
            demand_metadata[quantity] = (
                quantity_kind = :final_metal_demand,
                region = region,
                family = missing,
                route = role,
            )
        end
        inventory_demand[_circular_inventory_id(region)] =
            calibration.inventory_change[basic_metals] / external_price
    end
    for trade_route in calibration.trade_routes
        trade_route.product === :BASIC_METALS && trade_route.destination === :ROW || continue
        quantity = _circular_export_id(trade_route.id)
        demand_driver[quantity] = JCGEBlocks.global_var(:T, trade_route.id)
        demand_initial[quantity] = calibration.trade_value[trade_route.id] / external_price
        demand_metadata[quantity] = (
            quantity_kind = :external_metal_export,
            region = trade_route.origin,
            family = missing,
            route = :ROW,
        )
    end

    return (
        external_price = external_price,
        recovery_driver = recovery_driver,
        recovery_coefficient = recovery_coefficient,
        recovery_initial = recovery_initial,
        recycled_inputs = recycled_inputs,
        recycled_coefficient = recycled_coefficient,
        recycled_initial = recycled_initial,
        recycled_metadata = recycled_metadata,
        primary_driver = primary_driver,
        primary_coefficient = primary_coefficient,
        primary_initial = primary_initial,
        primary_metadata = primary_metadata,
        demand_driver = demand_driver,
        demand_initial = demand_initial,
        demand_metadata = demand_metadata,
        inventory_demand = inventory_demand,
    )
end

"""Create the physical METAL-market blocks supported by a sensitivity profile."""
function circular_metal_blocks(model::MultiRegionModelSpec,
    profile::CircularMetalProfile)
    structure = _circular_metal_structure(model, profile)
    blocks = Any[
        JCGEBlocks.quantity_link(
            :observed_recycling_throughput,
            sort!(collect(keys(structure.recovery_driver))),
            structure.recovery_driver;
            quantity_var = _CIRCULAR_METAL_VAR,
            lower = 0.0,
            params = (coefficient = structure.recovery_coefficient,),
        ),
    ]
    isempty(structure.recycled_inputs) || push!(blocks,
        JCGEBlocks.quantity_transformation(
            :recycled_metal_output,
            sort!(collect(keys(structure.recycled_inputs))),
            structure.recycled_inputs;
            output_var = _CIRCULAR_METAL_VAR,
            input_var = _CIRCULAR_METAL_VAR,
            lower = 0.0,
            params = (coefficient = structure.recycled_coefficient,),
        ))
    push!(blocks,
        JCGEBlocks.quantity_link(
            :primary_metal_output,
            sort!(collect(keys(structure.primary_driver))),
            structure.primary_driver;
            quantity_var = _CIRCULAR_METAL_VAR,
            lower = 0.0,
            params = (coefficient = structure.primary_coefficient,),
        ))
    push!(blocks,
        JCGEBlocks.quantity_link(
            :metal_demand_from_basic_metals_use,
            sort!(collect(keys(structure.demand_driver))),
            structure.demand_driver;
            quantity_var = _CIRCULAR_METAL_VAR,
            lower = 0.0,
            params = (
                coefficient = Dict(quantity => 1.0 / structure.external_price
                    for quantity in keys(structure.demand_driver)),
            ),
        ))
    push!(blocks,
        SharedMetalMarketBlock(
            :eu_wide_metal_market,
            sort!(collect(keys(structure.demand_initial))),
            sort!(collect(keys(structure.primary_initial))),
            sort!(collect(keys(structure.recycled_initial))),
            sort!(collect(keys(structure.inventory_demand))),
            _CIRCULAR_METAL_VAR,
            _CIRCULAR_METAL_PRICE_VAR,
            _CIRCULAR_METAL_IMPORT_VAR,
            (
                external_price = structure.external_price,
                fixed_demand = structure.inventory_demand,
                positive_lower = model.calibration.positive_lower,
            ),
        ))
    return blocks
end

"""Return calibrated starting values for the physical METAL market."""
function circular_metal_initial_values(model::MultiRegionModelSpec,
    profile::CircularMetalProfile)
    structure = _circular_metal_structure(model, profile)
    starts = Dict{Symbol,Float64}()
    for collection in (
        structure.recovery_initial,
        structure.recycled_initial,
        structure.primary_initial,
        structure.demand_initial,
    )
        for (id, value) in pairs(collection)
            starts[JCGEBlocks.global_var(_CIRCULAR_METAL_VAR, id)] = value
        end
    end
    total_demand = sum(values(structure.demand_initial)) +
        sum(values(structure.inventory_demand))
    total_supply_without_imports = sum(values(structure.primary_initial)) +
        sum(values(structure.recycled_initial))
    import_start = total_demand - total_supply_without_imports
    import_start >= 0.0 || error(
        "Circular-metal sensitivity profile implies negative external METAL imports at calibration. " *
        "Increase the common METAL price or reduce the recovery yield.")
    starts[_CIRCULAR_METAL_PRICE_VAR] = structure.external_price
    starts[_CIRCULAR_METAL_IMPORT_VAR] = import_start
    return starts
end

"""Describe observed physical-flow coverage for each CE route."""
function circular_metal_coverage(model::MultiRegionModelSpec)
    observed = model.outline.bundle.physical_flows
    rows = NamedTuple[]
    for route in (:NEW, :REF, :REP, :REU, :REC)
        kind = route === :NEW ? :new_product_output : :route_input_mass
        count_rows = count(row -> String(row.status) == "observed" &&
            Symbol(row.route) === route && Symbol(row.flow_kind) === kind,
            eachrow(observed))
        push!(rows, (
            route = route,
            required_flow_kind = kind,
            observed_rows = count_rows,
            expected_region_family_rows = length(model.outline.regions) * length(model.outline.families),
            complete = count_rows == length(model.outline.regions) * length(model.outline.families),
        ))
    end
    return DataFrame(rows)
end

"""Return the solved physical supply and demand components of the METAL market."""
function circular_metal_projection(result, model::MultiRegionModelSpec)
    profile = model.circular_metal
    profile === nothing && error("Circular-metal projection requires a model with a CircularMetalProfile.")
    hasproperty(result, :context) || error("Circular-metal projection requires a solved result with a KernelContext.")
    context = result.context
    JuMP.has_values(context.model) || error("Circular-metal projection requires a solved JuMP model.")
    structure = _circular_metal_structure(model, profile)
    rows = NamedTuple[]
    for (id, _) in pairs(structure.recycled_initial)
        metadata = structure.recycled_metadata[id]
        push!(rows, (
            quantity_kind = :recycled_metal_output,
            quantity_id = id,
            region = metadata.region,
            family = missing,
            route = :REC,
            tonnes = JuMP.value(context.variables[JCGEBlocks.global_var(_CIRCULAR_METAL_VAR, id)]),
        ))
    end
    for (id, _) in pairs(structure.primary_initial)
        metadata = structure.primary_metadata[id]
        push!(rows, (
            quantity_kind = :primary_metal_output,
            quantity_id = id,
            region = metadata.region,
            family = missing,
            route = missing,
            tonnes = JuMP.value(context.variables[JCGEBlocks.global_var(_CIRCULAR_METAL_VAR, id)]),
        ))
    end
    for (id, _) in pairs(structure.demand_initial)
        metadata = structure.demand_metadata[id]
        push!(rows, (
            quantity_kind = metadata.quantity_kind,
            quantity_id = id,
            region = metadata.region,
            family = metadata.family,
            route = metadata.route,
            tonnes = JuMP.value(context.variables[JCGEBlocks.global_var(_CIRCULAR_METAL_VAR, id)]),
        ))
    end
    for (id, value) in pairs(structure.inventory_demand)
        region = Symbol(split(String(id), '_')[end])
        push!(rows, (
            quantity_kind = :metal_inventory_change,
            quantity_id = id,
            region = region,
            family = missing,
            route = missing,
            tonnes = value,
        ))
    end
    push!(rows, (
        quantity_kind = :external_metal_import,
        quantity_id = _CIRCULAR_METAL_IMPORT_VAR,
        region = :EU,
        family = missing,
        route = missing,
        tonnes = JuMP.value(context.variables[_CIRCULAR_METAL_IMPORT_VAR]),
    ))
    return DataFrame(rows)
end

"""Compare solved variable physical quantities with their calibration starts."""
function circular_metal_calibration_report(result, model::MultiRegionModelSpec)
    profile = model.circular_metal
    profile === nothing && error("Circular-metal calibration reporting requires a model with a CircularMetalProfile.")
    hasproperty(result, :context) || error("Circular-metal calibration reporting requires a solved result with a KernelContext.")
    context = result.context
    JuMP.has_values(context.model) || error("Circular-metal projection requires a solved JuMP model.")
    structure = _circular_metal_structure(model, profile)
    expected = Dict{Symbol,Float64}()
    for collection in (
        structure.recovery_initial,
        structure.recycled_initial,
        structure.primary_initial,
        structure.demand_initial,
    )
        merge!(expected, collection)
    end
    expected[_CIRCULAR_METAL_IMPORT_VAR] =
        sum(values(structure.demand_initial)) + sum(values(structure.inventory_demand)) -
        sum(values(structure.primary_initial)) - sum(values(structure.recycled_initial))
    rows = NamedTuple[]
    for id in sort!(collect(keys(expected)))
        variable = id === _CIRCULAR_METAL_IMPORT_VAR ?
            context.variables[_CIRCULAR_METAL_IMPORT_VAR] :
            context.variables[JCGEBlocks.global_var(_CIRCULAR_METAL_VAR, id)]
        calibrated = expected[id]
        solved = JuMP.value(variable)
        absolute_error = solved - calibrated
        push!(rows, (
            quantity_id = id,
            calibrated_tonnes = calibrated,
            solved_tonnes = solved,
            absolute_error_tonnes = absolute_error,
            relative_error = calibrated == 0.0 ? missing : absolute_error / calibrated,
        ))
    end
    return DataFrame(rows)
end
