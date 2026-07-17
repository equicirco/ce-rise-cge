"""
Physical-accounting interface for the CE-RISE model.

The monetary CGE model and the physical satellite remain separate.  This file
does not introduce physical constraints into the equilibrium problem.  It
instead records the supplied physical-accounting structure, exposes the volume
indices that can already be recovered from a solved model, and states the
anchors and flows still required before physical levels and mass balances can
be validated.
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

"""
Reference activity levels for a physical satellite.

Physical observations are anchored to the solved zero-policy equilibrium, not
to an independently rounded monetary input.  This preserves the supplied mass
observation at the base equilibrium and gives scenario indices a common,
reproducible denominator.
"""
struct PhysicalFlowReference
    scenario::Symbol
    activity_level::Dict{Symbol,Float64}
end

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

"""
    physical_flow_reference(result, model)

Record the solved activity level behind each directly observed physical flow.
The reference must be constructed from the zero-policy model and supplied to
all later scenario projections.
"""
function physical_flow_reference(result,
    model::MultiRegionModelSpec = multi_region_model())
    model.scenario.name === :baseline ||
        error("A physical-flow reference must be constructed from the zero-policy baseline.")
    hasproperty(result, :context) || error("Physical reporting requires a solved result with a KernelContext.")
    context = result.context
    JuMP.has_values(context.model) || error("Physical reporting requires a solved JuMP model.")

    route_accounts = Dict(
        (Symbol(row.region), Symbol(row.family), Symbol(row.route)) => Symbol(row.route_activity)
        for row in eachrow(model.outline.bundle.route_registry)
    )
    levels = Dict{Symbol,Float64}()
    for row in eachrow(model.outline.bundle.physical_flows)
        key = (Symbol(row.region), Symbol(row.family), Symbol(row.route))
        activity = get(route_accounts, key, nothing)
        activity === nothing && error("No route activity is registered for observed physical flow $(key).")
        variable = get(context.variables, JCGEBlocks.global_var(:Z, activity), nothing)
        variable isa JuMP.VariableRef || error("Observed physical flow $(key) is not linked to an activity-output variable.")
        level = JuMP.value(variable)
        isfinite(level) && level > 0.0 || error("Baseline activity $(activity) must be finite and strictly positive.")
        levels[activity] = level
    end
    return PhysicalFlowReference(:baseline, levels)
end

"""
    physical_calibration_driver_report(result, model)

Report the difference between a solved zero-policy activity level and its
monetary calibration input for every observed physical anchor.  This is kept
separate from the physical projection so numerical replication diagnostics are
visible rather than folded into the mass accounting.
"""
function physical_calibration_driver_report(result,
    model::MultiRegionModelSpec = multi_region_model())
    reference = physical_flow_reference(result, model)
    rows = NamedTuple[]
    for (activity, solved) in sort!(collect(reference.activity_level); by=first)
        calibrated = get(model.calibration.activity_output, activity, nothing)
        calibrated === nothing && error("No calibrated output is available for $(activity).")
        push!(rows, (
            route_activity = activity,
            calibrated_model_level = calibrated,
            solved_baseline_level = solved,
            absolute_difference = solved - calibrated,
            relative_difference = (solved - calibrated) / calibrated,
        ))
    end
    return DataFrame(rows)
end

"""
    physical_flow_projection(result, model; reference)

Scale each directly observed physical anchor by the solved volume index of its
linked route activity, relative to the solved zero-policy reference.  This
retains the supplied mass basis and makes no claim about route yields or
unobserved product stocks.
"""
function physical_flow_projection(result,
    model::MultiRegionModelSpec = multi_region_model();
    reference::PhysicalFlowReference = physical_flow_reference(result, model))
    hasproperty(result, :context) || error("Physical reporting requires a solved result with a KernelContext.")
    context = result.context
    JuMP.has_values(context.model) || error("Physical reporting requires a solved JuMP model.")
    reference.scenario === :baseline ||
        error("Physical-flow projections require a zero-policy baseline reference.")

    route_accounts = Dict(
        (Symbol(row.region), Symbol(row.family), Symbol(row.route)) => Symbol(row.route_activity)
        for row in eachrow(model.outline.bundle.route_registry)
    )
    rows = NamedTuple[]
    for row in eachrow(model.outline.bundle.physical_flows)
        key = (Symbol(row.region), Symbol(row.family), Symbol(row.route))
        activity = get(route_accounts, key, nothing)
        variable = activity === nothing ? nothing : get(context.variables, JCGEBlocks.global_var(:Z, activity), nothing)
        baseline_level = activity === nothing ? nothing : get(reference.activity_level, activity, nothing)
        available = variable !== nothing && baseline_level !== nothing && baseline_level > 0.0
        solved_level = available ? JuMP.value(variable) : missing
        index = available ? solved_level / baseline_level : missing
        base_mass = Float64(row.value_tonnes)
        push!(rows, (
            region = Symbol(row.region),
            family = Symbol(row.family),
            route = Symbol(row.route),
            flow_kind = Symbol(row.flow_kind),
            physical_unit = String(row.physical_unit),
            benchmark_tonnes = base_mass,
            route_activity = activity,
            baseline_model_level = baseline_level,
            solved_model_level = solved_level,
            model_quantity_index = index,
            projected_tonnes = available ? base_mass * index : missing,
            status = available ? :projected : :unbound,
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
            balance = :recovery_yield,
            required_flows = join(vcat(["recycled_metal_output"], ["eol_to_REC_" * family for family in families]), ";"),
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
    )
end
