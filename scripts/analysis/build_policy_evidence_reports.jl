#!/usr/bin/env julia

"""
Build reproducible policy-analysis figures and the generated result tables
inserted into the article. Results are organised by policy intervention and
wedge; ranges across the sensitivity design describe parameter dependence,
not a probability distribution.
"""

include(joinpath(@__DIR__, "analyze_policy_outcomes.jl"))

const EVIDENCE_WEDGE_PERCENT = 2.0

const DIRECT_POLICY_ROUTES = Dict(
    "recycling_support" => "REC",
    "repair_support" => "REP",
    "reuse_support" => "REU",
)

const EVIDENCE_PARAMETER_PAIRS = Dict(
    "virgin_metal_tax" => ("Armington elasticity", "CET transformation elasticity"),
    "recycling_support" => ("CET transformation elasticity", "Metal-substitution elasticity"),
    "refurbishment_support" => ("CET transformation elasticity", "Circular-service elasticity"),
    "repair_support" => ("CET transformation elasticity", "Circular-service elasticity"),
    "reuse_support" => ("CET transformation elasticity", "Circular-service elasticity"),
)

const KEY_POLICY_CONDITIONS = Dict(
    "virgin_metal_tax" => "Armington elasticity",
    "recycling_support" => "Metal-substitution elasticity",
    "refurbishment_support" => "Circular-service elasticity",
    "repair_support" => "Circular-service elasticity",
    "reuse_support" => "Circular-service elasticity",
)

const CONDITION_RESPONSE_VALUES = (0.5, 1.0, 2.0)
const CONDITION_RESPONSE_COLOURS = Dict(
    0.5 => colorant"#4E5D6C",
    1.0 => colorant"#4E79A7",
    2.0 => colorant"#8064A2",
)

const REGION_ORDER = ["DE", "FR", "IT", "PL", "REU", "SK"]

const TRANSMISSION_ACTIVITY_GROUPS = [
    "Basic metals",
    "Metal components",
    "Other manufacturing",
    "Trade",
    "Other services",
]

const REGION_COLOURS = Dict(
    "DE" => colorant"#4E79A7",
    "FR" => colorant"#E17C05",
    "IT" => colorant"#6F8F3D",
    "PL" => colorant"#8064A2",
    "REU" => colorant"#A64D79",
    "SK" => colorant"#7A7A7A",
)

function at_evidence_wedge(table::DataFrame)
    return filter(:wedge_percent => ==(EVIDENCE_WEDGE_PERCENT), table)
end

function route_mechanism_evidence(routes::DataFrame, activity::DataFrame)
    rows = NamedTuple[]
    for instrument in filter(!=("virgin_metal_tax"), POLICY_ORDER)
        if instrument == "refurbishment_support"
            selected = filter(row -> row.instrument == instrument &&
                row.activity_group == "Refurbishment", activity)
            for row in eachrow(selected)
                push!(rows, (
                    instrument = row.instrument,
                    wedge_percent = row.wedge_percent,
                    mechanism = "Refurbishment activity output",
                    unit = "million EUR",
                    physical_anchor = false,
                    median_change = row.median_change_million_eur,
                    lower_quartile_change = row.lower_quartile_change_million_eur,
                    upper_quartile_change = row.upper_quartile_change_million_eur,
                    median_change_percent = row.median_change_percent,
                    lower_quartile_change_percent = row.lower_quartile_change_percent,
                    upper_quartile_change_percent = row.upper_quartile_change_percent,
                ))
            end
        else
            route = DIRECT_POLICY_ROUTES[instrument]
            selected = filter(row -> row.instrument == instrument && row.route == route, routes)
            for row in eachrow(selected)
                push!(rows, (
                    instrument = row.instrument,
                    wedge_percent = row.wedge_percent,
                    mechanism = "$(ROUTE_LABELS[route]) route input mass",
                    unit = "tonnes",
                    physical_anchor = true,
                    median_change = row.median_change_tonnes,
                    lower_quartile_change = row.lower_quartile_change_tonnes,
                    upper_quartile_change = row.upper_quartile_change_tonnes,
                    median_change_percent = row.median_change_percent,
                    lower_quartile_change_percent = row.lower_quartile_change_percent,
                    upper_quartile_change_percent = row.upper_quartile_change_percent,
                ))
            end
        end
    end
    result = DataFrame(rows)
    sort!(result, [:instrument, :wedge_percent])
    return result
