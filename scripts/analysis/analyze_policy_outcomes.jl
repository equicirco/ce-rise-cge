#!/usr/bin/env julia

"""
Create the first policy-result tables and figures from the completed DuckDB
outcome store. Policy intervention and wedge magnitude are the primary
dimensions; ranges across the declared behavioural sensitivity grid describe
parameter dependence rather than statistical uncertainty.
"""

using CairoMakie
using CSV
using DataFrames
using DBInterface
using DuckDB

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_DATABASE = joinpath(ROOT_DIR, "results", "data", "policy_outcomes.duckdb")
const DEFAULT_OUTPUT_DIR = joinpath(ROOT_DIR, "results")

const POLICY_LABELS = Dict(
    "virgin_metal_tax" => "Virgin-metal tax",
    "recycling_support" => "Recycling support",
    "refurbishment_support" => "Refurbishment support",
    "repair_support" => "Repair support",
    "reuse_support" => "Reuse support",
)

const POLICY_ORDER = [
    "virgin_metal_tax",
    "recycling_support",
    "refurbishment_support",
    "repair_support",
    "reuse_support",
]

const POLICY_COLOURS = Dict(
    "virgin_metal_tax" => colorant"#4E5D6C",
    "recycling_support" => colorant"#4E79A7",
    "refurbishment_support" => colorant"#E17C05",
    "repair_support" => colorant"#6F8F3D",
    "reuse_support" => colorant"#8064A2",
)

function command_options(args)
    database = DEFAULT_DATABASE
    output_dir = DEFAULT_OUTPUT_DIR
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--database" && index < length(args)
            database = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--output-dir" && index < length(args)
            output_dir = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/analyze_policy_outcomes.jl " *
                "[--database PATH] [--output-dir PATH] [--dry-run]")
        end
    end
    return (database = database, output_dir = output_dir, dry_run = dry_run)
end

function query(connection, sql::AbstractString)
    return DataFrame(DBInterface.execute(connection, sql))
end

function policy_primary_metal_summary(connection)
    return query(connection, """
        SELECT
            instrument,
            abs(wedge) * 100.0 AS wedge_percent,
            count(*) AS valid_parameter_configurations,
            median(primary_metal_market_demand_reduction_tonnes) AS median_reduction_tonnes,
            quantile_cont(primary_metal_market_demand_reduction_tonnes, 0.25) AS lower_quartile_reduction_tonnes,
            quantile_cont(primary_metal_market_demand_reduction_tonnes, 0.75) AS upper_quartile_reduction_tonnes,
            min(primary_metal_market_demand_reduction_tonnes) AS minimum_reduction_tonnes,
            max(primary_metal_market_demand_reduction_tonnes) AS maximum_reduction_tonnes,
            median(100.0 * primary_metal_market_demand_reduction_tonnes /
                (primary_metal_market_demand_tonnes + primary_metal_market_demand_reduction_tonnes)) AS median_reduction_percent,
            quantile_cont(100.0 * primary_metal_market_demand_reduction_tonnes /
                (primary_metal_market_demand_tonnes + primary_metal_market_demand_reduction_tonnes), 0.25) AS lower_quartile_reduction_percent,
            quantile_cont(100.0 * primary_metal_market_demand_reduction_tonnes /
                (primary_metal_market_demand_tonnes + primary_metal_market_demand_reduction_tonnes), 0.75) AS upper_quartile_reduction_percent
        FROM policy_points
        WHERE solver_valid
        GROUP BY instrument, wedge
        ORDER BY instrument, wedge_percent
    """)
end

function policy_fiscal_summary(connection)
    return query(connection, """
        SELECT
            instrument,
            abs(wedge) * 100.0 AS wedge_percent,
            count(*) AS valid_parameter_configurations,
            median(fiscal_basis_million_eur) AS median_fiscal_basis_million_eur,
            quantile_cont(fiscal_basis_million_eur, 0.25) AS lower_quartile_fiscal_basis_million_eur,
            quantile_cont(fiscal_basis_million_eur, 0.75) AS upper_quartile_fiscal_basis_million_eur,
            min(fiscal_basis_million_eur) AS minimum_fiscal_basis_million_eur,
            max(fiscal_basis_million_eur) AS maximum_fiscal_basis_million_eur
        FROM policy_points
        WHERE solver_valid
        GROUP BY instrument, wedge
        ORDER BY instrument, wedge_percent
    """)
