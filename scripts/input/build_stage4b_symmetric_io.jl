#!/usr/bin/env julia

"""
Build the stage-4b symmetric industry-by-industry value IO artifact set.

This stage converts the balanced SUT into a symmetric industry-by-industry IO
representation using the fixed-product sales structure assumption of EUROSTAT
Model D: each product is reassigned to producing industries according to that
product's observed sales structure, regardless of the industry where it is
used.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const STAGE3_DIR = joinpath(ROOT_DIR, "data", "artifacts", "03_final_preparation")
const STAGE4_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04_balanced_sut")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "04b_symmetric_io")

const IN_SUPPLY = joinpath(STAGE4_DIR, "balanced_supply.tsv")
const IN_USE = joinpath(STAGE4_DIR, "balanced_use.tsv")
const IN_SECTOR_REGISTRY = joinpath(STAGE3_DIR, "explicit_final_sector_registry.tsv")

const OUT_SALES = joinpath(OUTDIR, "product_sales_structure.tsv")
const OUT_INTERMEDIATE = joinpath(OUTDIR, "industry_by_industry_intermediate.tsv")
const OUT_FINAL = joinpath(OUTDIR, "industry_by_final_demand.tsv")
const OUT_VALUE_ADDED = joinpath(OUTDIR, "value_added_by_industry.tsv")
const OUT_OUTPUT = joinpath(OUTDIR, "industry_output.tsv")
const OUT_PRODUCT_OUTPUT = joinpath(OUTDIR, "product_output.tsv")
const OUT_TECH = joinpath(OUTDIR, "industry_by_industry_technical_coefficients.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "symmetric_io_validation.tsv")

const SPECIAL_PRODUCT_ROWS = Set(["B2A3G", "D1", "D21X31", "D29X39", "OP_NRES", "OP_RES"])
const TOL = 1.0e-10

struct SupplyEntry
    product_region::String
    product_sector::String
    activity_region::String
    activity_sector::String
    value::Float64
end

struct UseEntry
    product_region::String
    product_sector::String
    use_region::String
    use_code::String
    value::Float64
end

sector_key(region::AbstractString, sector::AbstractString) = (String(region), String(sector))

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

function load_sector_registry(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))
    ids = String[]
    labels = Dict{String,String}()
    for row in rows[2:end]
        id = row[idx["sector_id"]]
        push!(ids, id)
        labels[id] = row[idx["sector_label"]]
    end
    return ids, labels
end

function load_supply_entries(path::AbstractString)
    rows = read_tsv(path)
    return [
        SupplyEntry(row[1], row[2], row[3], row[4], parse(Float64, row[5]))
        for row in rows[2:end]
    ]
end

function load_use_entries(path::AbstractString)
    rows = read_tsv(path)
    return [
        UseEntry(row[1], row[2], row[3], row[4], parse(Float64, row[5]))
        for row in rows[2:end]
    ]
end

function sorted_pair_keys(dict::Dict{Tuple{String,String},Float64})
    return sort!(collect(keys(dict)))
end

function sorted_quad_keys(dict)
    return sort!(collect(keys(dict)))
end

function add_flow!(dict, key, value)
    abs(value) <= TOL && return
    dict[key] = get(dict, key, 0.0) + value
end

function main()
    ensure_dir(OUTDIR)

    sector_ids, sector_labels = load_sector_registry(IN_SECTOR_REGISTRY)
    sector_set = Set(sector_ids)
    supply_entries = load_supply_entries(IN_SUPPLY)
    use_entries = load_use_entries(IN_USE)

    product_output = Dict{Tuple{String,String},Float64}()
    industry_output = Dict{Tuple{String,String},Float64}()
    make_values = Dict{NTuple{4,String},Float64}()

    for entry in supply_entries
        entry.product_sector in sector_set || continue
        entry.activity_sector in sector_set || continue
        product = sector_key(entry.product_region, entry.product_sector)
        activity = sector_key(entry.activity_region, entry.activity_sector)
        add_flow!(product_output, product, entry.value)
        add_flow!(industry_output, activity, entry.value)
        make_values[(product[1], product[2], activity[1], activity[2])] =
            get(make_values, (product[1], product[2], activity[1], activity[2]), 0.0) + entry.value
    end

    product_to_sales = Dict{Tuple{String,String},Vector{NamedTuple{(:activity_region, :activity_sector, :share, :supply_value),Tuple{String,String,Float64,Float64}}}}()
    sales_rows = Vector{Vector{String}}()
    max_abs_share_gap = 0.0

    for product in sort!(collect(keys(product_output)))
        q = product_output[product]
        q <= TOL && continue
        sales = NamedTuple{(:activity_region, :activity_sector, :share, :supply_value),Tuple{String,String,Float64,Float64}}[]
        share_sum = 0.0
        for key in sort!(collect(keys(make_values)))
            key[1] == product[1] || continue
            key[2] == product[2] || continue
            v = make_values[key]
            share = v / q
            push!(sales, (activity_region = key[3], activity_sector = key[4], share = share, supply_value = v))
            share_sum += share
            push!(sales_rows, [
                product[1], product[2], key[3], key[4],
                string(v), string(q), string(share),
            ])
        end
        product_to_sales[product] = sales
        max_abs_share_gap = max(max_abs_share_gap, abs(share_sum - 1.0))
    end

    intermediate_use = Dict{NTuple{4,String},Float64}()
    final_demand = Dict{NTuple{4,String},Float64}()
    value_added = Dict{NTuple{4,String},Float64}()
    final_demand_columns = Set{Tuple{String,String}}()
    value_added_rows = Set{Tuple{String,String}}()

    for entry in use_entries
        product = sector_key(entry.product_region, entry.product_sector)
        user = sector_key(entry.use_region, entry.use_code)
        if (entry.product_sector in sector_set) && (entry.use_code in sector_set)
            add_flow!(intermediate_use, (product[1], product[2], user[1], user[2]), entry.value)
        elseif (entry.product_sector in sector_set) && !(entry.use_code in sector_set) && !(entry.product_sector in SPECIAL_PRODUCT_ROWS)
            add_flow!(final_demand, (product[1], product[2], entry.use_region, entry.use_code), entry.value)
            push!(final_demand_columns, (entry.use_region, entry.use_code))
        elseif (entry.product_sector in SPECIAL_PRODUCT_ROWS) && (entry.use_code in sector_set)
            add_flow!(value_added, (entry.product_region, entry.product_sector, entry.use_region, entry.use_code), entry.value)
            push!(value_added_rows, (entry.product_region, entry.product_sector))
        end
    end

    io_intermediate = Dict{NTuple{4,String},Float64}()
    io_final = Dict{NTuple{4,String},Float64}()

    for pair in intermediate_use
        key = pair[1]
        value = pair[2]
        product = (key[1], key[2])
        user = (key[3], key[4])
        sales = get(product_to_sales, product, nothing)
        sales === nothing && continue
        for sale in sales
            add_flow!(io_intermediate,
                (sale.activity_region, sale.activity_sector, user[1], user[2]),
                sale.share * value)
        end
    end

    for pair in final_demand
        key = pair[1]
        value = pair[2]
        product = (key[1], key[2])
        demand = (key[3], key[4])
        sales = get(product_to_sales, product, nothing)
        sales === nothing && continue
        for sale in sales
            add_flow!(io_final,
                (sale.activity_region, sale.activity_sector, demand[1], demand[2]),
                sale.share * value)
        end
    end

    tech_rows = Vector{Vector{String}}()
    for key in sorted_quad_keys(io_intermediate)
        value = io_intermediate[key]
        col_activity = (key[3], key[4])
        output = get(industry_output, col_activity, 0.0)
        coeff = output <= TOL ? NaN : value / output
        push!(tech_rows, [key[1], key[2], key[3], key[4], string(value), string(coeff)])
    end

    intermediate_rows = [[key[1], key[2], key[3], key[4], string(io_intermediate[key])]
                         for key in sorted_quad_keys(io_intermediate)]
    final_rows = [[key[1], key[2], key[3], key[4], string(io_final[key])]
                  for key in sorted_quad_keys(io_final)]
    value_added_rows_out = [[key[1], key[2], key[3], key[4], string(value_added[key])]
                            for key in sorted_quad_keys(value_added)]
    industry_output_rows = [[key[1], key[2], get(sector_labels, key[2], key[2]), string(industry_output[key])]
                            for key in sorted_pair_keys(industry_output)]
    product_output_rows = [[key[1], key[2], get(sector_labels, key[2], key[2]), string(product_output[key])]
                           for key in sorted_pair_keys(product_output)]

    row_intermediate = Dict{Tuple{String,String},Float64}()
    row_final = Dict{Tuple{String,String},Float64}()
    col_intermediate = Dict{Tuple{String,String},Float64}()
    col_value_added = Dict{Tuple{String,String},Float64}()
    fd_totals_after = Dict{Tuple{String,String},Float64}()
    fd_totals_before = Dict{Tuple{String,String},Float64}()

    for pair in io_intermediate
        key = pair[1]
        value = pair[2]
        add_flow!(row_intermediate, (key[1], key[2]), value)
        add_flow!(col_intermediate, (key[3], key[4]), value)
    end
    for pair in io_final
        key = pair[1]
        value = pair[2]
        add_flow!(row_final, (key[1], key[2]), value)
        add_flow!(fd_totals_after, (key[3], key[4]), value)
    end
    for pair in final_demand
        key = pair[1]
        value = pair[2]
        add_flow!(fd_totals_before, (key[3], key[4]), value)
    end
    for pair in value_added
        key = pair[1]
        value = pair[2]
        add_flow!(col_value_added, (key[3], key[4]), value)
    end

    max_abs_row_gap = 0.0
    max_abs_col_gap = 0.0
    max_abs_fd_gap = 0.0
    row_gap_count = 0
    col_gap_count = 0
    fd_gap_count = 0

    for industry in keys(industry_output)
        gap = get(row_intermediate, industry, 0.0) + get(row_final, industry, 0.0) - industry_output[industry]
        abs_gap = abs(gap)
        max_abs_row_gap = max(max_abs_row_gap, abs_gap)
        abs_gap > 1.0e-6 && (row_gap_count += 1)

        cg = get(col_intermediate, industry, 0.0) + get(col_value_added, industry, 0.0) - industry_output[industry]
        abs_cg = abs(cg)
        max_abs_col_gap = max(max_abs_col_gap, abs_cg)
        abs_cg > 1.0e-6 && (col_gap_count += 1)
    end

    for fd in union(keys(fd_totals_before), keys(fd_totals_after))
        gap = get(fd_totals_after, fd, 0.0) - get(fd_totals_before, fd, 0.0)
        abs_gap = abs(gap)
        max_abs_fd_gap = max(max_abs_fd_gap, abs_gap)
        abs_gap > 1.0e-6 && (fd_gap_count += 1)
    end

    write_tsv(OUT_SALES,
        ["product_region", "product_sector", "activity_region", "activity_sector",
         "supply_value_meur", "product_output_meur", "sales_share"],
        sales_rows)
    write_tsv(OUT_INTERMEDIATE,
        ["row_region", "row_sector", "column_region", "column_sector", "value_meur"],
        intermediate_rows)
    write_tsv(OUT_FINAL,
        ["row_region", "row_sector", "final_demand_region", "final_demand_code", "value_meur"],
        final_rows)
    write_tsv(OUT_VALUE_ADDED,
        ["value_added_region", "value_added_code", "column_region", "column_sector", "value_meur"],
        value_added_rows_out)
    write_tsv(OUT_OUTPUT,
        ["region", "sector", "sector_label", "output_meur"],
        industry_output_rows)
    write_tsv(OUT_PRODUCT_OUTPUT,
        ["region", "product_sector", "product_label", "output_meur"],
        product_output_rows)
    write_tsv(OUT_TECH,
        ["row_region", "row_sector", "column_region", "column_sector", "value_meur", "technical_coefficient"],
        tech_rows)

    validation_rows = [
        ["industry_count", string(length(industry_output))],
        ["product_count", string(length(product_output))],
        ["final_demand_column_count", string(length(final_demand_columns))],
        ["value_added_row_count", string(length(value_added_rows))],
        ["total_industry_output", string(sum(values(industry_output)))],
        ["total_product_output", string(sum(values(product_output)))],
        ["total_intermediate_io", string(sum(values(io_intermediate)))],
        ["total_final_demand_io", string(sum(values(io_final)))],
        ["total_value_added", string(sum(values(value_added)))],
        ["max_abs_product_sales_share_gap", string(max_abs_share_gap)],
        ["max_abs_row_gap", string(max_abs_row_gap)],
        ["max_abs_column_gap", string(max_abs_col_gap)],
        ["max_abs_final_demand_gap", string(max_abs_fd_gap)],
        ["row_gap_count_gt_1e-6", string(row_gap_count)],
        ["column_gap_count_gt_1e-6", string(col_gap_count)],
        ["final_demand_gap_count_gt_1e-6", string(fd_gap_count)],
    ]
    write_tsv(OUT_VALIDATION, ["key", "value"], validation_rows)
end

main()
