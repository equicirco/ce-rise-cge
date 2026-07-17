#!/usr/bin/env julia

"""
Close the stage-5 industry-by-industry SAM.

Households receive factor income; households and governments save or borrow
through their regional investment account; external balances are recorded
through the regional external account; and the investment pool closes the
interregional saving-investment balance.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const CORE_DIR = joinpath(ROOT_DIR, "data", "artifacts", "05_core_sam")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "06_closed_sam")

const IN_ACCOUNTS = joinpath(CORE_DIR, "core_sam_accounts.tsv")
const IN_FLOWS = joinpath(CORE_DIR, "core_sam_flows.tsv")

const OUT_ACCOUNTS = joinpath(OUTDIR, "closed_sam_accounts.tsv")
const OUT_FLOWS = joinpath(OUTDIR, "closed_sam_flows.tsv")
const OUT_MATRIX = joinpath(OUTDIR, "closed_sam_matrix.tsv")
const OUT_BALANCES = joinpath(OUTDIR, "closed_sam_account_balances.tsv")
const OUT_SUMMARY = joinpath(OUTDIR, "closed_sam_macro_summary.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "closed_sam_validation.tsv")

const EU_REGIONS = ["DE", "FR", "IT", "PL", "SK", "REU"]
const TOL = 1.0e-8

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

function load_accounts()
    rows = read_tsv(IN_ACCOUNTS)
    return [copy(row) for row in rows[2:end]]
end

function load_flows()
    rows = read_tsv(IN_FLOWS)
    flows = Dict{NTuple{7,String},Float64}()
    for row in rows[2:end]
        key = (row[1], row[2], row[3], row[4], row[5], row[6], row[7])
        flows[key] = get(flows, key, 0.0) + parse(Float64, row[8])
    end
    return flows
end

function add_flow!(flows, row, col, row_type, col_type, kind, source, code, value)
    abs(value) <= TOL && return
    key = (String(row), String(col), String(row_type), String(col_type), String(kind), String(source), String(code))
    flows[key] = get(flows, key, 0.0) + value
end

function account_ids(accounts)
    return [row[1] for row in accounts]
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

function core_flow_total(flows, region, kinds)
    return sum(value for (key, value) in flows if key[5] in kinds && (occursin(":" * region * ":", key[1]) || occursin(":" * region * ":", key[2])))
end

function main()
    ensure_dir(OUTDIR)
    account_rows = load_accounts()
    accounts = account_ids(account_rows)
    flows = load_flows()

    household_saving = Dict{String,Float64}()
    government_saving = Dict{String,Float64}()
    external_balance = Dict{String,Float64}()

    rowsums, colsums = rowcol_sums(flows, accounts)
    for region in EU_REGIONS
        for (factor, kind) in (("LAB", "labour_income_to_households"), ("CAP", "capital_income_to_households"))
            factor_account = factor_id(region, factor)
            gap = rowsums[factor_account] - colsums[factor_account]
            if gap > TOL
                add_flow!(flows, institution_id(region, "HH"), factor_account, "institution", "factor", kind, "closure", factor, gap)
            elseif gap < -TOL
                add_flow!(flows, factor_account, institution_id(region, "HH"), "factor", "institution", "household_transfer_to_$(lowercase(factor))", "closure", factor, -gap)
            end
        end
    end

    rowsums, colsums = rowcol_sums(flows, accounts)
    for region in EU_REGIONS
        hh = institution_id(region, "HH")
        gap = rowsums[hh] - colsums[hh]
        household_saving[region] = gap
        if gap > TOL
            add_flow!(flows, institution_id(region, "INV"), hh, "institution", "institution", "household_saving", "closure", "HH", gap)
        elseif gap < -TOL
            add_flow!(flows, hh, institution_id(region, "INV"), "institution", "institution", "household_borrowing", "closure", "HH", -gap)
        end
    end

    rowsums, colsums = rowcol_sums(flows, accounts)
    for region in EU_REGIONS
        gov = institution_id(region, "GOV")
        gap = rowsums[gov] - colsums[gov]
        government_saving[region] = gap
        if gap > TOL
            add_flow!(flows, institution_id(region, "INV"), gov, "institution", "institution", "government_saving", "closure", "GOV", gap)
        elseif gap < -TOL
            add_flow!(flows, gov, institution_id(region, "INV"), "institution", "institution", "government_borrowing", "closure", "GOV", -gap)
        end
    end

    rowsums, colsums = rowcol_sums(flows, accounts)
    for region in EU_REGIONS
        ext = external_id(region)
        gap = rowsums[ext] - colsums[ext]
        external_balance[region] = gap
        if gap > TOL
            add_flow!(flows, institution_id(region, "INV"), ext, "institution", "external", "foreign_saving", "closure", "EXT", gap)
        elseif gap < -TOL
            add_flow!(flows, ext, institution_id(region, "INV"), "external", "institution", "net_lending_abroad", "closure", "EXT", -gap)
        end
    end

    rowsums, colsums = rowcol_sums(flows, accounts)
    for region in EU_REGIONS
        investment = institution_id(region, "INV")
        gap = rowsums[investment] - colsums[investment]
        if gap > TOL
            add_flow!(flows, investment_pool_id(), investment, "investment_pool", "institution", "interregional_net_lending", "closure", "INV_POOL", gap)
        elseif gap < -TOL
            add_flow!(flows, investment, investment_pool_id(), "institution", "investment_pool", "interregional_financing", "closure", "INV_POOL", -gap)
        end
    end

    rowsums, colsums = rowcol_sums(flows, accounts)
    max_balance = maximum(abs(rowsums[id] - colsums[id]) for id in accounts)
    total_balance = sum(abs(rowsums[id] - colsums[id]) for id in accounts)
    max_balance <= 1.0e-6 || error("Closed SAM is not balanced: maximum account gap is $max_balance")

    summary_rows = Vector{Vector{String}}()
    for region in EU_REGIONS
        push!(summary_rows, [
            region,
            string(core_flow_total(flows, region, Set(["final_demand"]))),
            string(household_saving[region]),
            string(government_saving[region]),
            string(external_balance[region]),
        ])
    end
    validation_rows = [
        ["account_structure", "industry_by_industry"],
        ["n_accounts", string(length(accounts))],
        ["n_industry_accounts", string(count(row -> row[2] == "industry", account_rows))],
        ["max_abs_balance", string(max_balance)],
        ["total_abs_balance", string(total_balance)],
        ["household_npish_rule", "P3_S15 merged into households"],
    ]

    write_tsv(OUT_ACCOUNTS, ["account_id", "account_type", "region", "code", "label"], account_rows)
    write_tsv(OUT_FLOWS, ["row_account_id", "column_account_id", "row_type", "column_type", "flow_kind", "source_table", "source_code", "value"], flow_rows(flows))
    write_tsv(OUT_MATRIX, vcat(["account_id"], accounts), matrix_rows(accounts, flows))
    write_tsv(OUT_BALANCES, ["account_id", "account_type", "region", "code", "row_sum", "column_sum", "balance"], balance_rows(account_rows, flows))
    write_tsv(OUT_SUMMARY, ["region", "final_demand", "household_saving", "government_saving", "external_balance"], summary_rows)
    write_tsv(OUT_VALIDATION, ["key", "value"], validation_rows)
    println("Wrote stage-6 closed industry-by-industry SAM artifacts to ", OUTDIR)
end

main()
