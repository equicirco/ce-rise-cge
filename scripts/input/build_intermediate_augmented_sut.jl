#!/usr/bin/env julia

"""
Build an intermediate augmented SUT that keeps parent sectors and adds the
current disaggregated sectors alongside them.

Purpose:
- preserve the original FIGARO parent sectors,
- add the CE-RISE manufacturing split sectors,
- add family-specific circular-parent service splits plus residual sectors,
- keep this as an intermediate exploratory layer before the final aggregation
  and balancing choices are fixed.

Important:
- this augmented SUT is intentionally not a final balanced benchmark;
- parent sectors remain present while their split sectors are also added;
- later steps can drop, aggregate, or recompose sectors from this layer.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")
const STRUCTURE_DIR = joinpath(ROOT_DIR, "data", "interim", "structure")

const SUPPLY_FILE = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const USE_FILE = joinpath(SUT_DIR, "sut_use_base_2016.tsv")
const MANUFACTURING_MAP_FILE = joinpath(SUT_DIR, "sut_parent_child_figaro_map.tsv")
const MANUFACTURING_SHARES_FILE = joinpath(SUT_DIR, "sut_split_output_shares.tsv")
const CIRCULAR_CANDIDATES_FILE = joinpath(STRUCTURE_DIR, "circular_parent_candidates.tsv")
const CIRCULAR_ACTIVITY_FILE = joinpath(STRUCTURE_DIR, "circular_parent_activity_output.tsv")
const CIRCULAR_USE_FILE = joinpath(STRUCTURE_DIR, "circular_parent_use_by_family.tsv")

const OUT_MAP = joinpath(SUT_DIR, "sut_intermediate_split_map.tsv")
const OUT_SHARES = joinpath(SUT_DIR, "sut_intermediate_split_shares.tsv")
const OUT_SUPPLY = joinpath(SUT_DIR, "sut_supply_intermediate_augmented.tsv")
const OUT_USE = joinpath(SUT_DIR, "sut_use_intermediate_augmented.tsv")

struct SplitItem
    source::String
    target_id::String
    target_product_code::String
    target_product_label::String
    target_activity_code::String
    target_activity_label::String
    split_label::String
    split_label_description::String
    split_kind::String
    split_product_code::String
    split_activity_code::String
    share::Float64
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

function load_manufacturing_splits()
    map_rows = read_tsv(MANUFACTURING_MAP_FILE)
    map_by_key = Dict{Tuple{String,String},NamedTuple}()
    for row in map_rows[2:end]
        group = row[1]
        parent_product_code = row[4]
        parent_product_label = row[5]
        parent_activity_code = row[6]
        split_label = row[7]
        split_label_description = row[8]
        split_kind = row[9]
        split_product_code = row[10]
        split_activity_code = row[11]
        map_by_key[(group, split_label)] = (
            target_product_code = parent_product_code,
            target_product_label = parent_product_label,
            target_activity_code = parent_activity_code,
            target_activity_label = parent_activity_code,
            split_label_description = split_label_description,
            split_kind = split_kind,
            split_product_code = split_product_code,
            split_activity_code = split_activity_code,
        )
    end

    region_items = Dict{Tuple{String,String},Vector{SplitItem}}()
    share_rows = read_tsv(MANUFACTURING_SHARES_FILE)
    for row in share_rows[2:end]
        region = row[1]
        group = row[2]
        split_label = row[4]
        share = parse(Float64, row[12])
        meta = map_by_key[(group, split_label)]
        item = SplitItem(
            "manufacturing",
            group,
            meta.target_product_code,
            meta.target_product_label,
            meta.target_activity_code,
            meta.target_activity_label,
            split_label,
            meta.split_label_description,
            meta.split_kind,
            meta.split_product_code,
            meta.split_activity_code,
            share,
        )
        get!(region_items, (region, meta.target_product_code), SplitItem[])
        push!(region_items[(region, meta.target_product_code)], item)
    end

    for items in values(region_items)
        sort!(items, by = x -> x.split_product_code)
    end
    return region_items
end

function load_circular_splits()
    candidate_rows = read_tsv(CIRCULAR_CANDIDATES_FILE)
    candidate_by_role = Dict{String,NamedTuple}()
    for row in candidate_rows[2:end]
        role_id = row[1]
        role_label = row[2]
        product_code = row[3]
        product_label = row[4]
        activity_code = row[5]
        activity_label = row[6]
        candidate_by_role[role_id] = (
            role_label = role_label,
            product_code = product_code,
            product_label = product_label,
            activity_code = activity_code,
            activity_label = activity_label,
        )
    end

    own_output = Dict{Tuple{String,String},Float64}()
    activity_rows = read_tsv(CIRCULAR_ACTIVITY_FILE)
    for row in activity_rows[2:end]
        region = row[1]
        role_id = row[2]
        own_output[(region, role_id)] = parse(Float64, row[8])
    end

    family_use = Dict{Tuple{String,String,String,String},Tuple{String,Float64}}()
    totals_by_role = Dict{Tuple{String,String},Float64}()
    use_rows = read_tsv(CIRCULAR_USE_FILE)
    for row in use_rows[2:end]
        region = row[1]
        ce_rise_parent = row[2]
        ce_rise_parent_label = row[3]
        role_id = row[6]
        total_use = parse(Float64, row[7])
        family_key = replace(ce_rise_parent, "A_" => "")
        family_use[(region, role_id, family_key, ce_rise_parent)] = (ce_rise_parent_label, total_use)
        totals_by_role[(region, role_id)] = get(totals_by_role, (region, role_id), 0.0) + total_use
    end

    region_items = Dict{Tuple{String,String},Vector{SplitItem}}()
    role_regions = sort!(collect(keys(own_output)))
    for (region, role_id) in role_regions
        candidate = candidate_by_role[role_id]
        denominator = own_output[(region, role_id)]
        denominator > 0.0 || error("Non-positive own output for $(role_id) in $(region)")
        items = SplitItem[]
        total_share = 0.0
        for family_key in ("ELMA", "OFMA", "RATV")
            use_key = (region, role_id, family_key, "A_" * family_key)
            if haskey(family_use, use_key)
                ce_rise_parent_label, total_use = family_use[use_key]
                share = total_use / denominator
                total_share += share
                push!(items, SplitItem(
                    "circular_parent",
                    role_id,
                    candidate.product_code,
                    candidate.product_label,
                    candidate.activity_code,
                    candidate.activity_label,
                    family_key,
                    string(ce_rise_parent_label, "-linked share of ", candidate.role_label),
                    "family_split",
                    string(candidate.product_code, "_", family_key),
                    string(candidate.activity_code, "_", family_key),
                    share,
                ))
            end
        end
        total_share <= 1.0 + 1.0e-9 || error("Circular shares exceed one for $(role_id) in $(region): $(total_share)")
        residual_share = max(0.0, 1.0 - total_share)
        push!(items, SplitItem(
            "circular_parent",
            role_id,
            candidate.product_code,
            candidate.product_label,
            candidate.activity_code,
            candidate.activity_label,
            "res",
            string("Residual non-CE-RISE share of ", candidate.role_label),
            "residual",
            string(candidate.product_code, "_res"),
            string(candidate.activity_code, "_res"),
            residual_share,
        ))
        sort!(items, by = x -> x.split_product_code)
        region_items[(region, candidate.product_code)] = items
    end
    return region_items
end

function merge_split_sets(split_sets...)
    merged = Dict{Tuple{String,String},Vector{SplitItem}}()
    for split_set in split_sets
        for (key, items) in split_set
            merged[key] = items
        end
    end
    return merged
end

function activity_code_aliases(code::AbstractString)
    code == "E37-E39" && return ("E37-E39", "E37-39")
    return (String(code),)
end

function build_activity_lookup(split_items_by_product)
    lookup = Dict{Tuple{String,String},Vector{SplitItem}}()
    for ((region, _), items) in split_items_by_product
        isempty(items) && continue
        activity_code = items[1].target_activity_code
        for alias in activity_code_aliases(activity_code)
            lookup[(region, alias)] = items
        end
    end
    return lookup
end

function split_map_rows(split_items_by_product)
    rows = Vector{Vector{String}}()
    seen = Set{Tuple{String,String,String,String,String,String,String,String,String,String,String}}()
    for (_, items) in sort!(collect(split_items_by_product), by = x -> x[1])
        for item in items
            key = (
                item.source,
                item.target_id,
                item.target_product_code,
                item.target_product_label,
                item.target_activity_code,
                item.target_activity_label,
                item.split_label,
                item.split_label_description,
                item.split_kind,
                item.split_product_code,
                item.split_activity_code,
            )
            key in seen && continue
            push!(seen, key)
            push!(rows, collect(key))
        end
    end
    sort!(rows, by = x -> join(x, '\t'))
    return rows
end

function split_share_rows(split_items_by_product)
    rows = Vector{Vector{String}}()
    for ((region, _), items) in sort!(collect(split_items_by_product), by = x -> x[1])
        for item in items
            push!(rows, [
                region,
                item.source,
                item.target_id,
                item.target_product_code,
                item.target_product_label,
                item.target_activity_code,
                item.target_activity_label,
                item.split_label,
                item.split_label_description,
                item.split_kind,
                item.split_product_code,
                item.split_activity_code,
                string(item.share),
            ])
        end
    end
    return rows
end

function write_row(io, fields::AbstractVector{<:AbstractString})
    println(io, join(fields, '\t'))
end

function write_augmented_supply(product_lookup, activity_lookup)
    input_rows = 0
    output_rows = 0

    open(OUT_SUPPLY, "w") do out
        println(out, "product_region\tproduct_code\tactivity_region\tactivity_code\tvalue_meur")
        open(SUPPLY_FILE, "r") do io
            readline(io)
            for line in eachline(io)
                input_rows += 1
                parts = split(line, '\t')
                product_region, product_code, activity_region, activity_code, value_str = parts
                value = parse(Float64, value_str)
                write_row(out, parts)
                output_rows += 1

                product_items = get(product_lookup, (product_region, product_code), nothing)
                activity_items = get(activity_lookup, (activity_region, activity_code), nothing)

                if !isnothing(product_items) && isnothing(activity_items)
                    for item in product_items
                        split_value = value * item.share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, item.split_product_code, activity_region, activity_code, string(split_value)])
                        output_rows += 1
                    end
                elseif isnothing(product_items) && !isnothing(activity_items)
                    for item in activity_items
                        split_value = value * item.share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, product_code, activity_region, item.split_activity_code, string(split_value)])
                        output_rows += 1
                    end
                elseif !isnothing(product_items) && !isnothing(activity_items)
                    same_target =
                        product_region == activity_region &&
                        product_items[1].target_product_code == activity_items[1].target_product_code &&
                        product_items[1].target_activity_code == activity_items[1].target_activity_code

                    if same_target
                        activity_by_label = Dict(item.split_label => item for item in activity_items)
                        for pitem in product_items
                            haskey(activity_by_label, pitem.split_label) || continue
                            split_value = value * pitem.share
                            abs(split_value) <= 1.0e-12 && continue
                            aitem = activity_by_label[pitem.split_label]
                            write_row(out, [product_region, pitem.split_product_code, activity_region, aitem.split_activity_code, string(split_value)])
                            output_rows += 1
                        end
                    else
                        for pitem in product_items
                            for aitem in activity_items
                                split_value = value * pitem.share * aitem.share
                                abs(split_value) <= 1.0e-12 && continue
                                write_row(out, [product_region, pitem.split_product_code, activity_region, aitem.split_activity_code, string(split_value)])
                                output_rows += 1
                            end
                        end
                    end
                end
            end
        end
    end

    return input_rows, output_rows
end

function write_augmented_use(product_lookup, activity_lookup)
    input_rows = 0
    output_rows = 0

    open(OUT_USE, "w") do out
        println(out, "product_region\tproduct_code\tuse_region\tuse_code\tvalue_meur")
        open(USE_FILE, "r") do io
            readline(io)
            for line in eachline(io)
                input_rows += 1
                parts = split(line, '\t')
                product_region, product_code, use_region, use_code, value_str = parts
                value = parse(Float64, value_str)
                write_row(out, parts)
                output_rows += 1

                product_items = get(product_lookup, (product_region, product_code), nothing)
                use_items = get(activity_lookup, (use_region, use_code), nothing)

                if !isnothing(product_items) && isnothing(use_items)
                    for item in product_items
                        split_value = value * item.share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, item.split_product_code, use_region, use_code, string(split_value)])
                        output_rows += 1
                    end
                elseif isnothing(product_items) && !isnothing(use_items)
                    for item in use_items
                        split_value = value * item.share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, product_code, use_region, item.split_activity_code, string(split_value)])
                        output_rows += 1
                    end
                elseif !isnothing(product_items) && !isnothing(use_items)
                    for pitem in product_items
                        for uitem in use_items
                            split_value = value * pitem.share * uitem.share
                            abs(split_value) <= 1.0e-12 && continue
                            write_row(out, [product_region, pitem.split_product_code, use_region, uitem.split_activity_code, string(split_value)])
                            output_rows += 1
                        end
                    end
                end
            end
        end
    end

    return input_rows, output_rows
end

function main()
    manufacturing = load_manufacturing_splits()
    circular = load_circular_splits()
    split_items_by_product = merge_split_sets(manufacturing, circular)
    split_items_by_activity = build_activity_lookup(split_items_by_product)

    write_tsv(
        OUT_MAP,
        [
            "split_source",
            "target_parent_id",
            "target_parent_product_code",
            "target_parent_product_label",
            "target_parent_activity_code",
            "target_parent_activity_label",
            "split_label",
            "split_label_description",
            "split_kind",
            "split_product_code",
            "split_activity_code",
        ],
        split_map_rows(split_items_by_product),
    )
    write_tsv(
        OUT_SHARES,
        [
            "region",
            "split_source",
            "target_parent_id",
            "target_parent_product_code",
            "target_parent_product_label",
            "target_parent_activity_code",
            "target_parent_activity_label",
            "split_label",
            "split_label_description",
            "split_kind",
            "split_product_code",
            "split_activity_code",
            "split_share",
        ],
        split_share_rows(split_items_by_product),
    )

    supply_stats = write_augmented_supply(split_items_by_product, split_items_by_activity)
    use_stats = write_augmented_use(split_items_by_product, split_items_by_activity)

    println("Wrote:")
    println("  ", OUT_MAP)
    println("  ", OUT_SHARES)
    println("  ", OUT_SUPPLY)
    println("  ", OUT_USE)
    println()
    println("Supply rows: ", supply_stats[1], " -> ", supply_stats[2])
    println("Use rows:    ", use_stats[1], " -> ", use_stats[2])
end

main()