end

function selected_boundary_evidence(pair_summary::DataFrame;
    wedge_percent::Float64=EVIDENCE_WEDGE_PERCENT)
    selected = DataFrame()
    for instrument in POLICY_ORDER
        x_parameter, y_parameter = EVIDENCE_PARAMETER_PAIRS[instrument]
        rows = filter(row ->
            row.instrument == instrument &&
            row.wedge_percent == wedge_percent &&
            row.x_parameter == x_parameter &&
            row.y_parameter == y_parameter,
            pair_summary)
        append!(selected, rows)
    end
    sort!(selected, [:instrument, :x_value, :y_value])
    return selected
end

function wedge_slug(wedge_percent::Float64)
    return replace(string(wedge_percent), "." => "_")
end

function household_income_evidence(incidence::DataFrame)
    selected = filter(row ->
        row.wedge_percent == EVIDENCE_WEDGE_PERCENT &&
        row.outcome == "Household disposable income",
        incidence)
    sort!(selected, [:instrument, :region])
    return selected
end

"""Summarise broad-industry output transmission by policy and European region."""
function activity_transmission_evidence(connection)
    return query(connection, """
        WITH activity_changes AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, region,
                CASE
                    WHEN account LIKE '%\\_BASIC\\_METALS' ESCAPE '\\' THEN 'Basic metals'
                    WHEN account LIKE '%\\_METAL\\_COMPONENTS' ESCAPE '\\' THEN 'Metal components'
                    WHEN account LIKE '%\\_OTHER\\_MANUFACTURING' ESCAPE '\\' THEN 'Other manufacturing'
                    WHEN account LIKE '%\\_TRADE' ESCAPE '\\' THEN 'Trade'
                    WHEN account LIKE '%\\_OTHER\\_SERVICES' ESCAPE '\\' THEN 'Other services'
                END AS activity_group,
                100.0 * (policy_level - baseline_level) / nullif(baseline_level, 0.0)
                    AS output_change_percent
            FROM policy_outcomes
            WHERE indicator = 'activity_output_volume_index'
              AND (
                    account LIKE '%\\_BASIC\\_METALS' ESCAPE '\\' OR
                    account LIKE '%\\_METAL\\_COMPONENTS' ESCAPE '\\' OR
                    account LIKE '%\\_OTHER\\_MANUFACTURING' ESCAPE '\\' OR
                    account LIKE '%\\_TRADE' ESCAPE '\\' OR
                    account LIKE '%\\_OTHER\\_SERVICES' ESCAPE '\\'
              )
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, region, activity_group,
            count(*) AS valid_parameter_configurations,
            median(output_change_percent) AS median_output_change_percent,
            quantile_cont(output_change_percent, 0.25) AS lower_quartile_output_change_percent,
            quantile_cont(output_change_percent, 0.75) AS upper_quartile_output_change_percent
        FROM activity_changes
        GROUP BY instrument, wedge, region, activity_group
        ORDER BY instrument, wedge_percent, region, activity_group
    """)
end

"""Summarise regional labour and capital utilisation responses in percentage points."""
function factor_utilisation_evidence(connection)
    return query(connection, """
        WITH factor_changes AS (
            SELECT sensitivity_profile, scenario, instrument, wedge, region,
                CASE
                    WHEN right(factor, 3) = 'LAB' THEN 'Labour'
                    WHEN right(factor, 3) = 'CAP' THEN 'Capital'
                END AS factor_group,
                100.0 * (policy_level - baseline_level) AS utilisation_change_percentage_points
            FROM policy_outcomes
            WHERE indicator = 'regional_factor_utilisation'
        )
        SELECT instrument, abs(wedge) * 100.0 AS wedge_percent, region, factor_group,
            count(*) AS valid_parameter_configurations,
            median(utilisation_change_percentage_points) AS median_utilisation_change_percentage_points,
            quantile_cont(utilisation_change_percentage_points, 0.25)
                AS lower_quartile_utilisation_change_percentage_points,
            quantile_cont(utilisation_change_percentage_points, 0.75)
                AS upper_quartile_utilisation_change_percentage_points
        FROM factor_changes
        GROUP BY instrument, wedge, region, factor_group
        ORDER BY instrument, wedge_percent, region, factor_group
    """)
