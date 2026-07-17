#!/usr/bin/env julia

"""
Build the stage-5 core industry-by-industry SAM artifact set.

The source is the symmetric industry-by-industry IO table produced at stage 4b.
Each of the six European regions has one account for each retained industry,
two factor accounts, three institutional accounts, and one external account.
The global investment-pool account is included for the stage-6 closure.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const IO_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04b_symmetric_io")
const SUT_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04_balanced_sut")
const SECTOR_DIR = joinpath(ROOT_DIR, "data", "artifacts", "03_final_preparation")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "05_core_sam")

const IN_INTERMEDIATE = joinpath(IO_DIR, "industry_by_industry_intermediate.tsv")
const IN_FINAL = joinpath(IO_DIR, "industry_by_final_demand.tsv")
const IN_VALUE_ADDED = joinpath(IO_DIR, "value_added_by_industry.tsv")
const IN_BALANCED_USE = joinpath(SUT_DIR, "balanced_use.tsv")
const IN_SECTORS = joinpath(SECTOR_DIR, "explicit_final_sector_registry.tsv")

const OUT_ACCOUNTS = joinpath(OUTDIR, "core_sam_accounts.tsv")
const OUT_FLOWS = joinpath(OUTDIR, "core_sam_flows.tsv")
const OUT_MATRIX = joinpath(OUTDIR, "core_sam_matrix.tsv")
const OUT_BALANCES = joinpath(OUTDIR, "core_sam_account_balances.tsv")
const OUT_BLOCKS = joinpath(OUTDIR, "core_sam_block_totals.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "core_sam_validation.tsv")

const EU_REGIONS = ["DE", "FR", "IT", "PL", "SK", "REU"]
const EU_REGION_SET = Set(EU_REGIONS)
const ROW_REGION = "ROW"
const TOL = 1.0e-10

industry_id(region, code) = "IND:$region:$code"
factor_id(region, code) = "FAC:$region:$code"
institution_id(region, code) = "INS:$region:$code"
external_id(region) = "EXT:$region:EXT"
investment_pool_id() = "INS:GLOBAL:INV_POOL"

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

function load_sector_rows()
    rows = read_tsv(IN_SECTORS)
    return [(code = row[1], label = row[2]) for row in rows[2:end]]
end

function final_demand_account(region::String, code::String)
    if code == "P3_S13"
        return institution_id(region, "GOV"), "institution"
    elseif code == "P3_S14" || code == "P3_S15"
        return institution_id(region, "HH"), "institution"
    elseif code == "P51G" || code == "P5M"
        return institution_id(region, "INV"), "institution"
    end
    error("Unexpected final-demand code $code")
end

function add_flow!(
    flows::Dict{NTuple{7,String},Float64},
    row::String,
    col::String,
    row_type::String,
    col_type::String,
    kind::String,
    source::String,
    code::String,
    value::Float64,
)
    abs(value) <= TOL && return
    key = (row, col, row_type, col_type, kind, source, code)
    flows[key] = get(flows, key, 0.0) + value
end

function account_rows(sectors)
    rows = Vector{Vector{String}}()
    for region in EU_REGIONS
        for sector in sectors
            push!(rows, [industry_id(region, sector.code), "industry", region, sector.code, "$region industry: $(sector.label)"])
        end
        push!(rows, [factor_id(region, "LAB"), "factor", region, "LAB", "$region factor: Labour"])
        push!(rows, [factor_id(region, "CAP"), "factor", region, "CAP", "$region factor: Capital"])
        push!(rows, [institution_id(region, "HH"), "institution", region, "HH", "$region institution: Households (+ NPISH)"])
        push!(rows, [institution_id(region, "GOV"), "institution", region, "GOV", "$region institution: Government"])
        push!(rows, [institution_id(region, "INV"), "institution", region, "INV", "$region institution: Investment"])
        push!(rows, [external_id(region), "external", region, "EXT", "$region external account"])
    end
    push!(rows, [investment_pool_id(), "investment_pool", "GLOBAL", "INV_POOL", "Global interregional investment pool"])
    return rows
end

function add_intermediate_flows!(flows)
    rows = read_tsv(IN_INTERMEDIATE)
    for row in rows[2:end]
        origin_region, origin_sector, use_region, use_sector, value_text = row
        value = parse(Float64, value_text)
        if origin_region in EU_REGION_SET && use_region in EU_REGION_SET
            add_flow!(flows, industry_id(origin_region, origin_sector), industry_id(use_region, use_sector), "industry", "industry", "intermediate_demand", "symmetric_io", origin_sector, value)
        elseif origin_region in EU_REGION_SET && use_region == ROW_REGION
            add_flow!(flows, industry_id(origin_region, origin_sector), external_id(origin_region), "industry", "external", "export_to_row", "symmetric_io", origin_sector, value)
        elseif origin_region == ROW_REGION && use_region in EU_REGION_SET
            add_flow!(flows, external_id(use_region), industry_id(use_region, use_sector), "external", "industry", "import_from_row_intermediate", "symmetric_io", use_sector, value)
        end
    end
end

function add_final_demand_flows!(flows)
    rows = read_tsv(IN_FINAL)
    for row in rows[2:end]
        origin_region, origin_sector, demand_region, demand_code, value_text = row
        value = parse(Float64, value_text)
        if origin_region in EU_REGION_SET && demand_region in EU_REGION_SET
            account, account_type = final_demand_account(demand_region, demand_code)
            add_flow!(flows, industry_id(origin_region, origin_sector), account, "industry", account_type, "final_demand", "symmetric_io", demand_code, value)
        elseif origin_region in EU_REGION_SET && demand_region == ROW_REGION
            add_flow!(flows, industry_id(origin_region, origin_sector), external_id(origin_region), "industry", "external", "export_to_row", "symmetric_io", demand_code, value)
        elseif origin_region == ROW_REGION && demand_region in EU_REGION_SET
            account, account_type = final_demand_account(demand_region, demand_code)
            add_flow!(flows, external_id(demand_region), account, "external", account_type, "import_from_row_$(lowercase(account_type))", "symmetric_io", demand_code, value)
        end
    end
end

function add_value_added_flows!(flows)
    rows = read_tsv(IN_VALUE_ADDED)
    for row in rows[2:end]
        value_added_region, value_added_code, industry_region, industry_sector, value_text = row
        industry_region in EU_REGION_SET || continue
        value_added_region == industry_region || continue
        value = parse(Float64, value_text)
        row_id, row_type, kind =
            value_added_code == "D1" ? (factor_id(industry_region, "LAB"), "factor", "labour_income") :
            value_added_code == "B2A3G" ? (factor_id(industry_region, "CAP"), "factor", "capital_income") :
            value_added_code == "D21X31" ? (institution_id(industry_region, "GOV"), "institution", "product_taxes_less_subsidies") :
            value_added_code == "D29X39" ? (institution_id(industry_region, "GOV"), "institution", "production_taxes_less_subsidies") :
            error("Unexpected value-added row $value_added_code")
        add_flow!(flows, row_id, industry_id(industry_region, industry_sector), row_type, "industry", kind, "symmetric_io", value_added_code, value)
    end
end

function add_tourism_flows!(flows)
    rows = read_tsv(IN_BALANCED_USE)
    for row in rows[2:end]
        product_region, product_sector, use_region, _, value_text = row
        product_region in EU_REGION_SET || continue
        use_region in EU_REGION_SET || continue
        value = parse(Float64, value_text)
        if product_sector == "OP_NRES"
            add_flow!(flows, institution_id(use_region, "HH"), external_id(use_region), "institution", "external", "tourism_inbound_adjustment", "balanced_sut", product_sector, value)
        elseif product_sector == "OP_RES"
            add_flow!(flows, external_id(use_region), institution_id(use_region, "HH"), "external", "institution", "tourism_outbound_adjustment", "balanced_sut", product_sector, value)
        end
    end
end

function account_ids(account_rows)
    return [row[1] for row in account_rows]
end

function rowcol_sums(flows, accounts)
    rowsums = Dict(account => 0.0 for account in accounts)
    colsums = Dict(account => 0.0 for account in accounts)
    for (key, value) in flows
        rowsums[key[1]] = get(rowsums, key[1], 0.0) + value
        colsums[key[2]] = get(colsums, key[2], 0.0) + value
    end
    return rowsums, colsums
end

function flow_rows(flows)
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(flows)))
        push!(rows, [key[1], key[2], key[3], key[4], key[5], key[6], key[7], string(flows[key])])
    end
    return rows
end

function matrix_rows(accounts, flows)
    values = Dict{Tuple{String,String},Float64}()
    for (key, value) in flows
        pair = (key[1], key[2])
        values[pair] = get(values, pair, 0.0) + value
    end
    rows = Vector{Vector{String}}()
    for row_account in accounts
        row = [row_account]
        for col_account in accounts
            push!(row, string(get(values, (row_account, col_account), 0.0)))
        end
        push!(rows, row)
    end
    return rows
end

function balance_rows(account_rows, flows)
    accounts = account_ids(account_rows)
    rowsums, colsums = rowcol_sums(flows, accounts)
    return [[row[1], row[2], row[3], row[4], string(rowsums[row[1]]), string(colsums[row[1]]), string(rowsums[row[1]] - colsums[row[1]])] for row in account_rows]
end

function main()
    ensure_dir(OUTDIR)
    sectors = load_sector_rows()
    accounts = account_rows(sectors)
    flows = Dict{NTuple{7,String},Float64}()

    add_intermediate_flows!(flows)
    add_final_demand_flows!(flows)
    add_value_added_flows!(flows)
    add_tourism_flows!(flows)

    ids = account_ids(accounts)
    rowsums, colsums = rowcol_sums(flows, ids)
    preliminary_gaps = [abs(rowsums[id] - colsums[id]) for id in ids]
    blocks = [
        ["intermediate_industry_flows", string(sum(value for (key, value) in flows if key[5] == "intermediate_demand"))],
        ["final_demand_flows", string(sum(value for (key, value) in flows if key[5] == "final_demand"))],
        ["extra_europe_exports", string(sum(value for (key, value) in flows if key[5] == "export_to_row"))],
        ["extra_europe_imports", string(sum(value for (key, value) in flows if startswith(key[5], "import_from_row")))],
    ]
    validation = [
        ["account_structure", "industry_by_industry"],
        ["n_industries_per_region", string(length(sectors))],
        ["n_regions", string(length(EU_REGIONS))],
        ["n_accounts", string(length(ids))],
        ["max_abs_preclosure_balance", string(maximum(preliminary_gaps))],
    ]

    write_tsv(OUT_ACCOUNTS, ["account_id", "account_type", "region", "code", "label"], accounts)
    write_tsv(OUT_FLOWS, ["row_account_id", "column_account_id", "row_type", "column_type", "flow_kind", "source_table", "source_code", "value"], flow_rows(flows))
    write_tsv(OUT_MATRIX, vcat(["account_id"], ids), matrix_rows(ids, flows))
    write_tsv(OUT_BALANCES, ["account_id", "account_type", "region", "code", "row_sum", "column_sum", "balance"], balance_rows(accounts, flows))
    write_tsv(OUT_BLOCKS, ["block", "value_meur"], blocks)
    write_tsv(OUT_VALIDATION, ["key", "value"], validation)
    println("Wrote stage-5 industry-by-industry core SAM artifacts to ", OUTDIR)
end

main()