end

function policy_support_efficiency_summary(connection)
    return query(connection, """
        SELECT
            instrument,
            abs(wedge) * 100.0 AS wedge_percent,
            count(*) AS valid_parameter_configurations,
            median(primary_metal_market_demand_reduction_per_million_eur) AS median_tonnes_per_million_eur,
            quantile_cont(primary_metal_market_demand_reduction_per_million_eur, 0.25) AS lower_quartile_tonnes_per_million_eur,
            quantile_cont(primary_metal_market_demand_reduction_per_million_eur, 0.75) AS upper_quartile_tonnes_per_million_eur,
            min(primary_metal_market_demand_reduction_per_million_eur) AS minimum_tonnes_per_million_eur,
            max(primary_metal_market_demand_reduction_per_million_eur) AS maximum_tonnes_per_million_eur
        FROM policy_points
        WHERE solver_valid
          AND fiscal_basis_kind = 'support_expenditure'
        GROUP BY instrument, wedge
        ORDER BY instrument, wedge_percent
    """)
end

function policy_activity_summary(connection)
    return query(connection, """
        WITH activity_changes AS (
            SELECT
                sensitivity_profile,
                scenario,
                instrument,
                wedge,
                CASE
                    WHEN account LIKE '%\\_NEW\\_ELMA' ESCAPE '\\' OR
                         account LIKE '%\\_NEW\\_OFMA' ESCAPE '\\' OR
                         account LIKE '%\\_NEW\\_RATV' ESCAPE '\\' THEN 'New CE-RISE products'
                    WHEN account LIKE '%\\_REF\\_ELMA' ESCAPE '\\' OR
                         account LIKE '%\\_REF\\_OFMA' ESCAPE '\\' OR
                         account LIKE '%\\_REF\\_RATV' ESCAPE '\\' THEN 'Refurbishment'
                    WHEN account LIKE '%\\_REP\\_ELMA' ESCAPE '\\' OR
                         account LIKE '%\\_REP\\_OFMA' ESCAPE '\\' OR
                         account LIKE '%\\_REP\\_RATV' ESCAPE '\\' THEN 'Repair'
                    WHEN account LIKE '%\\_REU\\_ELMA' ESCAPE '\\' OR
                         account LIKE '%\\_REU\\_OFMA' ESCAPE '\\' OR
                         account LIKE '%\\_REU\\_RATV' ESCAPE '\\' THEN 'Reuse'
                    WHEN account LIKE '%\\_REC\\_EE' ESCAPE '\\' THEN 'Recycling'
                    WHEN account LIKE '%\\_BASIC\\_METALS' ESCAPE '\\' THEN 'Basic metals'
                    WHEN account LIKE '%\\_TRADE' ESCAPE '\\' THEN 'Trade'
                    ELSE 'All industries'
                END AS activity_group,
                baseline_level,
                policy_level
            FROM policy_outcomes
            WHERE indicator = 'activity_gross_output_million_eur'
        ),
        grouped AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, activity_group,
                sum(policy_level - baseline_level) AS absolute_change_million_eur,
                100.0 * sum(policy_level - baseline_level) / sum(baseline_level) AS percentage_change
            FROM activity_changes
            GROUP BY sensitivity_profile, scenario, instrument, wedge, activity_group
        ),
        all_industries AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, 'All industries' AS activity_group,
                sum(policy_level - baseline_level) AS absolute_change_million_eur,
                100.0 * sum(policy_level - baseline_level) / sum(baseline_level) AS percentage_change
            FROM policy_outcomes
            WHERE indicator = 'activity_gross_output_million_eur'
            GROUP BY sensitivity_profile, scenario, instrument, wedge
        ),
        combined AS (
            SELECT * FROM grouped WHERE activity_group <> 'All industries'
            UNION ALL
            SELECT * FROM all_industries
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, activity_group,
            count(*) AS valid_parameter_configurations,
            median(absolute_change_million_eur) AS median_change_million_eur,
            quantile_cont(absolute_change_million_eur, 0.25) AS lower_quartile_change_million_eur,
            quantile_cont(absolute_change_million_eur, 0.75) AS upper_quartile_change_million_eur,
            median(percentage_change) AS median_change_percent,
            quantile_cont(percentage_change, 0.25) AS lower_quartile_change_percent,
            quantile_cont(percentage_change, 0.75) AS upper_quartile_change_percent
        FROM combined
        GROUP BY instrument, wedge, activity_group
        ORDER BY instrument, wedge_percent, activity_group
    """)