end

function regional_household_income_figure(table::DataFrame; filename::AbstractString)
    figure = Figure(size=(1200, 900), fontsize=18)
    grid = figure[1, 1] = GridLayout()
    regions = filter(region -> region in unique(table.region), REGION_ORDER)
    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        rows = filter(:instrument => ==(instrument), table)
        sort!(rows, :region, by=region -> findfirst(==(region), regions))
        x = 1:length(regions)
        axis = Axis(grid[position...];
            title=POLICY_LABELS[instrument],
            xlabel="Region",
            ylabel=index in (1, 4) ? "Household-income change\n(million EUR)" : "",
            xticks=(x, regions),
            backgroundcolor=:gray95)
        barplot!(axis, x, rows.median_absolute_change;
            color=POLICY_COLOURS[instrument], strokecolor=:black, strokewidth=0.5)
        lower = rows.median_absolute_change .- rows.lower_quartile_absolute_change
        upper = rows.upper_quartile_absolute_change .- rows.median_absolute_change
        errorbars!(axis, x, rows.median_absolute_change, lower, upper;
            color=:black, whiskerwidth=10, linewidth=2)
        hlines!(axis, [0.0]; color=:black, linewidth=1, linestyle=:dash)
    end
    Label(grid[2, 3], "Bars: median\nWhiskers: interquartile range\nPolicy wedge: 2%",
        tellwidth=false, halign=:center, valign=:center, fontsize=15)
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 14)
    rowgap!(grid, 18)
    save(filename, figure)
    return nothing
end

"""Plot broad-industry output transmission across the six European regions."""
function activity_transmission_figure(table::DataFrame; filename::AbstractString)
    selected = at_evidence_wedge(table)
    activity_groups = TRANSMISSION_ACTIVITY_GROUPS
    regions = filter(region -> region in unique(selected.region), REGION_ORDER)
    colour_limit = maximum(abs, selected.median_output_change_percent)
    colour_limit = max(colour_limit, 0.01)

    figure = Figure(size=(1800, 1200), fontsize=17)
    grid = figure[1, 1] = GridLayout()
    heatmap_plot = nothing
    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        rows = filter(:instrument => ==(instrument), selected)
        values = fill(NaN, length(activity_groups), length(regions))
        for row in eachrow(rows)
            activity_index = findfirst(==(row.activity_group), activity_groups)
            region_index = findfirst(==(row.region), regions)
            values[activity_index, region_index] = row.median_output_change_percent
        end
        axis = Axis(grid[position...];
            title=POLICY_LABELS[instrument],
            xlabel="Industry",
            ylabel=index in (1, 4) ? "Region" : "",
            xlabelsize=13,
            ylabelsize=13,
            xticks=(1:length(activity_groups), activity_groups),
            yticks=(1:length(regions), regions),
            xticklabelrotation=pi / 4,
            yreversed=true,
            backgroundcolor=:gray95)
        heatmap_plot = heatmap!(axis, 1:length(activity_groups), 1:length(regions), values;
            colormap=:PuOr,
            colorrange=(-colour_limit, colour_limit))
    end
    Colorbar(figure[2, 1], heatmap_plot;
        vertical=false,
        label="Median output-volume change (%)",
        labelsize=14,
        ticklabelsize=13)
    rowsize!(grid, 1, Relative(0.46))
    rowsize!(grid, 2, Relative(0.46))
    colgap!(grid, 28)
    rowgap!(grid, 36)
    save(filename, figure)
    return nothing
end

const REGIME_COLOURS = Dict(
    "primary_metal_saving" => colorant"#4C9F8B",
    "parameter_dependent" => colorant"#DFAE50",
    "primary_metal_increase" => colorant"#C95A5A",
)

const REGIME_VALUES = Dict(
    "primary_metal_saving" => 1.0,
    "parameter_dependent" => 2.0,
    "primary_metal_increase" => 3.0,
)

