"""
Physical-accounting interface for the CE-RISE model.

Observed physical flows are represented by generic, normalized volume-index
variables. `JCGEOutput` converts those indices to physical quantities through
observed anchors and remains responsible for baseline-referenced projection
and post-solution diagnostics.  When a `CircularMetalProfile` is supplied,
additional tonne-level quantities transform observed route masses into metal
use and recycled-metal output.
"""

struct PhysicalSatelliteSpec
    quantity_bridge::DataFrame
    coefficients::DataFrame
    route_registry::DataFrame
    observed_flows::DataFrame
end

struct PhysicalSatelliteReadiness
    quantity_rows::Int
    coefficient_rows::Int
    quantity_value_column::Bool
    coefficient_value_column::Bool
    template_quantity_rows::Int
    template_coefficient_rows::Int
    model_anchor_rows::Int
    unbound_anchor_rows::Int
    observed_flow_rows::Int
    observed_new_output_rows::Int
    observed_anchor_ready::Bool
    ready::Bool
end

const _PHYSICAL_FLOW_VARIABLE = :physical_flow

"""Return the model-side physical-accounting specification without altering it."""
function physical_satellite_spec(model::MultiRegionModelSpec = multi_region_model())
    return PhysicalSatelliteSpec(
        copy(model.quantity_template),
        copy(model.coefficient_template),
        copy(model.outline.bundle.route_registry),
        copy(model.outline.bundle.physical_flows),
    )
end

"""Return directly observed, mass-based physical anchors from the BONSAI input."""
function observed_physical_flows(model::MultiRegionModelSpec = multi_region_model())
    return copy(model.outline.bundle.physical_flows)
end

_physical_flow_id(row) = Symbol(
    :physical_, Symbol(row.region), :_, Symbol(row.family), :_, Symbol(row.route),
    :_, Symbol(row.flow_kind),
)

function _route_activity_by_flow(bundle::CalibrationBundle)
    return Dict(
        (Symbol(row.region), Symbol(row.family), Symbol(row.route)) => Symbol(row.route_activity)
        for row in eachrow(bundle.route_registry)
    )
end

"""Return structural mappings and calibrated volume-index coefficients for observed flows."""
function _physical_flow_link_data(bundle::CalibrationBundle,
    calibration::MultiRegionCalibration)
    route_accounts = _route_activity_by_flow(bundle)
    quantities = Symbol[]
    driver_by_quantity = Dict{Symbol,Symbol}()
    coefficient = Dict{Symbol,Float64}()
    base_quantity = Dict{Symbol,Float64}()
    activity_by_quantity = Dict{Symbol,Symbol}()

    for row in eachrow(bundle.physical_flows)
        id = _physical_flow_id(row)
        id in quantities && error("Observed physical-flow identifier $(id) is duplicated.")
        key = (Symbol(row.region), Symbol(row.family), Symbol(row.route))
        activity = get(route_accounts, key, nothing)
        activity === nothing && error("No route activity is registered for observed physical flow $(key).")
        activity_output = get(calibration.activity_output, activity, nothing)
        activity_output === nothing && error("No calibrated activity output is available for $(activity).")
        activity_output > 0.0 || error("Calibrated activity output for $(activity) must be strictly positive.")
        quantity = Float64(row.value_tonnes)
        quantity > 0.0 || error("Observed physical flow $(id) must be strictly positive.")
        push!(quantities, id)
        driver_by_quantity[id] = JCGEBlocks.global_var(:Z, activity)
        coefficient[id] = 1.0 / activity_output
        base_quantity[id] = quantity
        activity_by_quantity[id] = activity
    end

    return (
        quantities = quantities,
        driver_by_quantity = driver_by_quantity,
        coefficient = coefficient,
        base_quantity = base_quantity,
        activity_by_quantity = activity_by_quantity,
    )
end

"""
    observed_physical_quantity_links(bundle, calibration)

Create generic JCGE links for the normalized volume index of each observed
physical flow. Each coefficient is derived from calibrated monetary activity
output; the observed physical quantity remains the `JCGEOutput` anchor. No
numerical coefficient is hard-coded here.
"""
function observed_physical_quantity_links(bundle::CalibrationBundle,
    calibration::MultiRegionCalibration)
    links = _physical_flow_link_data(bundle, calibration)
    return JCGEBlocks.quantity_link(
        :observed_physical_flow_links,
        links.quantities,
        links.driver_by_quantity;
        quantity_var = _PHYSICAL_FLOW_VARIABLE,
        lower = 0.0,
        params = (coefficient = links.coefficient,),
    )
end