end

function policy_material_flow_summary(connection)
    return query(connection, """
        WITH flows AS (
            SELECT sensitivity_profile, scenario, instrument, wedge,
                indicator,
                coalesce(material, 'all') AS material,
                sum(absolute_change) AS absolute_change_tonnes,
                100.0 * sum(absolute_change) / nullif(sum(baseline_level), 0.0) AS percentage_change
            FROM policy_outcomes
            WHERE domain = 'physical'
              AND indicator IN ('ce_route_metal_demand', 'primary_metal_output',
                  'recycled_metal_output', 'observed_new_product_output',
                  'observed_recycled_metal_output', 'observed_route_input_mass')
            GROUP BY sensitivity_profile, scenario, instrument, wedge, indicator, material
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, indicator, material,
            count(*) AS valid_parameter_configurations,
            median(absolute_change_tonnes) AS median_change_tonnes,
            quantile_cont(absolute_change_tonnes, 0.25) AS lower_quartile_change_tonnes,
            quantile_cont(absolute_change_tonnes, 0.75) AS upper_quartile_change_tonnes,
            median(percentage_change) AS median_change_percent,
            quantile_cont(percentage_change, 0.25) AS lower_quartile_change_percent,
            quantile_cont(percentage_change, 0.75) AS upper_quartile_change_percent
        FROM flows
        GROUP BY instrument, wedge, indicator, material
        ORDER BY instrument, wedge_percent, indicator, material
    """)
end

function policy_circular_route_summary(connection)
    return query(connection, """
        WITH route_flows AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, family, route,
                sum(absolute_change) AS absolute_change_tonnes,
                100.0 * sum(absolute_change) / nullif(sum(baseline_level), 0.0) AS percentage_change
            FROM policy_outcomes
            WHERE indicator = 'observed_route_input_mass'
            GROUP BY sensitivity_profile, scenario, instrument, wedge, family, route
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, family, route,
            count(*) AS valid_parameter_configurations,
            median(absolute_change_tonnes) AS median_change_tonnes,
            quantile_cont(absolute_change_tonnes, 0.25) AS lower_quartile_change_tonnes,
            quantile_cont(absolute_change_tonnes, 0.75) AS upper_quartile_change_tonnes,
            median(percentage_change) AS median_change_percent,
            quantile_cont(percentage_change, 0.25) AS lower_quartile_change_percent,
            quantile_cont(percentage_change, 0.75) AS upper_quartile_change_percent
        FROM route_flows
        GROUP BY instrument, wedge, family, route
        ORDER BY instrument, wedge_percent, family, route
    """)
end

function policy_circular_route_total_summary(connection)
    return query(connection, """
        WITH route_flows AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, route,
                sum(absolute_change) AS absolute_change_tonnes,
                100.0 * sum(absolute_change) / nullif(sum(baseline_level), 0.0) AS percentage_change
            FROM policy_outcomes
            WHERE indicator = 'observed_route_input_mass'
            GROUP BY sensitivity_profile, scenario, instrument, wedge, route
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, route,
            count(*) AS valid_parameter_configurations,
            median(absolute_change_tonnes) AS median_change_tonnes,
            quantile_cont(absolute_change_tonnes, 0.25) AS lower_quartile_change_tonnes,
            quantile_cont(absolute_change_tonnes, 0.75) AS upper_quartile_change_tonnes,
            median(percentage_change) AS median_change_percent,
            quantile_cont(percentage_change, 0.25) AS lower_quartile_change_percent,
            quantile_cont(percentage_change, 0.75) AS upper_quartile_change_percent
        FROM route_flows
        GROUP BY instrument, wedge, route
        ORDER BY instrument, wedge_percent, route
    """)
end