function parameter_axis_label(parameter::AbstractString, axis::AbstractString)
    short = replace(parameter,
        "CET transformation elasticity" => "CET transformation\nelasticity",
        "Circular-service elasticity" => "Circular-service\nelasticity",
        "Metal-substitution elasticity" => "Metal-substitution\nelasticity",
        "Armington elasticity" => "Armington\nelasticity",
    )
    return isempty(axis) ? short : "$(axis): $(short)"
end

function parameter_boundary_figure(table::DataFrame; filename::AbstractString)
    figure = Figure(size=(1200, 900), fontsize=17)
    grid = figure[1, 1] = GridLayout()
    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        rows = filter(:instrument => ==(instrument), table)
        x_values = sort(unique(rows.x_value))
        y_values = sort(unique(rows.y_value))
        x_positions = collect(1:length(x_values))
        y_positions = collect(1:length(y_values))
        regimes = fill(NaN, length(x_values), length(y_values))
        for row in eachrow(rows)
            x_index = findfirst(==(row.x_value), x_values)
            y_index = findfirst(==(row.y_value), y_values)
            regimes[x_index, y_index] = REGIME_VALUES[row.material_outcome_regime]
        end
        axis = Axis(grid[position...];
            title=POLICY_LABELS[instrument],
            xlabel=parameter_axis_label(first(rows.x_parameter), ""),
            ylabel=parameter_axis_label(first(rows.y_parameter), ""),
            xlabelsize=13,
            ylabelsize=13,
            xticks=(x_positions, string.(x_values)),
            yticks=(y_positions, string.(y_values)),
            backgroundcolor=:gray95)
        heatmap!(axis, x_positions, y_positions, regimes;
            colormap=[REGIME_COLOURS["primary_metal_saving"],
                REGIME_COLOURS["parameter_dependent"],
                REGIME_COLOURS["primary_metal_increase"]],
            colorrange=(0.5, 3.5))
    end
    displayed_regimes = [
        regime for regime in ("primary_metal_saving", "parameter_dependent",
            "primary_metal_increase") if any(table.material_outcome_regime .== regime)
    ]
    legend_elements = [PolyElement(color=REGIME_COLOURS[regime])
        for regime in displayed_regimes]
    legend_labels = Dict(
        "primary_metal_saving" => "Saving for all remaining settings",
        "parameter_dependent" => "Saving or increase, depending on remaining settings",
        "primary_metal_increase" => "Increase for all remaining settings",
    )
    Legend(grid[2, 3], legend_elements, [legend_labels[regime] for regime in displayed_regimes];
        tellwidth=false, halign=:center, valign=:center, labelsize=14)
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 14)
    rowgap!(grid, 18)
    save(filename, figure)
    return nothing
end

"""Plot primary-metal saving against each policy's most influential condition."""
function policy_condition_response_figure(table::DataFrame; filename::AbstractString)
    figure = Figure(size=(1800, 1200), fontsize=17)
    grid = figure[1, 1] = GridLayout()
    panel_rows = Dict{String, DataFrame}()
    for instrument in POLICY_ORDER
        parameter = KEY_POLICY_CONDITIONS[instrument]
        rows = filter(row -> row.instrument == instrument &&
            row.wedge_percent == EVIDENCE_WEDGE_PERCENT && row.parameter == parameter,
            table)
        sort!(rows, :value)
        panel_rows[instrument] = rows
    end
    lower = min(0.0, minimum(minimum(rows.lower_quartile_reduction_tonnes)
        for rows in values(panel_rows)))
    upper = maximum(maximum(rows.upper_quartile_reduction_tonnes)
        for rows in values(panel_rows))
    padding = 0.05 * (upper - lower)
    ylimits = (lower - padding, upper + padding)

    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        parameter = KEY_POLICY_CONDITIONS[instrument]
        rows = panel_rows[instrument]
        axis = Axis(grid[position...];
            title=POLICY_LABELS[instrument],
            xlabel=parameter_axis_label(parameter, ""),
            ylabel="Primary-metal saving (t)",
            xlabelsize=13,
            ylabelsize=13,
            xticks=(rows.value, string.(rows.value)),
            backgroundcolor=:gray95)
        band!(axis, rows.value, rows.lower_quartile_reduction_tonnes,
            rows.upper_quartile_reduction_tonnes;
            color=(POLICY_COLOURS[instrument], 0.25))
        lines!(axis, rows.value, rows.median_reduction_tonnes;
            color=POLICY_COLOURS[instrument], linewidth=3)
        scatter!(axis, rows.value, rows.median_reduction_tonnes;
            color=POLICY_COLOURS[instrument], markersize=10)
        hlines!(axis, [0.0]; color=:black, linewidth=1, linestyle=:dash)
        ylims!(axis, ylimits...)
    end
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 36)
    rowgap!(grid, 40)
    save(filename, figure)
    return nothing
