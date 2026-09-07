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

const _OUTCOME_KEY_FIELDS = (
    :domain,
    :indicator,
    :region,
    :account,
    :factor,
    :family,
    :route,
    :material,
    :unit,
)

function _outcome_row(domain::Symbol, indicator::Symbol;
    region=missing,
    account=missing,
    factor=missing,
    family=missing,
    route=missing,
    material=missing,
    unit::Symbol,
    level::Real,
)
    return (
        domain = domain,
        indicator = indicator,
        region = region === missing ? missing : Symbol(region),
        account = account === missing ? missing : Symbol(account),
        factor = factor === missing ? missing : Symbol(factor),
        family = family === missing ? missing : Symbol(family),
        route = route === missing ? missing : Symbol(route),
        material = material === missing ? missing : Symbol(material),
        unit = unit,
        level = Float64(level),
    )
end

function _outcome_variable_value(result, name::Symbol; default=nothing)
    variable = get(result.context.variables, name, nothing)
    variable === nothing && return default
    return JuMP.value(variable)
end

function _outcome_key(row)
    return Tuple(getproperty(row, field) for field in _OUTCOME_KEY_FIELDS)
end

function _require_unique_outcome_keys(table::DataFrame, label::AbstractString)
    keys = [_outcome_key(row) for row in eachrow(table)]
    length(unique(keys)) == length(keys) ||
        error("$(label) outcome table contains duplicate outcome identifiers.")
    return keys
end