function policy_avoided_new_product_summary(connection)
    return query(connection, """
        WITH family_output AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, family,
                sum(absolute_change) AS new_product_change_tonnes,
                sum(baseline_level) AS baseline_new_product_tonnes
            FROM policy_outcomes
            WHERE indicator = 'observed_new_product_output'
            GROUP BY sensitivity_profile, scenario, instrument, wedge, family
        ),
        combined AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, family,
                new_product_change_tonnes, baseline_new_product_tonnes
            FROM family_output
            UNION ALL
            SELECT sensitivity_profile, scenario, instrument, wedge,
                'all CE-RISE families' AS family,
                sum(new_product_change_tonnes) AS new_product_change_tonnes,
                sum(baseline_new_product_tonnes) AS baseline_new_product_tonnes
            FROM family_output
            GROUP BY sensitivity_profile, scenario, instrument, wedge
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, family,
            count(*) AS valid_parameter_configurations,
            median(-new_product_change_tonnes) AS median_avoided_new_product_tonnes,
            quantile_cont(-new_product_change_tonnes, 0.25) AS lower_quartile_avoided_new_product_tonnes,
            quantile_cont(-new_product_change_tonnes, 0.75) AS upper_quartile_avoided_new_product_tonnes,
            median(-100.0 * new_product_change_tonnes / nullif(baseline_new_product_tonnes, 0.0))
                AS median_avoided_new_product_percent,
            quantile_cont(-100.0 * new_product_change_tonnes / nullif(baseline_new_product_tonnes, 0.0), 0.25)
                AS lower_quartile_avoided_new_product_percent,
            quantile_cont(-100.0 * new_product_change_tonnes / nullif(baseline_new_product_tonnes, 0.0), 0.75)
                AS upper_quartile_avoided_new_product_percent
        FROM combined
        GROUP BY instrument, wedge, family
        ORDER BY instrument, wedge_percent, family
    """)
end

function refurbishment_metal_demand_summary(connection)
    return query(connection, """
        WITH route_demand AS (
            SELECT sensitivity_profile, scenario, wedge, family, material,
                sum(absolute_change) AS metal_demand_change_tonnes,
                sum(baseline_level) AS baseline_metal_demand_tonnes
            FROM policy_outcomes
            WHERE instrument = 'refurbishment_support'
              AND indicator = 'ce_route_metal_demand'
              AND route = 'REF'
            GROUP BY sensitivity_profile, scenario, wedge, family, material
        )
        SELECT abs(wedge) * 100.0 AS wedge_percent, family, material,
            count(*) AS valid_parameter_configurations,
            median(metal_demand_change_tonnes) AS median_metal_demand_change_tonnes,
            quantile_cont(metal_demand_change_tonnes, 0.25) AS lower_quartile_metal_demand_change_tonnes,
            quantile_cont(metal_demand_change_tonnes, 0.75) AS upper_quartile_metal_demand_change_tonnes,
            median(100.0 * metal_demand_change_tonnes / nullif(baseline_metal_demand_tonnes, 0.0))
                AS median_metal_demand_change_percent,
            quantile_cont(100.0 * metal_demand_change_tonnes / nullif(baseline_metal_demand_tonnes, 0.0), 0.25)
                AS lower_quartile_metal_demand_change_percent,
            quantile_cont(100.0 * metal_demand_change_tonnes / nullif(baseline_metal_demand_tonnes, 0.0), 0.75)
                AS upper_quartile_metal_demand_change_percent
        FROM route_demand
        GROUP BY wedge, family, material
        ORDER BY wedge_percent, family, material
    """)
end

function policy_incidence_summary(connection)
    return query(connection, """
        WITH regional_outcomes AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, region,
                'Household disposable income' AS outcome, NULL::VARCHAR AS factor,
                baseline_level, policy_level
            FROM policy_outcomes
            WHERE indicator = 'household_disposable_income_million_eur'
            UNION ALL
            SELECT sensitivity_profile, scenario, instrument, wedge, region,
                'Household consumption' AS outcome, NULL::VARCHAR AS factor,
                baseline_level, policy_level
            FROM policy_outcomes
            WHERE indicator = 'household_consumption_million_eur'
            UNION ALL
            SELECT sensitivity_profile, scenario, instrument, wedge, region,
                'Household utility' AS outcome, NULL::VARCHAR AS factor,
                baseline_level, policy_level
            FROM policy_outcomes
            WHERE indicator = 'household_utility_index'
            UNION ALL
            SELECT sensitivity_profile, scenario, instrument, wedge, region,
                'Factor income' AS outcome, factor,
                sum(baseline_level) AS baseline_level,
                sum(policy_level) AS policy_level
            FROM policy_outcomes
            WHERE indicator = 'factor_income_million_eur'
            GROUP BY sensitivity_profile, scenario, instrument, wedge, region, factor
        ),
        changes AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, region, outcome, factor,
                policy_level - baseline_level AS absolute_change,
                100.0 * (policy_level - baseline_level) / nullif(baseline_level, 0.0) AS percentage_change
            FROM regional_outcomes
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, region, outcome, factor,
            count(*) AS valid_parameter_configurations,
            median(absolute_change) AS median_absolute_change,
            quantile_cont(absolute_change, 0.25) AS lower_quartile_absolute_change,
            quantile_cont(absolute_change, 0.75) AS upper_quartile_absolute_change,
            median(percentage_change) AS median_change_percent,
            quantile_cont(percentage_change, 0.25) AS lower_quartile_change_percent,
            quantile_cont(percentage_change, 0.75) AS upper_quartile_change_percent
        FROM changes
        GROUP BY instrument, wedge, region, outcome, factor
        ORDER BY instrument, wedge_percent, region, outcome, factor
    """)
