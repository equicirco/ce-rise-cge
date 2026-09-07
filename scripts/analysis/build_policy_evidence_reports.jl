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

const REGION_ORDER = ["DE", "FR", "IT", "PL", "REU", "SK"]

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

function selected_boundary_evidence(pair_summary::DataFrame)
    selected = DataFrame()
    for instrument in POLICY_ORDER
        x_parameter, y_parameter = EVIDENCE_PARAMETER_PAIRS[instrument]
        rows = filter(row ->
            row.instrument == instrument &&
            row.wedge_percent == EVIDENCE_WEDGE_PERCENT &&
            row.x_parameter == x_parameter &&
            row.y_parameter == y_parameter,
            pair_summary)
        append!(selected, rows)
    end
    sort!(selected, [:instrument, :x_value, :y_value])
    return selected
end

function household_income_evidence(incidence::DataFrame)
    selected = filter(row ->
        row.wedge_percent == EVIDENCE_WEDGE_PERCENT &&
        row.outcome == "Household disposable income",
        incidence)
    sort!(selected, [:instrument, :region])
    return selected
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
    return "$(axis): $(short)"
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
            xlabel=parameter_axis_label(first(rows.x_parameter), "x"),
            ylabel=parameter_axis_label(first(rows.y_parameter), "y"),
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
    legend_elements = [
        PolyElement(color=REGIME_COLOURS["primary_metal_saving"]),
        PolyElement(color=REGIME_COLOURS["parameter_dependent"]),
        PolyElement(color=REGIME_COLOURS["primary_metal_increase"]),
    ]
    Legend(grid[2, 3], legend_elements,
        ["Saving for all remaining settings", "Depends on remaining settings",
            "Increase for all remaining settings"];
        tellwidth=false, halign=:center, valign=:center, labelsize=14)
    rowsize!(grid, 1, Relative(0.5))
    rowsize!(grid, 2, Relative(0.5))
    colgap!(grid, 14)
    rowgap!(grid, 18)
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

function _table_row(table::DataFrame, predicate)
    return only(eachrow(filter(predicate, table)))
end

function write_material_fiscal_table(path::AbstractString, primary::DataFrame, fiscal::DataFrame)
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Primary-metal outcome and fiscal scale at a 2\\% policy wedge. Brackets give the interquartile range across the declared sensitivity design. Fiscal flow is tax revenue for the tax and support expenditure for support instruments.}")
        println(io, "\\label{tab:policy-material-fiscal}")
        println(io, "\\begin{tabularx}{\\textwidth}{>{\\raggedright\\arraybackslash}p{0.25\\textwidth}>{\\raggedleft\\arraybackslash}p{0.25\\textwidth}>{\\raggedright\\arraybackslash}p{0.18\\textwidth}>{\\raggedleft\\arraybackslash}X}")
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
                "$(latex_interval(material.median_reduction_tonnes, material.lower_quartile_reduction_tonnes, material.upper_quartile_reduction_tonnes)) & " *
                "$(fiscal_basis) & " *
                "$(latex_interval(flow.median_fiscal_basis_million_eur, flow.lower_quartile_fiscal_basis_million_eur, flow.upper_quartile_fiscal_basis_million_eur)) \\\\")
            instrument == last(POLICY_ORDER) || println(io, "\\lightrule")
        end
        println(io, "\\hline")
        println(io, "\\end{tabularx}")
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