end

"""Plot primary-metal saving against the absolute policy-wedge magnitude."""
function policy_intensity_response_figure(table::DataFrame; filename::AbstractString)
    selected = filter(row -> row.parameter == KEY_POLICY_CONDITIONS[row.instrument],
        table)
    lower = min(0.0, minimum(selected.lower_quartile_reduction_tonnes))
    upper = maximum(selected.upper_quartile_reduction_tonnes)
    padding = 0.05 * (upper - lower)
    ylimits = (lower - padding, upper + padding)

    figure = Figure(size=(1800, 1200), fontsize=17)
    grid = figure[1, 1] = GridLayout()
    for (index, instrument) in enumerate(POLICY_ORDER)
        position = index <= 3 ? (1, index) : (2, index - 3)
        parameter = KEY_POLICY_CONDITIONS[instrument]
        axis = Axis(grid[position...];
            title="$(POLICY_LABELS[instrument])\n$(parameter_axis_label(parameter, ""))",
            xlabel="Policy wedge (%)",
            ylabel="Primary-metal saving (t)",
            xlabelsize=13,
            ylabelsize=13,
            xticks=([0.0, 0.25, 0.5, 1.0, 2.0], ["0", "0.25", "0.5", "1", "2"]),
            backgroundcolor=:gray95)
        for value in CONDITION_RESPONSE_VALUES
            rows = filter(row -> row.instrument == instrument &&
                row.parameter == parameter && row.value == value, table)
            sort!(rows, :wedge_percent)
            wedges = vcat(0.0, rows.wedge_percent)
            medians = vcat(0.0, rows.median_reduction_tonnes)
            lower_quartiles = vcat(0.0, rows.lower_quartile_reduction_tonnes)
            upper_quartiles = vcat(0.0, rows.upper_quartile_reduction_tonnes)
            colour = CONDITION_RESPONSE_COLOURS[value]
            band!(axis, wedges, lower_quartiles, upper_quartiles; color=(colour, 0.14))
            lines!(axis, wedges, medians; color=colour, linewidth=3)
            scatter!(axis, wedges, medians; color=colour, markersize=8)
        end
        hlines!(axis, [0.0]; color=:black, linewidth=1, linestyle=:dash)
        ylims!(axis, ylimits...)
    end
    legend_elements = [LineElement(color=CONDITION_RESPONSE_COLOURS[value],
        linewidth=3) for value in CONDITION_RESPONSE_VALUES]
    Legend(grid[2, 3], legend_elements,
        ["Condition value: $(value)" for value in CONDITION_RESPONSE_VALUES];
        tellwidth=false, halign=:center, valign=:center, labelsize=14)
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 36)
    rowgap!(grid, 40)
    save(filename, figure)
    return nothing
end

function formatted(value; digits::Int=2)
    return string(round(Float64(value), digits=digits))
end

latex_number(value; digits::Int=1) = string(round(Float64(value), digits=digits))

function latex_interval(median, lower, upper; digits::Int=1)
    return "$(latex_number(median; digits=digits)) [$(latex_number(lower; digits=digits)), " *
        "$(latex_number(upper; digits=digits))]"
end

function latex_value_with_iqr(median, lower, upper; digits::Int=1)
    value = latex_number(median; digits=digits)
    interval = "[$(latex_number(lower; digits=digits)), $(latex_number(upper; digits=digits))]"
    return "\\shortstack[r]{$(value) \\\\ \\mbox{$(interval)}}"
end

function _table_row(table::DataFrame, predicate)
    return only(eachrow(filter(predicate, table)))
end