end

function primary_metal_parameter_sensitivity(connection)
    return query(connection, """
        WITH outcomes AS (
            SELECT instrument, wedge,
                100.0 * primary_metal_market_demand_reduction_tonnes /
                    (primary_metal_market_demand_tonnes + primary_metal_market_demand_reduction_tonnes)
                    AS primary_metal_reduction_percent,
                armington_elasticity, cet_transformation_elasticity, service_elasticity,
                eol_allocation_elasticity, eol_productivity_elasticity,
                material_substitution_elasticity
            FROM policy_points
            WHERE solver_valid
        ),
        parameter_values AS (
            SELECT instrument, wedge, 'Armington elasticity' AS parameter, armington_elasticity AS value,
                primary_metal_reduction_percent FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'CET transformation elasticity', cet_transformation_elasticity,
                primary_metal_reduction_percent FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'Circular-service elasticity', service_elasticity,
                primary_metal_reduction_percent FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'EOL-allocation elasticity', eol_allocation_elasticity,
                primary_metal_reduction_percent FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'EOL-productivity elasticity', eol_productivity_elasticity,
                primary_metal_reduction_percent FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'Metal-substitution elasticity', material_substitution_elasticity,
                primary_metal_reduction_percent FROM outcomes
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, parameter, value,
            count(*) AS valid_parameter_configurations,
            median(primary_metal_reduction_percent) AS median_reduction_percent,
            quantile_cont(primary_metal_reduction_percent, 0.25) AS lower_quartile_reduction_percent,
            quantile_cont(primary_metal_reduction_percent, 0.75) AS upper_quartile_reduction_percent,
            min(primary_metal_reduction_percent) AS minimum_reduction_percent,
            max(primary_metal_reduction_percent) AS maximum_reduction_percent
        FROM parameter_values
        GROUP BY instrument, wedge, parameter, value
        ORDER BY instrument, wedge_percent, parameter, value
    """)
end

function primary_metal_parameter_sensitivity_ranking(connection)
    return query(connection, """
        WITH outcomes AS (
            SELECT instrument, wedge,
                primary_metal_market_demand_reduction_tonnes,
                armington_elasticity, cet_transformation_elasticity, service_elasticity,
                eol_allocation_elasticity, eol_productivity_elasticity,
                material_substitution_elasticity
            FROM policy_points
            WHERE solver_valid
        ),
        parameter_values AS (
            SELECT instrument, wedge, 'Armington elasticity' AS parameter, armington_elasticity AS value,
                primary_metal_market_demand_reduction_tonnes AS reduction_tonnes FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'CET transformation elasticity', cet_transformation_elasticity,
                primary_metal_market_demand_reduction_tonnes FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'Circular-service elasticity', service_elasticity,
                primary_metal_market_demand_reduction_tonnes FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'EOL-allocation elasticity', eol_allocation_elasticity,
                primary_metal_market_demand_reduction_tonnes FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'EOL-productivity elasticity', eol_productivity_elasticity,
                primary_metal_market_demand_reduction_tonnes FROM outcomes
            UNION ALL
            SELECT instrument, wedge, 'Metal-substitution elasticity', material_substitution_elasticity,
                primary_metal_market_demand_reduction_tonnes FROM outcomes
        ),
        conditional_medians AS (
            SELECT instrument, wedge, parameter, value, median(reduction_tonnes) AS median_reduction_tonnes
            FROM parameter_values
            GROUP BY instrument, wedge, parameter, value
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, parameter,
            arg_min(value, median_reduction_tonnes) AS value_at_lowest_median,
            min(median_reduction_tonnes) AS lowest_median_reduction_tonnes,
            arg_max(value, median_reduction_tonnes) AS value_at_highest_median,
            max(median_reduction_tonnes) AS highest_median_reduction_tonnes,
            max(median_reduction_tonnes) - min(median_reduction_tonnes) AS conditional_median_range_tonnes,
            min(median_reduction_tonnes) < 0.0 AND max(median_reduction_tonnes) > 0.0 AS changes_material_outcome_sign
        FROM conditional_medians
        GROUP BY instrument, wedge, parameter
        ORDER BY instrument, wedge_percent, conditional_median_range_tonnes DESC
    """)