function write_refurbishment_substitution_table(path::AbstractString,
    avoided_new_products::DataFrame, refurbishment_metal_demand::DataFrame)
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Refurbishment-support substitution evidence at a 2\\% wedge. Positive avoided new-product output denotes lower new output relative to the matching zero-policy solution; a positive METAL value denotes higher input demand in the refurbishment route. Brackets give the interquartile range across the sensitivity design.}")
        println(io, "\\label{tab:refurbishment-substitution}")
        println(io, "\\begin{tabularx}{\\textwidth}{>{\\raggedright\\arraybackslash}p{0.16\\textwidth}>{\\raggedleft\\arraybackslash}p{0.28\\textwidth}>{\\raggedleft\\arraybackslash}p{0.28\\textwidth}>{\\raggedleft\\arraybackslash}X}")
        println(io, "\\hline")
        println(io, "Product family & Avoided new-product output (t) & Primary METAL demand in refurbishment (t) & Recycled METAL demand in refurbishment (t) \\\\")
        println(io, "\\hline")
        families = ["ELMA", "OFMA", "RATV"]
        for family in families
            avoided = _table_row(avoided_new_products, row ->
                row.instrument == "refurbishment_support" &&
                row.wedge_percent == EVIDENCE_WEDGE_PERCENT && row.family == family)
            primary = _table_row(refurbishment_metal_demand, row ->
                row.wedge_percent == EVIDENCE_WEDGE_PERCENT && row.family == family && row.material == "primary")
            recycled = _table_row(refurbishment_metal_demand, row ->
                row.wedge_percent == EVIDENCE_WEDGE_PERCENT && row.family == family && row.material == "recycled")
            println(io, "$(family) & " *
                "$(latex_interval(avoided.median_avoided_new_product_tonnes, avoided.lower_quartile_avoided_new_product_tonnes, avoided.upper_quartile_avoided_new_product_tonnes)) & " *
                "$(latex_interval(primary.median_metal_demand_change_tonnes, primary.lower_quartile_metal_demand_change_tonnes, primary.upper_quartile_metal_demand_change_tonnes)) & " *
                "$(latex_interval(recycled.median_metal_demand_change_tonnes, recycled.lower_quartile_metal_demand_change_tonnes, recycled.upper_quartile_metal_demand_change_tonnes; digits=2)) \\\\")
            family == last(families) || println(io, "\\lightrule")
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
    avoided_new_products::DataFrame, refurbishment_metal_demand::DataFrame, income::DataFrame)
    generated = joinpath(ROOT_DIR, "article", "generated")
    isdir(generated) || error("Article generated-table directory is missing: $(generated)")
    write_material_fiscal_table(joinpath(generated, "policy_material_fiscal.tex"), primary, fiscal)
    write_support_efficiency_table(joinpath(generated, "policy_support_efficiency.tex"), efficiency)
    write_refurbishment_substitution_table(joinpath(generated, "policy_refurbishment_substitution.tex"),
        avoided_new_products, refurbishment_metal_demand)
    write_household_incidence_table(joinpath(generated, "policy_household_incidence.tex"), income)
    return nothing
end

function main()
    options = command_options(ARGS)
    isfile(options.database) || error("Outcome database is missing: $(options.database)")
    options.dry_run && error("Evidence reports require a policy-outcome database.")
    mkpath(options.output_dir)
    database = DuckDB.DB(options.database)
    connection = DBInterface.connect(database)
    try
        primary = policy_primary_metal_summary(connection)
        fiscal = policy_fiscal_summary(connection)
        efficiency = policy_support_efficiency_summary(connection)
        avoided_new_products = policy_avoided_new_product_summary(connection)
        refurbishment_metal_demand = refurbishment_metal_demand_summary(connection)
        routes = policy_circular_route_total_summary(connection)
        activity = policy_activity_summary(connection)
        incidence = policy_incidence_summary(connection)
        pair_summary = primary_metal_parameter_pair_summary(connection)
        mechanism_evidence = route_mechanism_evidence(routes, activity)
        income_evidence = household_income_evidence(incidence)
        boundary_evidence = selected_boundary_evidence(pair_summary)
        CSV.write(joinpath(options.output_dir, "policy_route_mechanism_evidence.csv"), mechanism_evidence)
        CSV.write(joinpath(options.output_dir, "policy_household_incidence_evidence.csv"), income_evidence)
        CSV.write(joinpath(options.output_dir, "policy_parameter_boundary_evidence.csv"), boundary_evidence)
        regional_household_income_figure(income_evidence;
            filename=joinpath(options.output_dir, "policy_household_incidence.pdf"))
        parameter_boundary_figure(boundary_evidence;
            filename=joinpath(options.output_dir, "policy_parameter_boundaries.pdf"))
        write_article_result_tables(primary, fiscal, efficiency, avoided_new_products,
            refurbishment_metal_demand, income_evidence)
        println("Article result tables: ", joinpath(ROOT_DIR, "article", "generated"))
        println("Route-mechanism evidence rows: ", nrow(mechanism_evidence))
        println("Household-incidence evidence rows: ", nrow(income_evidence))
        println("Parameter-boundary evidence rows: ", nrow(boundary_evidence))
    finally
        DBInterface.close!(connection)
        close(database)
    end
    return nothing
end

main()