"""Return the `JCGEOutput` anchors for directly observed physical flows."""
function physical_flow_anchors(model::MultiRegionModelSpec = multi_region_model())
    links = _physical_flow_link_data(model.outline.bundle, model.calibration)
    anchors = SatelliteAnchor[]
    for row in eachrow(model.outline.bundle.physical_flows)
        id = _physical_flow_id(row)
        quantity = links.base_quantity[id]
        push!(anchors, SatelliteAnchor(
            id,
            String(row.physical_unit),
            quantity,
            JCGEBlocks.global_var(_PHYSICAL_FLOW_VARIABLE, id),
            1.0,
        ))
    end
    return anchors
end

"""
    physical_flow_reference(result, model)

Capture the solved generic physical-flow variables through `JCGEOutput`. The
reference must be constructed from the zero-policy model and supplied to all
later scenario projections. This keeps the observed base-year tonne anchor
separate from small rounding differences in the calibrated monetary system.
"""
function physical_flow_reference(result,
    model::MultiRegionModelSpec = multi_region_model())
    model.scenario.name === :baseline ||
        error("A physical-flow reference must be constructed from the zero-policy baseline.")
    return satellite_reference(result, physical_flow_anchors(model); id = :baseline)
end

"""
    physical_calibration_driver_report(result, model)

Report the difference between each calibrated physical driver and its solved
baseline reference. This is diagnostic only and does not modify projections.
"""
function physical_calibration_driver_report(result,
    model::MultiRegionModelSpec = multi_region_model())
    reference = physical_flow_reference(result, model)
    return DataFrame(satellite_calibration_report(reference, physical_flow_anchors(model)))
end

"""
    physical_flow_projection(result, model; reference)

Project each observed flow through `JCGEOutput` relative to a solved
zero-policy reference. The returned table retains CE-RISE route metadata while
the driver, index, and projected quantity come directly from the standard
satellite API.
"""
function physical_flow_projection(result,
    model::MultiRegionModelSpec = multi_region_model();
    reference::SatelliteReference = physical_flow_reference(result, model))
    reference.id === :baseline || error("Physical-flow projections require a zero-policy baseline reference.")
    links = _physical_flow_link_data(model.outline.bundle, model.calibration)
    projection = satellite_projection(result, physical_flow_anchors(model); reference = reference)
    projected_by_id = Dict(Symbol(row.id) => row for row in projection)
    rows = NamedTuple[]
    for row in eachrow(model.outline.bundle.physical_flows)
        id = _physical_flow_id(row)
        item = get(projected_by_id, id, nothing)
        item === nothing && error("Satellite projection is missing observed physical flow $(id).")
        activity = links.activity_by_quantity[id]
        push!(rows, (
            region = Symbol(row.region),
            family = Symbol(row.family),
            route = Symbol(row.route),
            flow_kind = Symbol(row.flow_kind),
            physical_anchor = id,
            physical_unit = String(row.physical_unit),
            benchmark_tonnes = item.base_quantity,
            route_activity = activity,
            model_volume_driver = links.driver_by_quantity[id],
            physical_driver = item.driver,
            calibration_volume_index = item.calibration_driver,
            reference_volume_index = item.reference_driver,
            solved_volume_index = item.solved_driver,
            model_quantity_index = item.volume_index,
            projected_tonnes = item.projected_quantity,
            status = item.status,
        ))
    end
    return DataFrame(rows)
end

_template_rows(table::DataFrame) =
    :status in names(table) ? count(row -> lowercase(strip(String(row.status))) == "template", eachrow(table)) : nrow(table)

"""
    physical_satellite_readiness(model)

Report whether the calibration bundle contains the numerical physical anchors
and coefficients required to calculate physical levels.  `model_anchor_rows`
counts bridge rows whose linked account is already an activity in the current
monetary model; the other rows require the forthcoming circular-economy
extension accounts.
"""
function physical_satellite_readiness(model::MultiRegionModelSpec = multi_region_model())
    spec = physical_satellite_spec(model)
    activities = Set(model.outline.industries)
    model_anchor_rows = count(
        row -> Symbol(row.linked_account) in activities,
        eachrow(spec.quantity_bridge),
    )
    quantity_value_column = :benchmark_physical_quantity in names(spec.quantity_bridge)
    coefficient_value_column = :value in names(spec.coefficients)
    template_quantity_rows = _template_rows(spec.quantity_bridge)
    template_coefficient_rows = _template_rows(spec.coefficients)
    observed_flow_rows = nrow(spec.observed_flows)
    observed_new_output_rows = count(
        row -> String(row.route) == "NEW" && String(row.flow_kind) == "new_product_output" &&
               String(row.physical_unit) == "tonnes" && String(row.status) == "observed" &&
               Float64(row.value_tonnes) > 0.0,
        eachrow(spec.observed_flows),
    )
    expected_new_output_rows = length(model.outline.regions) * length(model.outline.families)
    observed_anchor_ready = observed_new_output_rows == expected_new_output_rows
    ready = quantity_value_column && coefficient_value_column &&
            iszero(template_quantity_rows) && iszero(template_coefficient_rows) &&
            model_anchor_rows == nrow(spec.quantity_bridge)
    return PhysicalSatelliteReadiness(
        nrow(spec.quantity_bridge),
        nrow(spec.coefficients),
        quantity_value_column,
        coefficient_value_column,
        template_quantity_rows,
        template_coefficient_rows,
        model_anchor_rows,
        nrow(spec.quantity_bridge) - model_anchor_rows,
        observed_flow_rows,
        observed_new_output_rows,
        observed_anchor_ready,
        ready,
    )