end

const SENSITIVITY_PARAMETERS = [
    ("Armington elasticity", "armington_elasticity"),
    ("CET transformation elasticity", "cet_transformation_elasticity"),
    ("Circular-service elasticity", "service_elasticity"),
    ("EOL-allocation elasticity", "eol_allocation_elasticity"),
    ("EOL-productivity elasticity", "eol_productivity_elasticity"),
    ("Metal-substitution elasticity", "material_substitution_elasticity"),
]

function primary_metal_parameter_pair_summary(connection)
    pair_queries = String[]
    for first_index in 1:(length(SENSITIVITY_PARAMETERS) - 1)
        x_label, x_column = SENSITIVITY_PARAMETERS[first_index]
        for second_index in (first_index + 1):length(SENSITIVITY_PARAMETERS)
            y_label, y_column = SENSITIVITY_PARAMETERS[second_index]
            push!(pair_queries, """
                SELECT instrument, wedge,
                    '$(x_label)' AS x_parameter, $(x_column) AS x_value,
                    '$(y_label)' AS y_parameter, $(y_column) AS y_value,
                    primary_metal_market_demand_reduction_tonnes AS reduction_tonnes
                FROM policy_points
                WHERE solver_valid
            """)
        end
    end
    unioned_pairs = join(pair_queries, "\nUNION ALL\n")
    return query(connection, """
        WITH pair_values AS (
            $(unioned_pairs)
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent,
            x_parameter, x_value, y_parameter, y_value,
            count(*) AS valid_remaining_parameter_configurations,
            median(reduction_tonnes) AS median_reduction_tonnes,
            min(reduction_tonnes) AS minimum_reduction_tonnes,
            max(reduction_tonnes) AS maximum_reduction_tonnes,
            CASE
                WHEN min(reduction_tonnes) > 0.0 THEN 'primary_metal_saving'
                WHEN max(reduction_tonnes) < 0.0 THEN 'primary_metal_increase'
                ELSE 'parameter_dependent'
            END AS material_outcome_regime
        FROM pair_values
        GROUP BY instrument, wedge, x_parameter, x_value, y_parameter, y_value
        ORDER BY instrument, wedge_percent, x_parameter, y_parameter, x_value, y_value
    """)
end

function instrument_rows(table::DataFrame, instrument::AbstractString)
    rows = filter(:instrument => ==(instrument), table)
    sort!(rows, :wedge_percent)
    return rows
end

function policy_grid_figure(table::DataFrame, value, lower, upper;
    ylabel::AbstractString, filename::AbstractString)
    figure = Figure(size=(1200, 900), fontsize=18)
    grid = figure[1, 1] = GridLayout()
    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        axis = Axis(grid[position...];
            title=POLICY_LABELS[instrument],
            xlabel="Policy wedge (%)",
            ylabel=index in (1, 4) ? ylabel : "",
            xticks=[0.25, 0.5, 1.0, 2.0],
            backgroundcolor=:gray95)
        rows = instrument_rows(table, instrument)
        x = rows.wedge_percent
        band!(axis, x, rows[!, lower], rows[!, upper];
            color=(POLICY_COLOURS[instrument], 0.25))
        lines!(axis, x, rows[!, value]; color=POLICY_COLOURS[instrument], linewidth=3)
        scatter!(axis, x, rows[!, value]; color=POLICY_COLOURS[instrument], markersize=10)
        hlines!(axis, [0.0]; color=:black, linewidth=1, linestyle=:dash)
    end
    Label(grid[2, 3], "Line and points: median\nShaded band: interquartile range",
        tellwidth=false,
        halign=:center, valign=:center, fontsize=15)
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 14)
    rowgap!(grid, 18)
    save(filename, figure)
    return nothing
end

