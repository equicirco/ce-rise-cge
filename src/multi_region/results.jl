function summary_row(model::MultiRegionModelSpec = multi_region_model())
    summary = calibration_summary(model.outline.bundle)
    return (
        label = model.label,
        scenario = model.scenario.name,
        regions = summary.regions,
        industries = summary.industries,
        families = summary.families,
        routes = summary.routes,
        coefficient_rows = summary.coefficient_rows,
        quantity_bridge_rows = summary.quantity_bridge_rows,
        observed_physical_flow_rows = summary.observed_physical_flow_rows,
    )
end

const _METAL_DOMESTIC_DEMAND_KINDS = Set((
    :other_industry_metal_demand,
    :ce_route_metal_demand,
    :final_metal_demand,
    :metal_inventory_change,
))

const _METAL_MARKET_DEMAND_KINDS = union(
    _METAL_DOMESTIC_DEMAND_KINDS,
    Set((:external_metal_export,)),
)

function _metal_projection_total(projection::DataFrame, material::Symbol,
    quantity_kinds)
    return sum(
        Float64(row.tonnes) for row in eachrow(projection)
        if row.material === material && row.quantity_kind in quantity_kinds
    )
end

"""Return physical METAL measures used consistently across policy scenarios."""
function _metal_policy_measures(result, model::MultiRegionModelSpec)
    projection = circular_metal_projection(result, model)
    output = material -> sum(
        Float64(row.tonnes) for row in eachrow(projection)
        if row.material === material &&
           row.quantity_kind === Symbol(material, :_metal_output)
    )
    external_import = sum(
        Float64(row.tonnes) for row in eachrow(projection)
        if row.quantity_kind === :external_metal_import
    )
    return (
        primary_metal_market_demand_tonnes = _metal_projection_total(
            projection, :primary, _METAL_MARKET_DEMAND_KINDS),
        primary_metal_domestic_demand_tonnes = _metal_projection_total(
            projection, :primary, _METAL_DOMESTIC_DEMAND_KINDS),
        primary_metal_ce_rise_demand_tonnes = _metal_projection_total(
            projection, :primary, Set((:ce_route_metal_demand,))),
        recycled_metal_market_demand_tonnes = _metal_projection_total(
            projection, :recycled, _METAL_MARKET_DEMAND_KINDS),
        recycled_metal_domestic_demand_tonnes = _metal_projection_total(
            projection, :recycled, _METAL_DOMESTIC_DEMAND_KINDS),
        recycled_metal_ce_rise_demand_tonnes = _metal_projection_total(
            projection, :recycled, Set((:ce_route_metal_demand,))),
        primary_metal_output_tonnes = output(:primary),
        recycled_metal_output_tonnes = output(:recycled),
        external_metal_import_tonnes = external_import,
    )
end

"""Return regional-policy fiscal totals in the model's million-euro unit."""
function policy_fiscal_totals(result, model::MultiRegionModelSpec)
    model.scenario.name !== :baseline ||
        error("Policy fiscal totals require a non-baseline policy scenario.")
    total = variable -> sum(
        JuMP.value(result.context.variables[JCGEBlocks.global_var(variable, region)])
        for region in model.outline.regions
    )
    return (
        tax_revenue_million_eur = total(_CIRCULAR_POLICY_REVENUE_VAR),
        support_expenditure_million_eur = total(_CIRCULAR_POLICY_SUPPORT_VAR),
        household_transfer_million_eur = total(_CIRCULAR_POLICY_TRANSFER_VAR),
    )
end

"""
    policy_sweep_summary(baseline_result, baseline_model, policy_runs)

Return comparable physical and fiscal measures for explicitly supplied,
single-instrument policy runs. The reported fiscal basis is tax revenue
for a tax and support expenditure for a support; it is therefore transparent
about the different fiscal direction of the two instrument types.
"""
function policy_sweep_summary(baseline_result,
    baseline_model::MultiRegionModelSpec,
    policy_runs::AbstractVector)
    baseline_model.scenario.name === :baseline ||
        error("A policy sweep summary requires a zero-policy baseline model.")
    isempty(policy_runs) && error("A policy sweep summary requires at least one policy run.")
    models = MultiRegionModelSpec[run.model for run in policy_runs]
    instrument = _validate_policy_path(models)
    baseline = _metal_policy_measures(baseline_result, baseline_model)
    fiscal_basis_kind = instrument === :virgin_metal_tax ?
        :tax_revenue : :support_expenditure
    rows = NamedTuple[]
    for run in policy_runs
        model = run.model
        result = run.result
        measures = _metal_policy_measures(result, model)
        fiscal = policy_fiscal_totals(result, model)
        fiscal_basis = instrument === :virgin_metal_tax ?
            fiscal.tax_revenue_million_eur : fiscal.support_expenditure_million_eur
        fiscal_basis > 0.0 || error(
            "Policy sweep fiscal basis must be positive for $(model.scenario.name).")
        primary_reduction = baseline.primary_metal_market_demand_tonnes -
            measures.primary_metal_market_demand_tonnes
        push!(rows, merge(
            (
                scenario = model.scenario.name,
                instrument = instrument,
                wedge = policy_wedge(model.scenario, instrument),
                termination_status = JuMP.termination_status(result.context.model),
                max_scaled_residual = result.scaled_summary.max_scaled_abs,
                scaled_residuals_above_tolerance = result.scaled_summary.above_tol,
                max_bound_violation = result.bound_summary.max_abs,
                bound_violations_above_tolerance = result.bound_summary.above_tol,
                fiscal_basis_kind = fiscal_basis_kind,
                fiscal_basis_million_eur = fiscal_basis,
                primary_metal_market_demand_reduction_tonnes = primary_reduction,
                primary_metal_market_demand_reduction_per_million_eur =
                    primary_reduction / fiscal_basis,
            ),
            measures,
            fiscal,
        ))
    end
    return DataFrame(rows)
end