"""
    equilibrium_outcomes(result, model; physical_reference=nothing)

Return the solved economic and physical indicators required for policy
analysis. Monetary levels are reported in the calibration's million-euro
unit, while route and METAL flows retain tonne units. Quantity indices are
normalised to their own calibrated levels and are therefore suitable for
percentage-change reporting without assigning a spurious physical unit to
monetary-model activity quantities.
"""
function equilibrium_outcomes(result,
    model::MultiRegionModelSpec = multi_region_model();
    physical_reference::Union{Nothing,SatelliteReference}=nothing)
    hasproperty(result, :context) ||
        error("Outcome reporting requires a solved result with a KernelContext.")
    JuMP.has_values(result.context.model) ||
        error("Outcome reporting requires a solved JuMP model.")

    calibration = model.calibration
    outline = model.outline
    rows = NamedTuple[]

    for region in outline.regions
        activities = outline.industries_by_region[region]
        factors = outline.factors_by_region[region]
        factor_income = 0.0
        household_consumption = 0.0
        government_consumption = 0.0
        fixed_investment = 0.0

        for activity in activities
            output = _outcome_variable_value(result, JCGEBlocks.global_var(:Z, activity))
            value_added = _outcome_variable_value(result, JCGEBlocks.global_var(:Y, activity))
            output_price = _outcome_variable_value(result, JCGEBlocks.global_var(:pz, activity))
            value_added_price = _outcome_variable_value(result, JCGEBlocks.global_var(:py, activity))
            calibrated_output = calibration.activity_output[activity]
            calibrated_output > 0.0 || error("Activity $(activity) has no positive calibrated output.")
            push!(rows, _outcome_row(:economic, :activity_output_volume_index;
                region=region, account=activity, unit=:index,
                level=output / calibrated_output))
            push!(rows, _outcome_row(:economic, :activity_gross_output_million_eur;
                region=region, account=activity, unit=:million_eur,
                level=output_price * output))
            push!(rows, _outcome_row(:economic, :activity_value_added_million_eur;
                region=region, account=activity, unit=:million_eur,
                level=value_added_price * value_added))

            for factor in factors
                input = _outcome_variable_value(result, JCGEBlocks.global_var(:F, factor, activity))
                price = _outcome_variable_value(result, JCGEBlocks.global_var(:pf, factor))
                calibrated_input = calibration.factor_payment[(factor, activity)]
                calibrated_input > 0.0 ||
                    error("Factor $(factor) in $(activity) has no positive calibrated input.")
                factor_income += price * input
                push!(rows, _outcome_row(:economic, :factor_input_volume_index;
                    region=region, account=activity, factor=factor, unit=:index,
                    level=input / calibrated_input))
                push!(rows, _outcome_row(:economic, :factor_income_million_eur;
                    region=region, account=activity, factor=factor, unit=:million_eur,
                    level=price * input))
            end
        end

        for factor in factors
            input = sum(_outcome_variable_value(result,
                JCGEBlocks.global_var(:F, factor, activity)) for activity in activities)
            endowment = calibration.factor_endowment[factor]
            endowment > 0.0 || error("Factor $(factor) has no positive calibrated endowment.")
            push!(rows, _outcome_row(:economic, :regional_factor_utilisation;
                region=region, factor=factor, unit=:ratio, level=input / endowment))
        end

        for good in activities
            price = _outcome_variable_value(result, JCGEBlocks.global_var(:pq, good))
            household_consumption += price * _outcome_variable_value(result,
                JCGEBlocks.global_var(:Xp, good))
            government_consumption += price * _outcome_variable_value(result,
                JCGEBlocks.global_var(:Xg, good))
            fixed_investment += price * _outcome_variable_value(result,
                JCGEBlocks.global_var(:Xv, good))
        end
        direct_tax = _outcome_variable_value(result, JCGEBlocks.global_var(:Td, region))
        private_saving = _outcome_variable_value(result, JCGEBlocks.global_var(:Sp, region))
        policy_transfer = _outcome_variable_value(result,
            JCGEBlocks.global_var(_CIRCULAR_POLICY_TRANSFER_VAR, region); default=0.0)
        push!(rows, _outcome_row(:economic, :household_disposable_income_million_eur;
            region=region, unit=:million_eur,
            level=factor_income - direct_tax + policy_transfer))
        push!(rows, _outcome_row(:economic, :household_consumption_million_eur;
            region=region, unit=:million_eur, level=household_consumption))
        push!(rows, _outcome_row(:economic, :household_saving_million_eur;
            region=region, unit=:million_eur, level=private_saving))
        push!(rows, _outcome_row(:economic, :household_utility_index;
            region=region, unit=:index,
            level=_outcome_variable_value(result, JCGEBlocks.global_var(:UU, region))))
        push!(rows, _outcome_row(:economic, :household_price_index;
            region=region, unit=:index,
            level=_outcome_variable_value(result, JCGEBlocks.global_var(:P_HH, region))))
        push!(rows, _outcome_row(:economic, :government_consumption_million_eur;
            region=region, unit=:million_eur, level=government_consumption))
        push!(rows, _outcome_row(:economic, :fixed_investment_million_eur;
            region=region, unit=:million_eur, level=fixed_investment))
        push!(rows, _outcome_row(:fiscal, :policy_revenue_million_eur;
            region=region, unit=:million_eur,
            level=_outcome_variable_value(result,
                JCGEBlocks.global_var(_CIRCULAR_POLICY_REVENUE_VAR, region); default=0.0)))
        push!(rows, _outcome_row(:fiscal, :policy_support_million_eur;
            region=region, unit=:million_eur,
            level=_outcome_variable_value(result,
                JCGEBlocks.global_var(_CIRCULAR_POLICY_SUPPORT_VAR, region); default=0.0)))
        push!(rows, _outcome_row(:fiscal, :policy_transfer_million_eur;
            region=region, unit=:million_eur, level=policy_transfer))
    end

    for service in model.circular_routes.services
        region = model.circular_routes.service_region[service]
        family = model.circular_routes.service_family[service]
        reference_quantity = sum(calibration.household_demand[good]
            for good in values(model.circular_routes.route_goods_by_service[service]))
        reference_quantity > 0.0 || error("Circular service $(service) has no positive reference quantity.")
        push!(rows, _outcome_row(:economic, :circular_service_volume_index;
            region=region, account=service, family=family, unit=:index,
            level=_outcome_variable_value(result,
                JCGEBlocks.global_var(_CIRCULAR_SERVICE_QUANTITY_VAR, service)) / reference_quantity))
        for (route, good) in model.circular_routes.route_goods_by_service[service]
            reference_demand = calibration.household_demand[good]
            reference_demand > 0.0 || error("Circular route $(good) has no positive reference demand.")
            push!(rows, _outcome_row(:economic, :circular_route_household_demand_volume_index;
                region=region, account=good, family=family, route=route, unit=:index,
                level=_outcome_variable_value(result, JCGEBlocks.global_var(:Xp, good)) /
                    reference_demand))
        end
    end

    trade, row_routes = common_eu_trade_calibration(calibration)
    for product in EU_TRADED_PRODUCTS, region in outline.regions
        eu_price = _outcome_variable_value(result, _eu_price_id(product))
        push!(rows, _outcome_row(:economic, :eu_market_sales_million_eur;
            region=region, account=product, unit=:million_eur,
            level=eu_price * _outcome_variable_value(result, _eu_sale_id(product, region))))
        push!(rows, _outcome_row(:economic, :eu_market_purchases_million_eur;
            region=region, account=product, unit=:million_eur,
            level=eu_price * _outcome_variable_value(result, _eu_purchase_id(product, region))))
    end
    for route in row_routes
        quantity = _outcome_variable_value(result, JCGEBlocks.global_var(:T, route.id))
        if route.destination === :ROW
            value = _outcome_variable_value(result, JCGEBlocks.global_var(:pS, route.id)) * quantity
            push!(rows, _outcome_row(:economic, :row_export_value_million_eur;
                region=route.origin, account=route.product, unit=:million_eur, level=value))
        else
            value = _outcome_variable_value(result, JCGEBlocks.global_var(:pD, route.id)) * quantity
            push!(rows, _outcome_row(:economic, :row_import_value_million_eur;
                region=route.destination, account=route.product, unit=:million_eur, level=value))
        end
    end

    reference = physical_reference
    if reference === nothing
        model.scenario.name === :baseline || error(
            "Policy outcome reporting requires the matching zero-policy physical reference.")
        reference = physical_flow_reference(result, model)
    end
    for row in eachrow(physical_flow_projection(result, model; reference=reference))
        push!(rows, _outcome_row(:physical, Symbol(:observed_, row.flow_kind);
            region=row.region, account=row.physical_anchor, family=row.family, route=row.route,
            unit=:tonnes, level=row.projected_tonnes))
    end
    if model.circular_metal !== nothing
        for row in eachrow(circular_metal_projection(result, model))
            push!(rows, _outcome_row(:physical, row.quantity_kind;
                region=row.region, account=row.quantity_id, family=row.family, route=row.route,
                material=row.material, unit=:tonnes, level=row.tonnes))
        end
    end

    table = DataFrame(rows)
    _require_unique_outcome_keys(table, "Equilibrium")
    return table