const ROUTE_LABELS = Dict(
    "INC" => "Incineration / landfill",
    "REC" => "Recycling",
    "REF" => "Refurbishment",
    "REP" => "Repair",
    "REU" => "Reuse",
)

const ROUTE_ORDER = ["INC", "REC", "REP", "REU"]

const ROUTE_COLOURS = Dict(
    "INC" => colorant"#7A7A7A",
    "REC" => colorant"#4E79A7",
    "REF" => colorant"#E17C05",
    "REP" => colorant"#6F8F3D",
    "REU" => colorant"#8064A2",
)

function circular_route_figure(table::DataFrame; filename::AbstractString)
    figure = Figure(size=(1200, 900), fontsize=18)
    grid = figure[1, 1] = GridLayout()
    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        axis = Axis(grid[position...];
            title=POLICY_LABELS[instrument],
            xlabel="Policy wedge (%)",
            ylabel=index in (1, 4) ? "Change in route input mass (%)" : "",
            xticks=[0.25, 0.5, 1.0, 2.0],
            backgroundcolor=:gray95)
        policy_rows = filter(:instrument => ==(instrument), table)
        for route in ROUTE_ORDER
            rows = filter(:route => ==(route), policy_rows)
            isempty(rows) && continue
            sort!(rows, :wedge_percent)
            band!(axis, rows.wedge_percent,
                rows.lower_quartile_change_percent, rows.upper_quartile_change_percent;
                color=(ROUTE_COLOURS[route], 0.16))
            lines!(axis, rows.wedge_percent, rows.median_change_percent;
                color=ROUTE_COLOURS[route], linewidth=3)
            scatter!(axis, rows.wedge_percent, rows.median_change_percent;
                color=ROUTE_COLOURS[route], markersize=9)
        end
        hlines!(axis, [0.0]; color=:black, linewidth=1, linestyle=:dash)
    end
    legend_elements = [LineElement(color=ROUTE_COLOURS[route], linewidth=3) for route in ROUTE_ORDER]
    Legend(grid[2, 3], legend_elements, [ROUTE_LABELS[route] for route in ROUTE_ORDER];
        tellwidth=false, halign=:center, valign=:center, labelsize=15)
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 14)
    rowgap!(grid, 18)
    save(filename, figure)
    return nothing
end

function support_efficiency_figure(table::DataFrame; filename::AbstractString)
    support_instruments = filter(!=("virgin_metal_tax"), POLICY_ORDER)
    figure = Figure(size=(1200, 800), fontsize=18)
    grid = figure[1, 1] = GridLayout()
    for (index, instrument) in enumerate(support_instruments)
        row = index <= 2 ? 1 : 2
        column = isodd(index) ? 1 : 2
        axis = Axis(grid[row, column];
            title=POLICY_LABELS[instrument],
            xlabel="Policy wedge (%)",
            ylabel=column == 1 ? "Primary-metal reduction\n(t / million EUR support)" : "",
            xticks=[0.25, 0.5, 1.0, 2.0],
            backgroundcolor=:gray95)
        rows = instrument_rows(table, instrument)
        band!(axis, rows.wedge_percent,
            rows.lower_quartile_tonnes_per_million_eur,
            rows.upper_quartile_tonnes_per_million_eur;
            color=(POLICY_COLOURS[instrument], 0.25))
        lines!(axis, rows.wedge_percent, rows.median_tonnes_per_million_eur;
            color=POLICY_COLOURS[instrument], linewidth=3)
        scatter!(axis, rows.wedge_percent, rows.median_tonnes_per_million_eur;
            color=POLICY_COLOURS[instrument], markersize=10)
        hlines!(axis, [0.0]; color=:black, linewidth=1, linestyle=:dash)
    end
    rowgap!(grid, 18)
    colgap!(grid, 20)
    save(filename, figure)
    return nothing
end

