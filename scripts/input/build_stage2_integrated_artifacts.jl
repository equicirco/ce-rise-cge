#!/usr/bin/env julia

"""
Build the stage-2 integrated SUT artifact set.

Stage 2 removes the split parent sectors from the FIGARO benchmark and replaces
them with the CE-RISE manufacturing sectors plus the family-specific circular
parent sectors derived from the current overlay-based shares.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "02_integrated_sut")

const BASE_SUPPLY = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const BASE_USE = joinpath(SUT_DIR, "sut_use_base_2016.tsv")
const SPLIT_MAP_FILE = joinpath(SUT_DIR, "sut_intermediate_split_map.tsv")
const SPLIT_SHARE_FILE = joinpath(SUT_DIR, "sut_intermediate_split_shares.tsv")

const OUT_SUPPLY = joinpath(OUTDIR, "integrated_supply.tsv")
const OUT_USE = joinpath(OUTDIR, "integrated_use.tsv")
const OUT_MAP = joinpath(OUTDIR, "integrated_split_map.tsv")
const OUT_SHARES = joinpath(OUTDIR, "integrated_split_shares.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "integrated_validation.tsv")

const TOL = 1.0e-8

struct SplitItem
    target_parent_product_code::String
    target_parent_activity_code::String
    split_label::String
    split_product_code::String
    split_activity_code::String
    share::Float64
end

struct SplitMaps
    parent_product_by_split::Dict{String,String}
    parent_activity_by_split::Dict{String,String}
end

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
end

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

function canonical_code2(code::AbstractString)
    code == "E37-39" && return "E37-E39"
    return String(code)
end

function activity_code_aliases(code::AbstractString)
    code == "E37-E39" && return ("E37-E39", "E37-39")
    return (String(code),)
end

function load_split_shares(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))

    product_lookup = Dict{Tuple{String,String},Vector{SplitItem}}()
    activity_lookup = Dict{Tuple{String,String},Vector{SplitItem}}()

    for row in rows[2:end]
        region = row[idx["region"]]
        item = SplitItem(
            row[idx["target_parent_product_code"]],
            row[idx["target_parent_activity_code"]],
            row[idx["split_label"]],
            row[idx["split_product_code"]],
            row[idx["split_activity_code"]],
            parse(Float64, row[idx["split_share"]]),
        )
        get!(product_lookup, (region, item.target_parent_product_code), SplitItem[])
        push!(product_lookup[(region, item.target_parent_product_code)], item)
        for alias in activity_code_aliases(item.target_parent_activity_code)
            get!(activity_lookup, (region, alias), SplitItem[])
            push!(activity_lookup[(region, alias)], item)
        end
    end

    for items in values(product_lookup)
        sort!(items, by = x -> x.split_product_code)
    end
    for items in values(activity_lookup)
        sort!(items, by = x -> x.split_activity_code)
    end

    return product_lookup, activity_lookup
end

function load_split_maps(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))

    parent_product_by_split = Dict{String,String}()
    parent_activity_by_split = Dict{String,String}()
    for row in rows[2:end]
        parent_product_by_split[row[idx["split_product_code"]]] = row[idx["target_parent_product_code"]]
        parent_activity_by_split[row[idx["split_activity_code"]]] = canonical_code2(row[idx["target_parent_activity_code"]])
    end
    return SplitMaps(parent_product_by_split, parent_activity_by_split)
end

function add_value!(totals::Dict{NTuple{4,String},Float64}, key::NTuple{4,String}, value::Float64)
    abs(value) <= 1.0e-12 && return
    totals[key] = get(totals, key, 0.0) + value
end

function build_replacement_supply(product_lookup, activity_lookup)
    totals = Dict{NTuple{4,String},Float64}()
    rows = read_tsv(BASE_SUPPLY)
    for row in rows[2:end]
        product_region, product_code, activity_region, activity_code, value_str = row
        value = parse(Float64, value_str)
        product_items = get(product_lookup, (product_region, product_code), nothing)
        activity_items = get(activity_lookup, (activity_region, activity_code), nothing)

        if isnothing(product_items) && isnothing(activity_items)
            add_value!(totals, (product_region, product_code, activity_region, activity_code), value)
        elseif !isnothing(product_items) && isnothing(activity_items)
            for pitem in product_items
                add_value!(totals, (product_region, pitem.split_product_code, activity_region, activity_code), value * pitem.share)
            end
        elseif isnothing(product_items) && !isnothing(activity_items)
            for aitem in activity_items
                add_value!(totals, (product_region, product_code, activity_region, aitem.split_activity_code), value * aitem.share)
            end
        else
            same_target =
                product_region == activity_region &&
                product_items[1].target_parent_product_code == activity_items[1].target_parent_product_code &&
                product_items[1].target_parent_activity_code == activity_items[1].target_parent_activity_code

            if same_target
                activity_by_label = Dict(item.split_label => item for item in activity_items)
                for pitem in product_items
                    haskey(activity_by_label, pitem.split_label) || continue
                    aitem = activity_by_label[pitem.split_label]
                    add_value!(totals, (product_region, pitem.split_product_code, activity_region, aitem.split_activity_code), value * pitem.share)
                end
            else
                for pitem in product_items
                    for aitem in activity_items
                        add_value!(totals, (product_region, pitem.split_product_code, activity_region, aitem.split_activity_code), value * pitem.share * aitem.share)
                    end
                end
            end
        end
    end
    return totals
end

function build_replacement_use(product_lookup, activity_lookup)
    totals = Dict{NTuple{4,String},Float64}()
    rows = read_tsv(BASE_USE)
    for row in rows[2:end]
        product_region, product_code, use_region, use_code, value_str = row
        value = parse(Float64, value_str)
        product_items = get(product_lookup, (product_region, product_code), nothing)
        use_items = get(activity_lookup, (use_region, use_code), nothing)

        if isnothing(product_items) && isnothing(use_items)
            add_value!(totals, (product_region, product_code, use_region, use_code), value)
        elseif !isnothing(product_items) && isnothing(use_items)
            for pitem in product_items
                add_value!(totals, (product_region, pitem.split_product_code, use_region, use_code), value * pitem.share)
            end
        elseif isnothing(product_items) && !isnothing(use_items)
            for uitem in use_items
                add_value!(totals, (product_region, product_code, use_region, uitem.split_activity_code), value * uitem.share)
            end
        else
            for pitem in product_items
                for uitem in use_items
                    add_value!(totals, (product_region, pitem.split_product_code, use_region, uitem.split_activity_code), value * pitem.share * uitem.share)
                end
            end
        end
    end
    return totals
end

function write_matrix(path::AbstractString, totals::Dict{NTuple{4,String},Float64}; last_col::String)
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(totals)))
        value = totals[key]
        abs(value) <= 1.0e-12 && continue
        push!(rows, [key[1], key[2], key[3], key[4], string(value)])
    end
    write_tsv(path, [last_col == "activity_code" ? "product_region" : "product_region", "product_code", last_col == "activity_code" ? "activity_region" : "use_region", last_col, "value_meur"], rows)
end

function collapse_rows(totals::Dict{NTuple{4,String},Float64}, maps::SplitMaps)
    collapsed = Dict{NTuple{4,String},Float64}()
    for (key, value) in totals
        collapsed_key = (
            key[1],
            get(maps.parent_product_by_split, key[2], key[2]),
            key[3],
            get(maps.parent_activity_by_split, key[4], canonical_code2(key[4])),
        )
        collapsed[collapsed_key] = get(collapsed, collapsed_key, 0.0) + value
    end
    return collapsed
end

function load_base_totals(path::AbstractString)
    rows = read_tsv(path)
    totals = Dict{NTuple{4,String},Float64}()
    for row in rows[2:end]
        key = (row[1], row[2], row[3], canonical_code2(row[4]))
        totals[key] = get(totals, key, 0.0) + parse(Float64, row[5])
    end
    return totals
end

function compare_totals(left::Dict{NTuple{4,String},Float64}, right::Dict{NTuple{4,String},Float64})
    keys_union = union(keys(left), keys(right))
    n_diff = 0
    max_abs_diff = 0.0
    sum_abs_diff = 0.0
    for key in keys_union
        diff = get(left, key, 0.0) - get(right, key, 0.0)
        absdiff = abs(diff)
        if absdiff > TOL
            n_diff += 1
            max_abs_diff = max(max_abs_diff, absdiff)
            sum_abs_diff += absdiff
        end
    end
    return n_diff, max_abs_diff, sum_abs_diff, length(keys_union)
end

function total_value(totals::Dict{NTuple{4,String},Float64})
    sum(values(totals))
end

function main()
    ensure_dir(OUTDIR)

    product_lookup, activity_lookup = load_split_shares(SPLIT_SHARE_FILE)
    split_maps = load_split_maps(SPLIT_MAP_FILE)

    supply_totals = build_replacement_supply(product_lookup, activity_lookup)
    use_totals = build_replacement_use(product_lookup, activity_lookup)

    write_matrix(OUT_SUPPLY, supply_totals; last_col = "activity_code")
    write_matrix(OUT_USE, use_totals; last_col = "use_code")
    write_tsv(OUT_MAP, read_tsv(SPLIT_MAP_FILE)[1], read_tsv(SPLIT_MAP_FILE)[2:end])
    write_tsv(OUT_SHARES, read_tsv(SPLIT_SHARE_FILE)[1], read_tsv(SPLIT_SHARE_FILE)[2:end])

    base_supply = load_base_totals(BASE_SUPPLY)
    base_use = load_base_totals(BASE_USE)
    collapsed_supply = collapse_rows(supply_totals, split_maps)
    collapsed_use = collapse_rows(use_totals, split_maps)
    supply_cmp = compare_totals(base_supply, collapsed_supply)
    use_cmp = compare_totals(base_use, collapsed_use)

    write_tsv(
        OUT_VALIDATION,
        ["table", "base_total", "candidate_total", "comparison_total", "n_diff", "max_abs_diff", "sum_abs_diff", "n_keys", "status"],
        [
            [
                "supply",
                string(total_value(base_supply)),
                string(total_value(supply_totals)),
                string(total_value(collapsed_supply)),
                string(supply_cmp[1]),
                string(supply_cmp[2]),
                string(supply_cmp[3]),
                string(supply_cmp[4]),
                supply_cmp[1] == 0 ? "PASS" : "FAIL",
            ],
            [
                "use",
                string(total_value(base_use)),
                string(total_value(use_totals)),
                string(total_value(collapsed_use)),
                string(use_cmp[1]),
                string(use_cmp[2]),
                string(use_cmp[3]),
                string(use_cmp[4]),
                use_cmp[1] == 0 ? "PASS" : "FAIL",
            ],
        ],
    )

    println("Wrote stage-2 artifacts to ", OUTDIR)
end

main()
