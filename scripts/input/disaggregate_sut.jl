#!/usr/bin/env julia

"""
Disaggregate the FIGARO 2016 target SUT sectors using the CE-RISE overlay.

This script is the first monetary split step after the region mapping.

What it does:
1. reads the mapped CE-RISE -> FIGARO parent correspondence,
2. derives regional output shares from the CE-RISE overlay,
3. creates explicit residual sectors when the overlay does not exhaust
   the FIGARO parent total,
4. writes the first disaggregated supply and use tables.

Current rule set:
- supply rows with a target product and target activity in the same region
  and same parent group are split diagonally across the child sectors,
  because these rows represent the own-output portion of the parent sector;
- all other two-sided splits are done with independent product/activity
  shares and therefore remain unbalanced approximations until the next step;
- use rows are always split independently across the relevant product and/or
  activity dimensions.

This script preserves the monetary totals of every original row. Exact
account balancing is deferred to the following balancing step.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")

const PARENT_MAP_FILE = joinpath(SUT_DIR, "sut_parent_figaro_map.tsv")
const PARENT_CHILDREN_FILE = joinpath(SUT_DIR, "sut_parent_children.tsv")
const OVERLAY_FILE = joinpath(SUT_DIR, "sut_disaggregation_overlay_regions.tsv")
const SUPPLY_FILE = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const USE_FILE = joinpath(SUT_DIR, "sut_use_base_2016.tsv")

const OUT_SPLIT_MAP = joinpath(SUT_DIR, "sut_split_sector_map.tsv")
const OUT_PARENT_CHILD_MAP = joinpath(SUT_DIR, "sut_parent_child_figaro_map.tsv")
const OUT_SHARES = joinpath(SUT_DIR, "sut_split_output_shares.tsv")
const OUT_SUPPLY = joinpath(SUT_DIR, "sut_supply_disaggregated_unbalanced.tsv")
const OUT_USE = joinpath(SUT_DIR, "sut_use_disaggregated_unbalanced.tsv")

const FIGARO_PARENT_LABELS = Dict(
    "CPA_C26" => "Computer, electronic and optical products",
    "CPA_C27" => "Electrical equipment",
)

const CE_RISE_PARENT_LABELS = Dict(
    "A_ELMA" => "Electrical machinery and apparatus n.e.c.",
    "A_OFMA" => "Office machinery and computers",
    "A_RATV" => "Radio, television and communication equipment and apparatus",
)

const CE_RISE_SPLIT_LABELS = Dict(
    "HPP" => "Household appliances",
    "PV" => "Photovoltaic equipment",
    "BAT" => "Batteries",
    "ELMA_c" => "Other electrical machinery and apparatus",
    "ELMA_res" => "Residual electrical equipment outside CE-RISE disaggregation",
    "LAP" => "Laptops",
    "DES" => "Desktop computers",
    "PRI" => "Printers",
    "OFMA_c" => "Other office machinery and computers",
    "OFMA_res" => "Residual office machinery and computer equipment outside CE-RISE disaggregation",
    "MOB" => "Mobile phones",
    "MON" => "Monitors",
    "RATV_c" => "Other radio, television and communication equipment",
    "RATV_res" => "Residual radio, television and communication equipment outside CE-RISE disaggregation",
)

struct ParentEntry
    parent::String
    product_code::String
    activity_code::String
    group::String
end

struct SplitSector
    parent::String
    label::String
    kind::String
    product_code::String
    activity_code::String
    output_tonnes::Float64
    within_parent_share::Float64
    within_group_share::Float64
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

strip_activity_prefix(code::AbstractString) = code[3:end]
strip_commodity_prefix(code::AbstractString) = code[3:end]
short_parent(parent::AbstractString) = strip_activity_prefix(parent)

function load_parent_map()
    rows = read_tsv(PARENT_MAP_FILE)
    entries = ParentEntry[]
    for row in rows[2:end]
        push!(entries, ParentEntry(row[1], row[2], row[3], row[4]))
    end
    return entries
end

parent_label(parent::AbstractString) = get(CE_RISE_PARENT_LABELS, parent, parent)
split_label_text(label::AbstractString) = get(CE_RISE_SPLIT_LABELS, label, label)
figaro_parent_label(code::AbstractString) = get(FIGARO_PARENT_LABELS, code, code)

function load_parent_children()
    rows = read_tsv(PARENT_CHILDREN_FILE)
    children = Dict{String, Vector{String}}()
    for row in rows[2:end]
        parent = row[1]
        child = row[2]
        get!(children, parent, String[])
        push!(children[parent], child)
    end
    return children
end

function parse_overlay_outputs(parent_entries, parent_children)
    parent_set = Set(entry.parent for entry in parent_entries)
    child_to_parent = Dict{String, String}()
    for (parent, children) in parent_children
        for child in children
            child_to_parent[child] = parent
        end
    end

    parent_output = Dict{Tuple{String, String}, Float64}()
    child_output = Dict{Tuple{String, String, String}, Float64}()
    rows = read_tsv(OVERLAY_FILE)
    for row in rows[2:end]
        from_region, from_node, to_region, to_node, unit, value_str = row
        unit == "tonnes" || continue
        from_region == to_region || continue
        startswith(from_node, "A_") || continue
        startswith(to_node, "C_") || continue
        label_from = strip_activity_prefix(from_node)
        label_to = strip_commodity_prefix(to_node)
        label_from == label_to || continue

        value = parse(Float64, value_str)
        if from_node in parent_set
            parent_output[(from_region, from_node)] = get(parent_output, (from_region, from_node), 0.0) + value
        elseif haskey(child_to_parent, label_from)
            parent = child_to_parent[label_from]
            child_output[(from_region, parent, label_from)] = get(child_output, (from_region, parent, label_from), 0.0) + value
        end
    end

    return parent_output, child_output
end

function make_sector_codes(entry::ParentEntry, label::String)
    return string(entry.product_code, "_", label), string(entry.activity_code, "_", label)
end

function build_split_sectors(parent_entries, parent_children, parent_output, child_output)
    regions = sort(unique(key[1] for key in keys(parent_output)))
    groups = sort(unique(entry.group for entry in parent_entries))

    entries_by_group = Dict{String, Vector{ParentEntry}}()
    entry_by_parent = Dict(entry.parent => entry for entry in parent_entries)
    for entry in parent_entries
        get!(entries_by_group, entry.group, ParentEntry[])
        push!(entries_by_group[entry.group], entry)
    end

    splits = Dict{Tuple{String, String}, Vector{SplitSector}}()
    rows = Vector{Vector{String}}()
    map_rows = Vector{Vector{String}}()
    parent_child_rows = Vector{Vector{String}}()

    for group in groups
        sort!(entries_by_group[group], by = x -> x.parent)
        for region in regions
            group_total = 0.0
            for entry in entries_by_group[group]
                value = get(parent_output, (region, entry.parent), 0.0)
                value > 0.0 || error("Missing positive parent output for $(entry.parent) in $(region)")
                group_total += value
            end
            group_total > 0.0 || error("Missing positive group output for $(group) in $(region)")

            group_splits = SplitSector[]
            for entry in entries_by_group[group]
                parent_total = get(parent_output, (region, entry.parent), 0.0)
                child_sum = 0.0
                for child in get(parent_children, entry.parent, String[])
                    output = get(child_output, (region, entry.parent, child), 0.0)
                    child_sum += output
                    product_code, activity_code = make_sector_codes(entry, child)
                    split = SplitSector(
                        entry.parent,
                        child,
                        "child",
                        product_code,
                        activity_code,
                        output,
                        output / parent_total,
                        output / group_total,
                    )
                    push!(group_splits, split)
                end

                residual_output = parent_total - child_sum
                residual_output >= -1.0e-8 || error("Child outputs exceed parent output for $(entry.parent) in $(region)")
                residual_output = max(residual_output, 0.0)
                residual_label = string(short_parent(entry.parent), "_res")
                product_code, activity_code = make_sector_codes(entry, residual_label)
                residual = SplitSector(
                    entry.parent,
                    residual_label,
                    "residual",
                    product_code,
                    activity_code,
                    residual_output,
                    residual_output / parent_total,
                    residual_output / group_total,
                )
                push!(group_splits, residual)
            end

            total_share = sum(item.within_group_share for item in group_splits)
            abs(total_share - 1.0) <= 1.0e-6 || error("Split shares do not sum to one for $(group) in $(region): $(total_share)")
            splits[(region, group)] = group_splits

            for item in group_splits
                parent_total = get(parent_output, (region, item.parent), 0.0)
                push!(rows, [
                    region,
                    group,
                    item.parent,
                    item.label,
                    item.kind,
                    item.product_code,
                    item.activity_code,
                    string(item.output_tonnes),
                    string(parent_total),
                    string(group_total),
                    string(item.within_parent_share),
                    string(item.within_group_share),
                ])
                push!(map_rows, [
                    group,
                    item.parent,
                    parent_label(item.parent),
                    item.label,
                    split_label_text(item.label),
                    item.kind,
                    item.product_code,
                    item.activity_code,
                ])
                entry = entry_by_parent[item.parent]
                push!(parent_child_rows, [
                    group,
                    item.parent,
                    parent_label(item.parent),
                    entry.product_code,
                    figaro_parent_label(entry.product_code),
                    entry.activity_code,
                    item.label,
                    split_label_text(item.label),
                    item.kind,
                    item.product_code,
                    item.activity_code,
                ])
            end
        end
    end

    unique_map_rows = unique(map_rows)
    sort!(unique_map_rows, by = x -> join(x, '\t'))
    unique_parent_child_rows = unique(parent_child_rows)
    sort!(unique_parent_child_rows, by = x -> join(x, '\t'))
    write_tsv(
        OUT_SPLIT_MAP,
        [
            "shared_parent_group",
            "ce_rise_parent",
            "ce_rise_parent_label",
            "split_label",
            "split_label_description",
            "split_kind",
            "product_code",
            "activity_code",
        ],
        unique_map_rows,
    )
    write_tsv(
        OUT_PARENT_CHILD_MAP,
        [
            "shared_parent_group",
            "ce_rise_parent",
            "ce_rise_parent_label",
            "figaro_parent_product_code",
            "figaro_parent_product_label",
            "figaro_parent_activity_code",
            "split_label",
            "split_label_description",
            "split_kind",
            "split_product_code",
            "split_activity_code",
        ],
        unique_parent_child_rows,
    )
    write_tsv(
        OUT_SHARES,
        [
            "region",
            "shared_parent_group",
            "ce_rise_parent",
            "split_label",
            "split_kind",
            "product_code",
            "activity_code",
            "output_tonnes",
            "parent_output_tonnes",
            "group_output_tonnes",
            "within_parent_share",
            "within_group_share",
        ],
        rows,
    )

    return splits
end

function target_group_maps(parent_entries)
    product_group = Dict{String, String}()
    activity_group = Dict{String, String}()
    for entry in parent_entries
        product_group[entry.product_code] = entry.group
        activity_group[entry.activity_code] = entry.group
    end
    return product_group, activity_group
end

function write_row(io, fields::AbstractVector{<:AbstractString})
    println(io, join(fields, '\t'))
end

function split_supply(parent_entries, splits, product_group, activity_group)
    input_rows = 0
    output_rows = 0
    input_total = 0.0
    output_total = 0.0

    open(OUT_SUPPLY, "w") do out
        println(out, "product_region\tproduct_code\tactivity_region\tactivity_code\tvalue_meur")
        open(SUPPLY_FILE, "r") do io
            readline(io)
            for line in eachline(io)
                input_rows += 1
                parts = split(line, '\t')
                product_region, product_code, activity_region, activity_code, value_str = parts
                value = parse(Float64, value_str)
                input_total += value

                product_target = get(product_group, product_code, nothing)
                activity_target = get(activity_group, activity_code, nothing)

                if isnothing(product_target) && isnothing(activity_target)
                    write_row(out, parts)
                    output_rows += 1
                    output_total += value
                elseif !isnothing(product_target) && isnothing(activity_target)
                    for item in splits[(product_region, product_target)]
                        split_value = value * item.within_group_share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, item.product_code, activity_region, activity_code, string(split_value)])
                        output_rows += 1
                        output_total += split_value
                    end
                elseif isnothing(product_target) && !isnothing(activity_target)
                    for item in splits[(activity_region, activity_target)]
                        split_value = value * item.within_group_share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, product_code, activity_region, item.activity_code, string(split_value)])
                        output_rows += 1
                        output_total += split_value
                    end
                elseif product_target == activity_target && product_region == activity_region
                    for item in splits[(product_region, product_target)]
                        split_value = value * item.within_group_share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, item.product_code, activity_region, item.activity_code, string(split_value)])
                        output_rows += 1
                        output_total += split_value
                    end
                else
                    product_items = splits[(product_region, product_target)]
                    activity_items = splits[(activity_region, activity_target)]
                    for pitem in product_items
                        for aitem in activity_items
                            split_value = value * pitem.within_group_share * aitem.within_group_share
                            abs(split_value) <= 1.0e-12 && continue
                            write_row(out, [product_region, pitem.product_code, activity_region, aitem.activity_code, string(split_value)])
                            output_rows += 1
                            output_total += split_value
                        end
                    end
                end
            end
        end
    end

    return input_rows, output_rows, input_total, output_total
end

function split_use(parent_entries, splits, product_group, activity_group)
    input_rows = 0
    output_rows = 0
    input_total = 0.0
    output_total = 0.0

    open(OUT_USE, "w") do out
        println(out, "product_region\tproduct_code\tuse_region\tuse_code\tvalue_meur")
        open(USE_FILE, "r") do io
            readline(io)
            for line in eachline(io)
                input_rows += 1
                parts = split(line, '\t')
                product_region, product_code, use_region, use_code, value_str = parts
                value = parse(Float64, value_str)
                input_total += value

                product_target = get(product_group, product_code, nothing)
                use_target = get(activity_group, use_code, nothing)

                if isnothing(product_target) && isnothing(use_target)
                    write_row(out, parts)
                    output_rows += 1
                    output_total += value
                elseif !isnothing(product_target) && isnothing(use_target)
                    for item in splits[(product_region, product_target)]
                        split_value = value * item.within_group_share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, item.product_code, use_region, use_code, string(split_value)])
                        output_rows += 1
                        output_total += split_value
                    end
                elseif isnothing(product_target) && !isnothing(use_target)
                    for item in splits[(use_region, use_target)]
                        split_value = value * item.within_group_share
                        abs(split_value) <= 1.0e-12 && continue
                        write_row(out, [product_region, product_code, use_region, item.activity_code, string(split_value)])
                        output_rows += 1
                        output_total += split_value
                    end
                else
                    product_items = splits[(product_region, product_target)]
                    use_items = splits[(use_region, use_target)]
                    for pitem in product_items
                        for uitem in use_items
                            split_value = value * pitem.within_group_share * uitem.within_group_share
                            abs(split_value) <= 1.0e-12 && continue
                            write_row(out, [product_region, pitem.product_code, use_region, uitem.activity_code, string(split_value)])
                            output_rows += 1
                            output_total += split_value
                        end
                    end
                end
            end
        end
    end

    return input_rows, output_rows, input_total, output_total
end

function main()
    parent_entries = load_parent_map()
    parent_children = load_parent_children()
    parent_output, child_output = parse_overlay_outputs(parent_entries, parent_children)
    splits = build_split_sectors(parent_entries, parent_children, parent_output, child_output)
    product_group, activity_group = target_group_maps(parent_entries)

    supply_stats = split_supply(parent_entries, splits, product_group, activity_group)
    use_stats = split_use(parent_entries, splits, product_group, activity_group)

    println("Wrote:")
    println("  ", OUT_SPLIT_MAP)
    println("  ", OUT_PARENT_CHILD_MAP)
    println("  ", OUT_SHARES)
    println("  ", OUT_SUPPLY)
    println("  ", OUT_USE)
    println()
    println("Supply rows: ", supply_stats[1], " -> ", supply_stats[2], "   total=", supply_stats[3], " -> ", supply_stats[4])
    println("Use rows:    ", use_stats[1], " -> ", use_stats[2], "   total=", use_stats[3], " -> ", use_stats[4])
end

main()