function write_outputs(options, primary, fiscal, efficiency, activity, flows, routes, route_totals,
    avoided_new_products, refurbishment_metal_demand, incidence, parameter_sensitivity,
    parameter_ranking, parameter_pairs)
    mkpath(options.output_dir)
    CSV.write(joinpath(options.output_dir, "policy_primary_metal_summary.csv"), primary)
    CSV.write(joinpath(options.output_dir, "policy_fiscal_summary.csv"), fiscal)
    CSV.write(joinpath(options.output_dir, "policy_support_efficiency_summary.csv"), efficiency)
    CSV.write(joinpath(options.output_dir, "policy_activity_summary.csv"), activity)
    CSV.write(joinpath(options.output_dir, "policy_material_flow_summary.csv"), flows)
    CSV.write(joinpath(options.output_dir, "policy_circular_route_summary.csv"), routes)
    CSV.write(joinpath(options.output_dir, "policy_circular_route_total_summary.csv"), route_totals)
    CSV.write(joinpath(options.output_dir, "policy_avoided_new_product_summary.csv"), avoided_new_products)
    CSV.write(joinpath(options.output_dir, "policy_refurbishment_metal_demand_summary.csv"),
        refurbishment_metal_demand)
    CSV.write(joinpath(options.output_dir, "policy_incidence_summary.csv"), incidence)
    CSV.write(joinpath(options.output_dir, "policy_primary_metal_parameter_sensitivity.csv"),
        parameter_sensitivity)
    CSV.write(joinpath(options.output_dir, "policy_primary_metal_parameter_sensitivity_ranking.csv"),
        parameter_ranking)
    CSV.write(joinpath(options.output_dir, "policy_primary_metal_parameter_pair_summary.csv"),
        parameter_pairs)
    policy_grid_figure(primary, :median_reduction_percent,
        :lower_quartile_reduction_percent, :upper_quartile_reduction_percent;
        ylabel="Primary-metal demand reduction (%)",
        filename=joinpath(options.output_dir, "policy_primary_metal_reduction.pdf"))
    policy_grid_figure(fiscal, :median_fiscal_basis_million_eur,
        :lower_quartile_fiscal_basis_million_eur, :upper_quartile_fiscal_basis_million_eur;
        ylabel="Fiscal flow (million EUR)",
        filename=joinpath(options.output_dir, "policy_fiscal_scale.pdf"))
    circular_route_figure(route_totals;
        filename=joinpath(options.output_dir, "policy_circular_route_response.pdf"))
    support_efficiency_figure(efficiency;
        filename=joinpath(options.output_dir, "policy_support_efficiency.pdf"))
    return nothing
end

function main()
    options = command_options(ARGS)
    isfile(options.database) || error("Outcome database is missing: $(options.database)")
    println("Database: ", options.database)
    println("Output directory: ", options.output_dir)
    if options.dry_run
        println("Outputs: thirteen aggregate CSV tables and four policy-by-wedge PDF figures.")
        return nothing
    end
    database = DuckDB.DB(options.database)
    connection = DBInterface.connect(database)
    try
        primary = policy_primary_metal_summary(connection)
        fiscal = policy_fiscal_summary(connection)
        efficiency = policy_support_efficiency_summary(connection)
        activity = policy_activity_summary(connection)
        flows = policy_material_flow_summary(connection)
        routes = policy_circular_route_summary(connection)
        route_totals = policy_circular_route_total_summary(connection)
        avoided_new_products = policy_avoided_new_product_summary(connection)
        refurbishment_metal_demand = refurbishment_metal_demand_summary(connection)
        incidence = policy_incidence_summary(connection)
        parameter_sensitivity = primary_metal_parameter_sensitivity(connection)
        parameter_ranking = primary_metal_parameter_sensitivity_ranking(connection)
        parameter_pairs = primary_metal_parameter_pair_summary(connection)
        write_outputs(options, primary, fiscal, efficiency, activity, flows, routes, route_totals,
            avoided_new_products, refurbishment_metal_demand, incidence, parameter_sensitivity,
            parameter_ranking, parameter_pairs)
        println("Primary-metal summary rows: ", nrow(primary))
        println("Fiscal summary rows: ", nrow(fiscal))
        println("Support-efficiency summary rows: ", nrow(efficiency))
        println("Activity summary rows: ", nrow(activity))
        println("Material-flow summary rows: ", nrow(flows))
        println("Circular-route summary rows: ", nrow(routes))
        println("Circular-route total summary rows: ", nrow(route_totals))
        println("Avoided-new-product summary rows: ", nrow(avoided_new_products))
        println("Refurbishment METAL-demand summary rows: ", nrow(refurbishment_metal_demand))
        println("Incidence summary rows: ", nrow(incidence))
        println("Parameter-sensitivity summary rows: ", nrow(parameter_sensitivity))
        println("Parameter-sensitivity ranking rows: ", nrow(parameter_ranking))
        println("Parameter-pair summary rows: ", nrow(parameter_pairs))
    finally
        DBInterface.close!(connection)
        close(database)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
