#!/usr/bin/env julia

"""
Map the CE-RISE parent sectors onto the regional FIGARO 2016 base SUT.

This step does three things:
1. loads the CE-RISE parent -> FIGARO parent mapping,
2. aggregates the disaggregation overlay to the working regions
   (DE, FR, PL, IT, SK, ROW),
3. extracts the base FIGARO supply/use slices needed for the later
   sector split and balancing step.

The important economic point is that:
- A_ELMA maps to FIGARO C27 / CPA_C27
- A_OFMA and A_RATV both map to FIGARO C26 / CPA_C26

So C26 is a shared FIGARO parent that must later be split between OFMA,
RATV, and the remaining residual part using the CE-RISE overlay.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")
const MAP_DIR = joinpath(ROOT_DIR, "data", "mappings")

const REGION_MAP_FILE = joinpath(MAP_DIR, "figaro_region_map.tsv")
const PARENT_MAP_FILE = joinpath(MAP_DIR, "ce_rise_parent_to_figaro.tsv")

const SUPPLY_FILE = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const USE_FILE = joinpath(SUT_DIR, "sut_use_base_2016.tsv")
const OVERLAY_FILE = joinpath(SUT_DIR, "sut_disaggregation_overlay.tsv")

const OUT_PARENT_MAP = joinpath(SUT_DIR, "sut_parent_figaro_map.tsv")
const OUT_OVERLAY_REGIONS = joinpath(SUT_DIR, "sut_disaggregation_overlay_regions.tsv")
const OUT_TARGET_SUPPLY = joinpath(SUT_DIR, "sut_figaro_target_supply.tsv")
const OUT_TARGET_USE = joinpath(SUT_DIR, "sut_figaro_target_use.tsv")
const OUT_TARGET_GROUPS = joinpath(SUT_DIR, "sut_figaro_target_groups.tsv")

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

function load_simple_map(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    data = rows[2:end]
    return header, data
end

function kept_region(code::AbstractString)
    code in ("DE", "FR", "PL", "IT", "SK") && return code
    return "ROW"
end

function load_parent_map(path::AbstractString)
    _, rows = load_simple_map(path)
    mapping = Dict{String, NamedTuple}()
    for row in rows
        mapping[row[1]] = (
            product_code = row[2],
            activity_code = row[3],
            shared_group = row[4],
        )
    end
    return mapping
end

function write_parent_map_copy(parent_map)
    rows = Vector{Vector{String}}()
    for parent in sort(collect(keys(parent_map)))
        entry = parent_map[parent]
        push!(rows, [parent, entry.product_code, entry.activity_code, entry.shared_group])
    end
    write_tsv(
        OUT_PARENT_MAP,
        ["ce_rise_parent", "figaro_product_code", "figaro_activity_code", "shared_parent_group"],
        rows,
    )
end

function aggregate_overlay_by_regions()
    rows = read_tsv(OVERLAY_FILE)
    data = rows[2:end]
    totals = Dict{NTuple{6, String}, Float64}()
    for row in data
        from_region = kept_region(row[1])
        from_node = row[2]
        to_region = kept_region(row[3])
        to_node = row[4]
        unit = row[5]
        value = parse(Float64, row[6])
        key = (from_region, from_node, to_region, to_node, unit, "")
        totals[key] = get(totals, key, 0.0) + value
    end

    out_rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(totals)))
        push!(out_rows, [key[1], key[2], key[3], key[4], key[5], string(totals[key])])
    end

    write_tsv(
        OUT_OVERLAY_REGIONS,
        ["from_region", "from_node", "to_region", "to_node", "unit", "value"],
        out_rows,
    )
end

function write_target_group_summary(parent_map)
    seen = Dict{String, Tuple{String, String, Vector{String}}}()
    for (parent, entry) in parent_map
        if !haskey(seen, entry.shared_group)
            seen[entry.shared_group] = (entry.product_code, entry.activity_code, String[parent])
        else
            push!(seen[entry.shared_group][3], parent)
        end
    end

    rows = Vector{Vector{String}}()
    for group in sort(collect(keys(seen)))
        product_code, activity_code, parents = seen[group]
        push!(rows, [group, product_code, activity_code, join(sort(parents), ",")])
    end

    write_tsv(
        OUT_TARGET_GROUPS,
        ["shared_parent_group", "figaro_product_code", "figaro_activity_code", "ce_rise_parents"],
        rows,
    )
end

function extract_target_supply(parent_map)
    target_products = Set(entry.product_code for entry in values(parent_map))
    target_activities = Set(entry.activity_code for entry in values(parent_map))

    rows = read_tsv(SUPPLY_FILE)
    data = rows[2:end]
    out_rows = Vector{Vector{String}}()
    for row in data
        product_region, product_code, activity_region, activity_code, value = row
        if product_code in target_products || activity_code in target_activities
            push!(out_rows, [product_region, product_code, activity_region, activity_code, value])
        end
    end

    write_tsv(
        OUT_TARGET_SUPPLY,
        ["product_region", "product_code", "activity_region", "activity_code", "value_meur"],
        out_rows,
    )
end

function extract_target_use(parent_map)
    target_products = Set(entry.product_code for entry in values(parent_map))

    rows = read_tsv(USE_FILE)
    data = rows[2:end]
    out_rows = Vector{Vector{String}}()
    for row in data
        product_region, product_code, use_region, use_code, value = row
        if product_code in target_products
            push!(out_rows, [product_region, product_code, use_region, use_code, value])
        end
    end

    write_tsv(
        OUT_TARGET_USE,
        ["product_region", "product_code", "use_region", "use_code", "value_meur"],
        out_rows,
    )
end

function main()
    parent_map = load_parent_map(PARENT_MAP_FILE)
    write_parent_map_copy(parent_map)
    aggregate_overlay_by_regions()
    write_target_group_summary(parent_map)
    extract_target_supply(parent_map)
    extract_target_use(parent_map)

    println("Wrote:")
    println("  ", OUT_PARENT_MAP)
    println("  ", OUT_OVERLAY_REGIONS)
    println("  ", OUT_TARGET_GROUPS)
    println("  ", OUT_TARGET_SUPPLY)
    println("  ", OUT_TARGET_USE)
end

main()