function write_material_fiscal_table(path::AbstractString, primary::DataFrame, fiscal::DataFrame)
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Primary-metal outcome and fiscal scale at a 2\\% policy wedge. The first line reports the median and the second line the interquartile range across the declared sensitivity design. Fiscal flow is tax revenue for the tax and support expenditure for support instruments.}")
        println(io, "\\label{tab:policy-material-fiscal}")
        println(io, "\\begin{tabular}{@{}>{\\raggedright\\arraybackslash}m{0.22\\textwidth}>{\\raggedleft\\arraybackslash}m{0.23\\textwidth}>{\\raggedright\\arraybackslash}m{0.20\\textwidth}>{\\raggedleft\\arraybackslash}m{0.28\\textwidth}@{}}")
        println(io, "\\hline")
        println(io, "Intervention & Primary-metal saving (t) & Fiscal basis & Fiscal flow (million EUR) \\\\")
        println(io, "\\hline")
        for instrument in POLICY_ORDER
            material = _table_row(primary, row -> row.instrument == instrument &&
                row.wedge_percent == EVIDENCE_WEDGE_PERCENT)
            flow = _table_row(fiscal, row -> row.instrument == instrument &&
                row.wedge_percent == EVIDENCE_WEDGE_PERCENT)
            fiscal_basis = instrument == "virgin_metal_tax" ? "Tax revenue" : "Support expenditure"
            println(io, "$(POLICY_LABELS[instrument]) & " *
                "$(latex_value_with_iqr(material.median_reduction_tonnes, material.lower_quartile_reduction_tonnes, material.upper_quartile_reduction_tonnes)) & " *
                "$(fiscal_basis) & " *
                "$(latex_value_with_iqr(flow.median_fiscal_basis_million_eur, flow.lower_quartile_fiscal_basis_million_eur, flow.upper_quartile_fiscal_basis_million_eur)) \\\\")
            instrument == last(POLICY_ORDER) || println(io, "\\lightrule")
        end
        println(io, "\\hline")
        println(io, "\\end{tabular}")
        println(io, "\\end{table}")
    end
    return nothing
end

function write_support_efficiency_table(path::AbstractString, efficiency::DataFrame)
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Primary-metal saving per million euro of support expenditure at a 2\\% support wedge. Brackets give the interquartile range across the sensitivity design.}")
        println(io, "\\label{tab:policy-support-efficiency}")
        println(io, "\\begin{tabularx}{0.72\\textwidth}{>{\\raggedright\\arraybackslash}X>{\\raggedleft\\arraybackslash}p{0.34\\textwidth}}")
        println(io, "\\hline")
        println(io, "Support instrument & Primary-metal saving (t per million EUR) \\\\")
        println(io, "\\hline")
        support_instruments = filter(!=("virgin_metal_tax"), POLICY_ORDER)
        for instrument in support_instruments
            row = _table_row(efficiency, row -> row.instrument == instrument &&
                row.wedge_percent == EVIDENCE_WEDGE_PERCENT)
            println(io, "$(POLICY_LABELS[instrument]) & " *
                "$(latex_interval(row.median_tonnes_per_million_eur, row.lower_quartile_tonnes_per_million_eur, row.upper_quartile_tonnes_per_million_eur)) \\\\")
            instrument == last(support_instruments) || println(io, "\\lightrule")
        end
        println(io, "\\hline")
        println(io, "\\end{tabularx}")
        println(io, "\\end{table}")
    end
    return nothing
end