end

"""
    policy_outcome_comparison(baseline_result, baseline_model, policy_result, policy_model)

Compare one accepted policy equilibrium with the zero-policy equilibrium of
the same sensitivity profile. Each row reports the baseline and policy levels,
their absolute change, and the percentage change when the baseline is nonzero.
"""
function policy_outcome_comparison(baseline_result,
    baseline_model::MultiRegionModelSpec,
    policy_result,
    policy_model::MultiRegionModelSpec)
    baseline_model.scenario.name === :baseline || error(
        "Policy outcome comparison requires a zero-policy baseline model.")
    policy_model.scenario.name !== :baseline || error(
        "Policy outcome comparison requires a non-baseline policy model.")
    baseline_model.outline.bundle.name == policy_model.outline.bundle.name || error(
        "Policy and baseline models must use the same sensitivity calibration bundle.")

    reference = physical_flow_reference(baseline_result, baseline_model)
    baseline_table = equilibrium_outcomes(baseline_result, baseline_model;
        physical_reference=reference)
    policy_table = equilibrium_outcomes(policy_result, policy_model;
        physical_reference=reference)
    baseline_keys = _require_unique_outcome_keys(baseline_table, "Baseline")
    policy_keys = _require_unique_outcome_keys(policy_table, "Policy")
    Set(baseline_keys) == Set(policy_keys) || error(
        "Baseline and policy outcome identifiers differ.")

    baseline_level = Dict(
        key => Float64(row.level)
        for (key, row) in zip(baseline_keys, eachrow(baseline_table))
    )
    instrument = _active_policy_instrument(policy_model)
    wedge = policy_wedge(policy_model.scenario, instrument)
    rows = NamedTuple[]
    for (key, row) in zip(policy_keys, eachrow(policy_table))
        base = baseline_level[key]
        policy = Float64(row.level)
        change = policy - base
        push!(rows, merge(NamedTuple{_OUTCOME_KEY_FIELDS}(key), (
            scenario = policy_model.scenario.name,
            instrument = instrument,
            wedge = wedge,
            baseline_level = base,
            policy_level = policy,
            absolute_change = change,
            percentage_change = iszero(base) ? missing : 100.0 * change / base,
        )))
    end
    return DataFrame(rows)
end
