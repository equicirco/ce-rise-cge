#!/usr/bin/env julia

"""
Generate the supplementary calibration-period trade-exposure table.

The table aggregates sales in the six-region trade registry into the product
groups used to define the common-EU and regional-market closures. It reports
the shares of sales from European producers delivered to another modelled
European region and exported outside Europe.
"""

using CSV
using DataFrames
using Printf

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const TRADE_REGISTRY = joinpath(
    ROOT_DIR, "data", "artifacts", "08_six_region_bundle", "regional_trade_registry.tsv",
)
const OUTPUT = joinpath(ROOT_DIR, "article", "generated", "si_trade_exposure.tex")

const EUROPEAN_REGIONS = Set(["DE", "FR", "IT", "PL", "SK", "REU"])

const PRODUCT_GROUPS = [
    ("Agriculture and food", ["AGRI_FOOD"], "Common EU market"),
    ("Extractive industries", ["EXTRACTIVE"], "Common EU market"),
    ("Basic metals", ["BASIC_METALS"], "Common EU market"),
    ("Metal components", ["METAL_COMPONENTS"], "Common EU market"),
    ("New electronics", ["NEW_ELMA", "NEW_OFMA", "NEW_RATV"], "Common EU market"),
    ("Other manufacturing", ["OTHER_MANUFACTURING"], "Common EU market"),
    ("Repair, refurbishment, and reuse", [
        "REP_ELMA", "REP_OFMA", "REP_RATV",
        "REF_ELMA", "REF_OFMA", "REF_RATV",
        "REU_ELMA", "REU_OFMA", "REU_RATV",
    ], "Regional market; EU balance fixed"),
    ("Terminal treatment", ["REC_EE", "INC_EE"], "Regional market; EU balance fixed"),
    ("Construction, utilities, and waste", ["CONSTRUCTION", "UTIL_WASTE"], "Regional market; EU balance fixed"),
    ("Trade and transport", ["TRADE", "TRANSPORT"], "Regional market; EU balance fixed"),
    ("Other and public services", ["OTHER_SERVICES", "PUBLIC_SOCIAL"], "Regional market; EU balance fixed"),
]

function percent(value::Float64, total::Float64)
    total > 0.0 || error("Trade-exposure total must be positive.")
    return @sprintf("%.1f\\%%", 100.0 * value / total)
end

function write_table(path::AbstractString, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "\\begin{table}[htbp]")
        println(io, "\\centering")
        println(io, "\\footnotesize")
        println(io, "\\caption{Calibration-period trade exposure and market treatment by industry group. Shares are calculated from sales by producers in the six modelled European regions. Intra-European sales exclude sales within the producer's own region.}")
        println(io, "\\label{tab:si-trade-exposure}")
        println(io, "\\begin{tabularx}{\\textwidth}{>{\\raggedright\\arraybackslash}p{0.29\\textwidth}>{\\raggedleft\\arraybackslash}p{0.15\\textwidth}>{\\raggedleft\\arraybackslash}p{0.15\\textwidth}>{\\raggedright\\arraybackslash}X}")
        println(io, "\\hline")
        println(io, "Industry group & Intra-European sales & Extra-European exports & Model market treatment \\\\")
        println(io, "\\hline")
        for (index, row) in enumerate(rows)
            println(io, "$(row.name) & $(row.intra_eu) & $(row.extra_eu) & $(row.treatment) \\\\")
            index == length(rows) || println(io, "\\lightrule")
        end
        println(io, "\\hline")
        println(io, "\\end{tabularx}")
        println(io, "\\end{table}")
    end
end

function main()
    isfile(TRADE_REGISTRY) || error("Trade registry is missing: $(TRADE_REGISTRY)")
    data = CSV.read(TRADE_REGISTRY, DataFrame; delim='\t')
    required = [:product, :origin, :destination, :marketed_value_meur]
    all(String(name) in names(data) for name in required) ||
        error("Trade registry does not contain the required columns.")

    grouped_products = reduce(vcat, (products for (_, products, _) in PRODUCT_GROUPS))
    length(grouped_products) == length(unique(grouped_products)) ||
        error("A product appears in more than one trade-exposure group.")
    Set(grouped_products) == Set(data.product) ||
        error("Trade-exposure groups do not cover the product registry exactly.")

    rows = NamedTuple[]
    for (name, products, treatment) in PRODUCT_GROUPS
        subset = filter(row -> row.product in products && row.origin in EUROPEAN_REGIONS,
            data)
        total = sum(subset.marketed_value_meur)
        intra_eu = sum(row.marketed_value_meur for row in eachrow(subset)
            if row.destination in EUROPEAN_REGIONS && row.origin != row.destination)
        extra_eu = sum(row.marketed_value_meur for row in eachrow(subset)
            if row.destination == "ROW")
        push!(rows, (
            name = name,
            intra_eu = percent(intra_eu, total),
            extra_eu = percent(extra_eu, total),
            treatment = treatment,
        ))
    end

    write_table(OUTPUT, rows)
    println("Wrote ", OUTPUT)
end

main()