function write_new_product_displacement_table(path::AbstractString,
    avoided_new_products::DataFrame)
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Displacement of new product output and its metal inputs under life-extension and reuse support at a 2\\% wedge. Positive values denote lower new-product output or lower metal use in new production relative to the matching zero-policy solution. Brackets give the interquartile range across the sensitivity design.}")
        println(io, "\\label{tab:new-product-displacement}")
        println(io, "\\begin{tabularx}{\\textwidth}{>{\\raggedright\\arraybackslash}p{0.15\\textwidth}>{\\raggedright\\arraybackslash}p{0.11\\textwidth}>{\\raggedleft\\arraybackslash}p{0.24\\textwidth}>{\\raggedleft\\arraybackslash}p{0.24\\textwidth}>{\\raggedleft\\arraybackslash}X}")
        println(io, "\\hline")
        println(io, "Support & Product family & Avoided new-product output (t) & Avoided primary METAL use in new production (t) & Avoided recycled METAL use in new production (t) \\\\")
        println(io, "\\hline")
        families = ["ELMA", "OFMA", "RATV"]
        instruments = ["refurbishment_support", "repair_support", "reuse_support"]
        for (instrument_index, instrument) in enumerate(instruments)
            for (family_index, family) in enumerate(families)
                avoided = _table_row(avoided_new_products, row ->
                    row.instrument == instrument &&
                    row.wedge_percent == EVIDENCE_WEDGE_PERCENT && row.family == family)
                support = family_index == 1 ? POLICY_LABELS[instrument] : ""
                println(io, "$(support) & $(family) & " *
                    "$(latex_interval(avoided.median_avoided_new_product_tonnes, avoided.lower_quartile_avoided_new_product_tonnes, avoided.upper_quartile_avoided_new_product_tonnes)) & " *
                    "$(latex_interval(avoided.median_avoided_new_product_primary_metal_tonnes, avoided.lower_quartile_avoided_new_product_primary_metal_tonnes, avoided.upper_quartile_avoided_new_product_primary_metal_tonnes)) & " *
                    "$(latex_interval(avoided.median_avoided_new_product_recycled_metal_tonnes, avoided.lower_quartile_avoided_new_product_recycled_metal_tonnes, avoided.upper_quartile_avoided_new_product_recycled_metal_tonnes; digits=2)) \\\\")
                family_index == length(families) && instrument_index < length(instruments) ?
                    println(io, "\\lightrule") : nothing
            end
        end
        println(io, "\\hline")
        println(io, "\\end{tabularx}")
        println(io, "\\end{table}")
    end
    return nothing
end

function write_household_incidence_table(path::AbstractString, income::DataFrame)
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Median change in regional household disposable income at a 2\\% policy wedge (million EUR). Values are reported by policy and region; the accompanying figure reports interquartile ranges.}")
        println(io, "\\label{tab:regional-household-incidence}")
        println(io, "\\begin{tabularx}{\\textwidth}{>{\\raggedright\\arraybackslash}p{0.12\\textwidth}>{\\raggedleft\\arraybackslash}p{0.176\\textwidth}>{\\raggedleft\\arraybackslash}p{0.176\\textwidth}>{\\raggedleft\\arraybackslash}p{0.176\\textwidth}>{\\raggedleft\\arraybackslash}p{0.176\\textwidth}>{\\raggedleft\\arraybackslash}X}")
        println(io, "\\hline")
        println(io, "Region & Virgin-metal tax & Recycling support & Refurbishment support & Repair support & Reuse support \\\\")
        println(io, "\\hline")
        for region in REGION_ORDER
            values = String[]
            for instrument in POLICY_ORDER
                row = _table_row(income, row -> row.region == region && row.instrument == instrument)
                push!(values, latex_number(row.median_absolute_change))
            end
            println(io, "$(region) & $(join(values, " & ")) \\\\")
            region == last(REGION_ORDER) || println(io, "\\lightrule")
        end
        println(io, "\\hline")
        println(io, "\\end{tabularx}")
        println(io, "\\end{table}")
    end
    return nothing
end

function write_article_result_tables(primary::DataFrame, fiscal::DataFrame, efficiency::DataFrame,
    avoided_new_products::DataFrame, income::DataFrame)
    generated = joinpath(ROOT_DIR, "article", "generated")
    isdir(generated) || error("Article generated-table directory is missing: $(generated)")
    write_material_fiscal_table(joinpath(generated, "policy_material_fiscal.tex"), primary, fiscal)
    write_support_efficiency_table(joinpath(generated, "policy_support_efficiency.tex"), efficiency)
    write_new_product_displacement_table(joinpath(generated, "policy_new_product_displacement.tex"),
        avoided_new_products)
    write_household_incidence_table(joinpath(generated, "policy_household_incidence.tex"), income)
    return nothing
end

