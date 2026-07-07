#!/usr/bin/env julia

"""
Build the stage-5 core SAM artifact set.

Stage 5 extracts an incomplete square SAM from the balanced SUT.

What is included:
- region-specific activity accounts from the balanced supply/use tables;
- region-specific commodity accounts from the balanced supply/use tables;
- region-specific final-demand accounts from the balanced use table;
- region-specific satellite accounts for value added, taxes, and tourism
  adjustments from the special non-commodity rows.

What is intentionally left open:
- no household, government, savings-investment, or rest-of-world closure is
  imposed yet;
- satellite accounts therefore collect receipts without their later
  redistribution columns;
- final-demand accounts therefore keep their expenditure columns without their
  later income rows.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const ARTIFACT4_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04_balanced_sut")
const ARTIFACT3_DIR = joinpath(ROOT_DIR, "data", "artifacts", "03_final_preparation")
const ARTIFACT1_DIR = joinpath(ROOT_DIR, "data", "artifacts", "01_initial_data")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "05_core_sam")

const IN_SUPPLY = joinpath(ARTIFACT4_DIR, "balanced_supply.tsv")
const IN_USE = joinpath(ARTIFACT4_DIR, "balanced_use.tsv")
const SECTOR_REGISTRY = joinpath(ARTIFACT3_DIR, "explicit_final_sector_registry.tsv")
const CODE_MAP = joinpath(ARTIFACT1_DIR, "figaro_reference_code_map.tsv")

const OUT_ACCOUNTS = joinpath(OUTDIR, "core_sam_accounts.tsv")
const OUT_FLOWS = joinpath(OUTDIR, "core_sam_flows.tsv")
const OUT_MATRIX = joinpath(OUTDIR, "core_sam_matrix.tsv")
const OUT_BALANCES = joinpath(OUTDIR, "core_sam_account_balances.tsv")
const OUT_BLOCKS = joinpath(OUTDIR, "core_sam_block_totals.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "core_sam_validation.tsv")

const SPECIAL_CODES = Set(["B2A3G", "D1", "D21X31", "D29X39", "OP_NRES", "OP_RES"])
const TYPE_ORDER = Dict(
    "activity" => 1,
    "commodity" => 2,
    "final_demand" => 3,
    "satellite" => 4,
)

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

function load_sector_labels(path::AbstractString)
    rows = read_tsv(path)
    labels = Dict{String,String}()
    for row in rows[2:end]
        labels[row[1]] = row[2]
    end
    return labels
end

function load_code_labels(path::AbstractString)
    rows = read_tsv(path)
    labels = Dict{String,String}()
    for row in rows
        length(row) < 3 && continue
        code = row[2]
        label = row[3]
        labels[code] = label
    end
    return labels
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

activity_id(region::AbstractString, code::AbstractString) = "ACT:$region:$code"
commodity_id(region::AbstractString, code::AbstractString) = "COM:$region:$code"
final_demand_id(region::AbstractString, code::AbstractString) = "FD:$region:$code"
satellite_id(region::AbstractString, code::AbstractString) = "SAT:$region:$code"

function add_flow!(
    flows::Dict{Tuple{String,String,String,String,String,String,String},Float64},
    from_id::String,
    to_id::String,
    from_type::String,
    to_type::String,
    flow_kind::String,
    source_table::String,
    source_code::String,
    value::Float64,
)
    abs(value) <= 1.0e-12 && return
    key = (from_id, to_id, from_type, to_type, flow_kind, source_table, source_code)
    flows[key] = get(flows, key, 0.0) + value
end

function sorted_rows(dict::Dict{Tuple{String,String,String,String,String,String,String},Float64})
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(dict)))
        push!(rows, [
            key[1],
            key[2],
            key[3],
            key[4],
            key[5],
            key[6],
            key[7],
            string(dict[key]),
        ])
    end
    return rows
end

function account_label(prefix::String, region::String, code::String, sector_labels, code_labels)
    if prefix == "ACT"
        return "$region activity: $(get(sector_labels, code, code))"
    elseif prefix == "COM"
        return "$region commodity: $(get(sector_labels, code, code))"
    elseif prefix == "FD"
        return "$region final demand: $(get(code_labels, code, code))"
    else
        return "$region satellite: $(get(code_labels, code, code))"
    end
end

function build_account_registry(supply_entries, use_entries, sector_labels, code_labels)
    rows = Vector{Vector{String}}()
    seen = Set{String}()

    activity_codes = sort!(unique(entry.activity_sector for entry in supply_entries))
    commodity_codes = sort!(unique(entry.product_sector for entry in supply_entries))
    regions = sort!(unique(entry.activity_region for entry in supply_entries))

    for region in regions
        for code in activity_codes
            id = activity_id(region, code)
            id in seen && continue
            push!(seen, id)
            push!(rows, [id, "activity", region, code, account_label("ACT", region, code, sector_labels, code_labels)])
        end
    end

    for region in regions
        for code in commodity_codes
            id = commodity_id(region, code)
            id in seen && continue
            push!(seen, id)
            push!(rows, [id, "commodity", region, code, account_label("COM", region, code, sector_labels, code_labels)])
        end
    end

    final_demand_codes = sort!(unique(entry.use_code for entry in use_entries if !(entry.use_code in activity_codes) && !(entry.product_sector in SPECIAL_CODES)))
    for region in sort!(unique(entry.use_region for entry in use_entries))
        for code in final_demand_codes
            id = final_demand_id(region, code)
            id in seen && continue
            push!(seen, id)
            push!(rows, [id, "final_demand", region, code, account_label("FD", region, code, sector_labels, code_labels)])
        end
    end

    satellite_pairs = Set{Tuple{String,String}}()
    for entry in use_entries
        if entry.product_sector in SPECIAL_CODES
            push!(satellite_pairs, (entry.use_region, entry.product_sector))
        end
    end
    for pair in sort!(collect(satellite_pairs))
        region = pair[1]
        code = pair[2]
        id = satellite_id(region, code)
        id in seen && continue
        push!(seen, id)
        push!(rows, [id, "satellite", region, code, account_label("SAT", region, code, sector_labels, code_labels)])
    end

    sort!(rows, by = row -> (TYPE_ORDER[row[2]], row[3], row[4]))
    return rows, Set(activity_codes)
end

function build_flow_table(supply_entries, use_entries, activity_codes::Set{String})
    flows = Dict{Tuple{String,String,String,String,String,String,String},Float64}()

    for entry in supply_entries
        add_flow!(
            flows,
            activity_id(entry.activity_region, entry.activity_sector),
            commodity_id(entry.product_region, entry.product_sector),
            "activity",
            "commodity",
            "make",
            "balanced_supply",
            entry.product_sector,
            entry.value,
        )
    end

    for entry in use_entries
        if entry.product_sector in SPECIAL_CODES
            target_id = entry.use_code in activity_codes ?
                activity_id(entry.use_region, entry.use_code) :
                final_demand_id(entry.use_region, entry.use_code)

            target_type = entry.use_code in activity_codes ? "activity" : "final_demand"

            flow_kind =
                entry.product_sector == "D1" ? "compensation_of_employees" :
                entry.product_sector == "B2A3G" ? "operating_surplus_mixed_income" :
                entry.product_sector == "D29X39" ? "other_taxes_less_subsidies_on_production" :
                entry.product_sector == "D21X31" ? "taxes_less_subsidies_on_products" :
                entry.product_sector == "OP_NRES" ? "purchases_on_domestic_territory_by_non_residents" :
                "direct_purchases_abroad_by_residents"

            add_flow!(
                flows,
                satellite_id(entry.use_region, entry.product_sector),
                target_id,
                "satellite",
                target_type,
                flow_kind,
                "balanced_use_special_rows",
                entry.product_sector,
                entry.value,
            )
        else
            if entry.use_code in activity_codes
                add_flow!(
                    flows,
                    commodity_id(entry.product_region, entry.product_sector),
                    activity_id(entry.use_region, entry.use_code),
                    "commodity",
                    "activity",
                    "intermediate_demand",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            else
                add_flow!(
                    flows,
                    commodity_id(entry.product_region, entry.product_sector),
                    final_demand_id(entry.use_region, entry.use_code),
                    "commodity",
                    "final_demand",
                    "final_demand",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            end
        end
    end

    return flows
end

function build_matrix(accounts::Vector{Vector{String}}, flows::Dict{Tuple{String,String,String,String,String,String,String},Float64})
    account_ids = [row[1] for row in accounts]
    index = Dict{String,Int}()
    for (i, id) in enumerate(account_ids)
        index[id] = i
    end

    n = length(account_ids)
    matrix = zeros(Float64, n, n)
    for key in keys(flows)
        i = index[key[1]]
        j = index[key[2]]
        matrix[i, j] += flows[key]
    end

    rows = Vector{Vector{String}}()
    for i in 1:n
        push!(rows, vcat([account_ids[i]], [string(matrix[i, j]) for j in 1:n]))
    end
    header = vcat(["account_id"], account_ids)
    return header, rows, matrix, account_ids
end

function balance_rows(accounts::Vector{Vector{String}}, matrix, account_ids)
    rows = Vector{Vector{String}}()
    for i in eachindex(account_ids)
        row_sum = sum(matrix[i, :])
        col_sum = sum(matrix[:, i])
        push!(rows, [
            account_ids[i],
            accounts[i][2],
            accounts[i][3],
            accounts[i][4],
            string(row_sum),
            string(col_sum),
            string(row_sum - col_sum),
        ])
    end
    return rows
end

function block_rows(accounts::Vector{Vector{String}}, matrix, account_ids)
    types = [row[2] for row in accounts]
    rows = Vector{Vector{String}}()
    uniq_types = ["activity", "commodity", "final_demand", "satellite"]
    idx_by_type = Dict{String,Vector{Int}}()
    for t in uniq_types
        idx_by_type[t] = [i for i in eachindex(types) if types[i] == t]
    end
    for from_type in uniq_types
        for to_type in uniq_types
            total = 0.0
            for i in idx_by_type[from_type], j in idx_by_type[to_type]
                total += matrix[i, j]
            end
            push!(rows, [from_type, to_type, string(total)])
        end
    end
    return rows
end

function validation_rows(accounts::Vector{Vector{String}}, balance_rows_data::Vector{Vector{String}})
    counts = Dict{String,Int}()
    for row in accounts
        counts[row[2]] = get(counts, row[2], 0) + 1
    end

    commodity_imbalances = Float64[]
    activity_imbalances = Float64[]
    final_demand_imbalances = Float64[]
    satellite_imbalances = Float64[]

    for row in balance_rows_data
        imbalance = parse(Float64, row[7])
        if row[2] == "commodity"
            push!(commodity_imbalances, imbalance)
        elseif row[2] == "activity"
            push!(activity_imbalances, imbalance)
        elseif row[2] == "final_demand"
            push!(final_demand_imbalances, imbalance)
        else
            push!(satellite_imbalances, imbalance)
        end
    end

    return [
        ["n_activity_accounts", string(get(counts, "activity", 0))],
        ["n_commodity_accounts", string(get(counts, "commodity", 0))],
        ["n_final_demand_accounts", string(get(counts, "final_demand", 0))],
        ["n_satellite_accounts", string(get(counts, "satellite", 0))],
        ["max_abs_commodity_imbalance", string(maximum(abs.(commodity_imbalances)))],
        ["max_abs_activity_imbalance", string(maximum(abs.(activity_imbalances)))],
        ["total_final_demand_net_position", string(sum(final_demand_imbalances))],
        ["total_satellite_net_position", string(sum(satellite_imbalances))],
        ["stage5_status", "incomplete_by_design"],
        ["stage5_boundary", "no_income_allocation_or_macro_closure_yet"],
    ]
end

function main()
    ensure_dir(OUTDIR)

    sector_labels = load_sector_labels(SECTOR_REGISTRY)
    code_labels = load_code_labels(CODE_MAP)
    supply_entries = load_supply_entries(IN_SUPPLY)
    use_entries = load_use_entries(IN_USE)

    accounts, activity_codes = build_account_registry(supply_entries, use_entries, sector_labels, code_labels)
    flows = build_flow_table(supply_entries, use_entries, activity_codes)
    flow_rows = sorted_rows(flows)

    matrix_header, matrix_rows, matrix, account_ids = build_matrix(accounts, flows)
    account_balance_rows = balance_rows(accounts, matrix, account_ids)
    block_total_rows = block_rows(accounts, matrix, account_ids)
    validation = validation_rows(accounts, account_balance_rows)

    write_tsv(OUT_ACCOUNTS, ["account_id", "account_type", "region", "source_code", "account_label"], accounts)
    write_tsv(
        OUT_FLOWS,
        ["from_account", "to_account", "from_type", "to_type", "flow_kind", "source_table", "source_code", "value_meur"],
        flow_rows,
    )
    write_tsv(OUT_MATRIX, matrix_header, matrix_rows)
    write_tsv(
        OUT_BALANCES,
        ["account_id", "account_type", "region", "source_code", "row_sum_meur", "column_sum_meur", "imbalance_meur"],
        account_balance_rows,
    )
    write_tsv(OUT_BLOCKS, ["from_type", "to_type", "value_meur"], block_total_rows)
    write_tsv(OUT_VALIDATION, ["key", "value"], validation)

    println("Wrote stage-5 artifacts to ", OUTDIR)
end

main()