end

"""
    physical_quantity_indices(result, model)

Return the volume index for every bridge row that can be linked to an existing
activity-output variable.  The index is dimensionless: it becomes a physical
quantity only after the corresponding base-year physical anchor has been
provided, according to `Q_t = Q_0 q_t`.  Rows for service, end-of-life, and
material-pool accounts remain explicitly unbound until their CE blocks are
assembled.
"""
function physical_quantity_indices(result,
    model::MultiRegionModelSpec = multi_region_model())
    hasproperty(result, :context) || error("Physical reporting requires a solved result with a KernelContext.")
    context = result.context
    JuMP.has_values(context.model) || error("Physical reporting requires a solved JuMP model.")

    rows = NamedTuple[]
    for row in eachrow(model.quantity_template)
        account = Symbol(row.linked_account)
        variable_name = JCGEBlocks.global_var(:Z, account)
        variable = get(context.variables, variable_name, nothing)
        calibrated = get(model.calibration.activity_output, account, nothing)
        available = variable !== nothing && calibrated !== nothing && calibrated > 0.0
        level = available ? JuMP.value(variable) : missing
        index = available ? level / calibrated : missing
        push!(rows, (
            region = Symbol(row.region),
            bridge_id = Symbol(row.bridge_id),
            family = Symbol(row.family),
            quantity_kind = Symbol(row.quantity_kind),
            linked_account = account,
            physical_unit = String(row.physical_unit),
            quantity_driver = available ? :activity_output : :unbound,
            calibrated_model_level = available ? calibrated : missing,
            solved_model_level = level,
            model_quantity_index = index,
            status = available ? :index_available : :requires_ce_account,
        ))
    end
    return DataFrame(rows)
end

"""
    physical_mass_balance_requirements(model)

List the flow identities that must be populated before physical mass balances
can be evaluated.  The registry determines the routes; no balance coefficients
or physical values are constructed here.
"""
function physical_mass_balance_requirements(model::MultiRegionModelSpec = multi_region_model())
    registry = model.outline.bundle.route_registry
    rows = NamedTuple[]
    grouped = groupby(registry, [:region, :family])
    for group in grouped
        region = Symbol(group.region[1])
        family = Symbol(group.family[1])
        life_extension = sort([
            String(row.route) for row in eachrow(group)
            if occursin("eol_input", String(row.material_link))
        ])
        recovery = sort([
            String(row.route) for row in eachrow(group)
            if String(row.route_scope) == "eol_recovery"
        ])
        disposal = sort([
            String(row.route) for row in eachrow(group)
            if String(row.route_scope) == "eol_disposal"
        ])
        allocation_routes = vcat(life_extension, recovery, disposal)
        push!(rows, (
            region = region,
            family = family,
            balance = :end_of_life_allocation,
            required_flows = join(vcat(["end_of_life_available"], ["eol_to_" * route for route in allocation_routes]), ";"),
            required_coefficients = "none",
        ))
        for route in life_extension
            push!(rows, (
                region = region,
                family = family,
                balance = :life_extension_yield,
                required_flows = join(["eol_to_" * route, "output_" * route], ";"),
                required_coefficients = "yield:" * route,
            ))
        end
    end

    for region in model.outline.regions
        families = sort(unique(String.(filter(row -> Symbol(row.region) == region, registry).family)))
        push!(rows, (
            region = region,
            family = :ALL,
            balance = :recycling_metal_yield,
            required_flows = join(vcat(["metal_output_from_recycling"], ["eol_to_REC_" * family for family in families]), ";"),
            required_coefficients = "recovery_yield:REC",
        ))
    end
    return DataFrame(rows)
end

"""Collect the current physical-accounting readiness, indices, and balance requirements."""
function physical_baseline_report(result,
    model::MultiRegionModelSpec = multi_region_model())
    reference = physical_flow_reference(result, model)
    return (
        readiness = physical_satellite_readiness(model),
        observed_flows = observed_physical_flows(model),
        quantity_indices = physical_quantity_indices(result, model),
        flow_reference = reference,
        calibration_driver_report = physical_calibration_driver_report(result, model),
        flow_projection = physical_flow_projection(result, model; reference = reference),
        mass_balance_requirements = physical_mass_balance_requirements(model),
        circular_metal = model.circular_metal === nothing ? nothing : (
            coverage = circular_metal_coverage(model),
            projection = circular_metal_projection(result, model),
            calibration_report = circular_metal_calibration_report(result, model),
        ),
    )
end