function main()
    options = command_options(ARGS)
    isfile(options.database) || error("Outcome database is missing: $(options.database)")
    options.dry_run && error("Evidence reports require a policy-outcome database.")
    mkpath(options.output_dir)
    article_figure_dir = joinpath(ROOT_DIR, "article", "figures")
    isdir(article_figure_dir) || error("Article figure directory is missing: $(article_figure_dir)")
    database = DuckDB.DB(options.database; readonly=true)
    connection = DBInterface.connect(database)
    try
        primary = policy_primary_metal_summary(connection)
        fiscal = policy_fiscal_summary(connection)
        efficiency = policy_support_efficiency_summary(connection)
        avoided_new_products = policy_avoided_new_product_summary(connection)
        routes = policy_circular_route_total_summary(connection)
        activity = policy_activity_summary(connection)
        incidence = policy_incidence_summary(connection)
        activity_transmission = activity_transmission_evidence(connection)
        factor_utilisation = factor_utilisation_evidence(connection)
        parameter_sensitivity = primary_metal_parameter_sensitivity(connection)
        pair_summary = primary_metal_parameter_pair_summary(connection)
        mechanism_evidence = route_mechanism_evidence(routes, activity)
        income_evidence = household_income_evidence(incidence)
        boundary_evidence = selected_boundary_evidence(pair_summary)
        CSV.write(joinpath(options.output_dir, "policy_route_mechanism_evidence.csv"), mechanism_evidence)
        CSV.write(joinpath(options.output_dir, "policy_household_incidence_evidence.csv"), income_evidence)
        CSV.write(joinpath(options.output_dir, "policy_activity_transmission_evidence.csv"),
            activity_transmission)
        CSV.write(joinpath(options.output_dir, "policy_factor_utilisation_evidence.csv"),
            factor_utilisation)
        CSV.write(joinpath(options.output_dir, "policy_parameter_boundary_evidence.csv"), boundary_evidence)
        regional_household_income_figure(income_evidence;
            filename=joinpath(options.output_dir, "policy_household_incidence.pdf"))
        regional_household_income_figure(income_evidence;
            filename=joinpath(article_figure_dir, "policy_household_incidence.pdf"))
        activity_transmission_figure(activity_transmission;
            filename=joinpath(options.output_dir, "policy_activity_transmission.pdf"))
        activity_transmission_figure(activity_transmission;
            filename=joinpath(article_figure_dir, "policy_activity_transmission.pdf"))
        parameter_boundary_figure(boundary_evidence;
            filename=joinpath(options.output_dir, "policy_parameter_boundaries.pdf"))
        parameter_boundary_figure(boundary_evidence;
            filename=joinpath(article_figure_dir, "policy_validity_conditions.pdf"))
        for wedge_percent in (0.25, 0.5, 1.0)
            wedge_evidence = selected_boundary_evidence(pair_summary;
                wedge_percent=wedge_percent)
            parameter_boundary_figure(wedge_evidence;
                filename=joinpath(article_figure_dir,
                    "policy_validity_conditions_$(wedge_slug(wedge_percent)).pdf"))
        end
        policy_condition_response_figure(parameter_sensitivity;
            filename=joinpath(options.output_dir, "policy_condition_response.pdf"))
        policy_condition_response_figure(parameter_sensitivity;
            filename=joinpath(article_figure_dir, "policy_condition_response.pdf"))
        policy_intensity_response_figure(parameter_sensitivity;
            filename=joinpath(options.output_dir, "policy_intensity_response.pdf"))
        policy_intensity_response_figure(parameter_sensitivity;
            filename=joinpath(article_figure_dir, "policy_intensity_response.pdf"))
        write_article_result_tables(primary, fiscal, efficiency, avoided_new_products,
            income_evidence)
        println("Article result tables: ", joinpath(ROOT_DIR, "article", "generated"))
        println("Route-mechanism evidence rows: ", nrow(mechanism_evidence))
        println("Household-incidence evidence rows: ", nrow(income_evidence))
        println("Activity-transmission evidence rows: ", nrow(activity_transmission))
        println("Factor-utilisation evidence rows: ", nrow(factor_utilisation))
        println("Parameter-boundary evidence rows: ", nrow(boundary_evidence))
        println("Article figures: ", article_figure_dir)
    finally
        DBInterface.close!(connection)
        close(database)
    end
    return nothing
end

main()
