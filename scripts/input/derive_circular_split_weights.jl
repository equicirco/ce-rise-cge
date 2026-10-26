#!/usr/bin/env julia

"""
Derive split weights for circular parent sectors and circular route categories.

This script converts the previously extracted monetary and physical summaries
into normalized weights that can be used in the next SUT construction step.
"""

include(joinpath(@__DIR__, "discarded_equipment_treatment.jl"))
using .DiscardedEquipmentTreatment

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const STRUCTURE_DIR = joinpath(ROOT_DIR, "data", "interim", "structure")

const PARENT_USE_FILE = joinpath(STRUCTURE_DIR, "circular_parent_use_by_family.tsv")

const OUT_PARENT_SHARES = joinpath(STRUCTURE_DIR, "circular_parent_family_shares.tsv")
const OUT_ROUTE_SHARES = joinpath(STRUCTURE_DIR, "discarded_equipment_treatment_shares.tsv")

function read_tsv(path::AbstractString)
    rows = Vector{Vector{String}}()
    open(path, "r") do io
        for line in eachline(io)
            isempty(line) && continue
            push!(rows, split(line, '\t'))
        end
    end
    return rows
end

function write_tsv(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(header, '\t'))
        for row in rows
            println(io, join(row, '\t'))
        end
    end
end

function derive_parent_family_shares()
    rows = read_tsv(PARENT_USE_FILE)
    totals = Dict{Tuple{String,String},Float64}()
    detail = Vector{NamedTuple}()

    for row in rows[2:end]
        use_region, ce_rise_parent, ce_rise_parent_label, product_code, product_label, role_id, total_use_str, domestic_use_str, imported_use_str = row
        total_use = parse(Float64, total_use_str)
        domestic_use = parse(Float64, domestic_use_str)
        imported_use = parse(Float64, imported_use_str)
        key = (use_region, product_code)
        totals[key] = get(totals, key, 0.0) + total_use
        push!(detail, (
            use_region = use_region,
            ce_rise_parent = ce_rise_parent,
            ce_rise_parent_label = ce_rise_parent_label,
            product_code = product_code,
            product_label = product_label,
            role_id = role_id,
            total_use = total_use,
            domestic_use = domestic_use,
            imported_use = imported_use,
        ))
    end

    out_rows = Vector{Vector{String}}()
    for row in sort(detail, by = x -> (x.use_region, x.product_code, x.ce_rise_parent))
        denominator = totals[(row.use_region, row.product_code)]
        share = denominator == 0.0 ? 0.0 : row.total_use / denominator
        push!(out_rows, [
            row.use_region,
            row.ce_rise_parent,
            row.ce_rise_parent_label,
            row.product_code,
            row.product_label,
            row.role_id,
            string(row.total_use),
            string(row.domestic_use),
            string(row.imported_use),
            string(share),
        ])
    end

    write_tsv(
        OUT_PARENT_SHARES,
        [
            "use_region",
            "ce_rise_parent",
            "ce_rise_parent_label",
            "product_code",
            "product_label",
            "role_id",
            "total_use_meur",
            "domestic_use_meur",
            "imported_use_meur",
            "family_share_within_product",
        ],
        out_rows,
    )
end

function derive_route_category_shares()
    write_treatment_shares(OUT_ROUTE_SHARES, treatment_shares())
end

function main()
    derive_parent_family_shares()
    derive_route_category_shares()
    println("Wrote:")
    println("  ", OUT_PARENT_SHARES)
    println("  ", OUT_ROUTE_SHARES)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
