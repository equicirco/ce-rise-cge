#!/usr/bin/env julia

"""
Build the stage-6 closed benchmark SAM artifact set.

Stage 6 turns the balanced SUT into a region-by-region benchmark SAM with a
minimal macro closure.

Closure rules used here:
- households receive regional labor and capital income;
- NPISH final demand is merged into households;
- governments receive production and product taxes and purchase government
  final demand;
- investment demand is financed by household saving, government saving, and a
  region-specific external-balance account representing the rest of the world;
- any small residual activity-account gap left after the SUT balancing step is
  assigned to regional capital income as the residual claimant.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const ARTIFACT4_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04_balanced_sut")
const ARTIFACT3_DIR = joinpath(ROOT_DIR, "data", "artifacts", "03_final_preparation")
const ARTIFACT1_DIR = joinpath(ROOT_DIR, "data", "artifacts", "01_initial_data")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "06_closed_sam")

const IN_SUPPLY = joinpath(ARTIFACT4_DIR, "balanced_supply.tsv")
const IN_USE = joinpath(ARTIFACT4_DIR, "balanced_use.tsv")
const SECTOR_REGISTRY = joinpath(ARTIFACT3_DIR, "explicit_final_sector_registry.tsv")
const CODE_MAP = joinpath(ARTIFACT1_DIR, "figaro_reference_code_map.tsv")

const OUT_ACCOUNTS = joinpath(OUTDIR, "closed_sam_accounts.tsv")
const OUT_FLOWS = joinpath(OUTDIR, "closed_sam_flows.tsv")
const OUT_MATRIX = joinpath(OUTDIR, "closed_sam_matrix.tsv")
const OUT_BALANCES = joinpath(OUTDIR, "closed_sam_account_balances.tsv")
const OUT_SUMMARY = joinpath(OUTDIR, "closed_sam_macro_summary.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "closed_sam_validation.tsv")

const SPECIAL_CODES = Set(["B2A3G", "D1", "D21X31", "D29X39", "OP_NRES", "OP_RES"])
const HH_FINAL_CODES = Set(["P3_S14", "P3_S15"])
const GOV_FINAL_CODES = Set(["P3_S13"])
const INV_FINAL_CODES = Set(["P51G", "P5M"])
const EU_REGIONS = ["DE", "FR", "IT", "PL", "SK", "REU"]
const TYPE_ORDER = Dict(
    "activity" => 1,
    "commodity" => 2,
    "factor" => 3,
    "institution" => 4,
    "external" => 5,
)
const TOL = 1.0e-8

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
        labels[row[2]] = row[3]
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
factor_id(region::AbstractString, code::AbstractString) = "FAC:$region:$code"
institution_id(region::AbstractString, code::AbstractString) = "INS:$region:$code"
external_id(region::AbstractString) = "EXT:$region"

function add_flow!(
    flows::Dict{Tuple{String,String,String,String,String,String,String},Float64},
    row_id::String,
    col_id::String,
    row_type::String,
    col_type::String,
    flow_kind::String,
    source_table::String,
    source_code::String,
    value::Float64,
)
    abs(value) <= 1.0e-12 && return
    key = (row_id, col_id, row_type, col_type, flow_kind, source_table, source_code)
    flows[key] = get(flows, key, 0.0) + value
end

function account_label(prefix::String, region::String, code::String, sector_labels, code_labels)
    if prefix == "ACT"
        return "$region activity: $(get(sector_labels, code, code))"
    elseif prefix == "COM"
        return "$region commodity: $(get(sector_labels, code, code))"
    elseif prefix == "FAC"
        return code == "LAB" ? "$region factor: Labor" : "$region factor: Capital"
    elseif prefix == "INS"
        return code == "HH" ? "$region institution: Households (+ NPISH)" :
               code == "GOV" ? "$region institution: Government" :
               code == "INV_POOL" ? "EU institution: Interregional investment pool" :
               "$region institution: Investment"
    else
        return "$region external: Rest of world"
    end
end

function payer_account(region::AbstractString, code::AbstractString, activity_codes::Set{String})
    if code in activity_codes
        return activity_id(region, code), "activity"
    elseif code in HH_FINAL_CODES
        return institution_id(region, "HH"), "institution"
    elseif code in GOV_FINAL_CODES
        return institution_id(region, "GOV"), "institution"
    elseif code in INV_FINAL_CODES
        return institution_id(region, "INV"), "institution"
    end
    error("Unexpected payer code $(code) in region $(region)")
end

function build_account_registry(regions, activity_codes, commodity_codes, sector_labels, code_labels)
    rows = Vector{Vector{String}}()

    for region in regions
        for code in activity_codes
            push!(rows, [activity_id(region, code), "activity", region, code, account_label("ACT", region, code, sector_labels, code_labels)])
        end
    end

    for region in regions
        for code in commodity_codes
            push!(rows, [commodity_id(region, code), "commodity", region, code, account_label("COM", region, code, sector_labels, code_labels)])
        end
    end

    for region in regions, code in ("LAB", "CAP")
        push!(rows, [factor_id(region, code), "factor", region, code, account_label("FAC", region, code, sector_labels, code_labels)])
    end

    for region in regions, code in ("HH", "GOV", "INV")
        push!(rows, [institution_id(region, code), "institution", region, code, account_label("INS", region, code, sector_labels, code_labels)])
    end
    push!(rows, [institution_id("GLOBAL", "INV_POOL"), "institution", "GLOBAL", "INV_POOL", account_label("INS", "GLOBAL", "INV_POOL", sector_labels, code_labels)])

    for region in regions
        push!(rows, [external_id(region), "external", region, "EXT", account_label("EXT", region, "EXT", sector_labels, code_labels)])
    end

    sort!(rows, by = row -> (TYPE_ORDER[row[2]], row[3], row[4]))
    return rows
end

function row_col_sums(flows)
    rowsums = Dict{String,Float64}()
    colsums = Dict{String,Float64}()
    for (key, value) in flows
        rowsums[key[1]] = get(rowsums, key[1], 0.0) + value
        colsums[key[2]] = get(colsums, key[2], 0.0) + value
    end
    return rowsums, colsums
end

function activity_gap(rowsums, colsums, region::AbstractString, code::AbstractString)
    id = activity_id(region, code)
    return get(rowsums, id, 0.0) - get(colsums, id, 0.0)
end

function add_activity_residual_capital!(flows, regions, activity_codes)
    rowsums, colsums = row_col_sums(flows)
    summary = Dict{Tuple{String,String},Float64}()

    for region in regions
        for code in activity_codes
            gap = activity_gap(rowsums, colsums, region, code)
            summary[(region, code)] = gap
            if gap > TOL
                add_flow!(
                    flows,
                    factor_id(region, "CAP"),
                    activity_id(region, code),
                    "factor",
                    "activity",
                    "capital_residual_claim",
                    "activity_balance_residual",
                    code,
                    gap,
                )
            elseif gap < -TOL
                add_flow!(
                    flows,
                    activity_id(region, code),
                    factor_id(region, "CAP"),
                    "activity",
                    "factor",
                    "capital_support_residual",
                    "activity_balance_residual",
                    code,
                    -gap,
                )
            end
        end
    end
    return summary
end

function sorted_flow_rows(flows)
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(flows)))
        push!(rows, [
            key[1],
            key[2],
            key[3],
            key[4],
            key[5],
            key[6],
            key[7],
            string(flows[key]),
        ])
    end
    return rows
end

function build_matrix(accounts, flows)
    account_ids = [row[1] for row in accounts]
    index = Dict(id => i for (i, id) in enumerate(account_ids))
    matrix = zeros(Float64, length(account_ids), length(account_ids))
    for (key, value) in flows
        matrix[index[key[1]], index[key[2]]] += value
    end
    return account_ids, matrix
end

function matrix_rows(account_ids, matrix)
    header = vcat(["account_id"], account_ids)
    rows = Vector{Vector{String}}()
    for (i, id) in enumerate(account_ids)
        push!(rows, vcat([id], [string(matrix[i, j]) for j in eachindex(account_ids)]))
    end
    return header, rows
end

function balance_rows(accounts, matrix)
    rows = Vector{Vector{String}}()
    max_abs = 0.0
    total_abs = 0.0
    for (i, account) in enumerate(accounts)
        row_sum = sum(matrix[i, :])
        col_sum = sum(matrix[:, i])
        balance = row_sum - col_sum
        max_abs = max(max_abs, abs(balance))
        total_abs += abs(balance)
        push!(rows, [account[1], account[2], account[3], account[4], string(row_sum), string(col_sum), string(balance)])
    end
    return rows, max_abs, total_abs
end

function main()
    ensure_dir(OUTDIR)

    sector_labels = load_sector_labels(SECTOR_REGISTRY)
    code_labels = load_code_labels(CODE_MAP)
    supply_entries = load_supply_entries(IN_SUPPLY)
    use_entries = load_use_entries(IN_USE)

    regions = copy(EU_REGIONS)
    activity_codes = sort!(unique(entry.activity_sector for entry in supply_entries))
    commodity_codes = sort!(unique(entry.product_sector for entry in supply_entries))
    activity_code_set = Set(activity_codes)

    accounts = build_account_registry(regions, activity_codes, commodity_codes, sector_labels, code_labels)
    flows = Dict{Tuple{String,String,String,String,String,String,String},Float64}()

    household_consumption = Dict(region => 0.0 for region in regions)
    government_consumption = Dict(region => 0.0 for region in regions)
    investment_demand = Dict(region => 0.0 for region in regions)
    tourism_in = Dict(region => 0.0 for region in regions)
    tourism_out = Dict(region => 0.0 for region in regions)

    for entry in supply_entries
        (entry.product_region in EU_REGIONS && entry.activity_region in EU_REGIONS) || continue
        add_flow!(
            flows,
            activity_id(entry.activity_region, entry.activity_sector),
            commodity_id(entry.product_region, entry.product_sector),
            "activity",
            "commodity",
            "make_supply",
            "balanced_supply",
            entry.product_sector,
            entry.value,
        )
    end

    for entry in use_entries
        use_region_eu = entry.use_region in EU_REGIONS
        product_region_eu = entry.product_region in EU_REGIONS

        if !use_region_eu
            if product_region_eu && !(entry.product_sector in SPECIAL_CODES)
                add_flow!(
                    flows,
                    commodity_id(entry.product_region, entry.product_sector),
                    external_id(entry.product_region),
                    "commodity",
                    "external",
                    "export_to_row",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            end
            continue
        end

        if !(entry.product_sector in SPECIAL_CODES)
            if product_region_eu
                if entry.use_code in activity_code_set
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
                elseif entry.use_code in HH_FINAL_CODES
                    household_consumption[entry.use_region] += entry.value
                    add_flow!(
                        flows,
                        commodity_id(entry.product_region, entry.product_sector),
                        institution_id(entry.use_region, "HH"),
                        "commodity",
                        "institution",
                        "household_final_demand",
                        "balanced_use",
                        entry.product_sector,
                        entry.value,
                    )
                elseif entry.use_code in GOV_FINAL_CODES
                    government_consumption[entry.use_region] += entry.value
                    add_flow!(
                        flows,
                        commodity_id(entry.product_region, entry.product_sector),
                        institution_id(entry.use_region, "GOV"),
                        "commodity",
                        "institution",
                        "government_final_demand",
                        "balanced_use",
                        entry.product_sector,
                        entry.value,
                    )
                elseif entry.use_code in INV_FINAL_CODES
                    investment_demand[entry.use_region] += entry.value
                    add_flow!(
                        flows,
                        commodity_id(entry.product_region, entry.product_sector),
                        institution_id(entry.use_region, "INV"),
                        "commodity",
                        "institution",
                        "investment_demand",
                        "balanced_use",
                        entry.product_sector,
                        entry.value,
                    )
                else
                    error("Unhandled non-special use code $(entry.use_code)")
                end
            elseif entry.use_code in activity_code_set
                add_flow!(
                    flows,
                    external_id(entry.use_region),
                    activity_id(entry.use_region, entry.use_code),
                    "external",
                    "activity",
                    "import_from_row_intermediate",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            elseif entry.use_code in HH_FINAL_CODES
                household_consumption[entry.use_region] += entry.value
                add_flow!(
                    flows,
                    external_id(entry.use_region),
                    institution_id(entry.use_region, "HH"),
                    "external",
                    "institution",
                    "import_from_row_households",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            elseif entry.use_code in GOV_FINAL_CODES
                government_consumption[entry.use_region] += entry.value
                add_flow!(
                    flows,
                    external_id(entry.use_region),
                    institution_id(entry.use_region, "GOV"),
                    "external",
                    "institution",
                    "import_from_row_government",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            elseif entry.use_code in INV_FINAL_CODES
                investment_demand[entry.use_region] += entry.value
                add_flow!(
                    flows,
                    external_id(entry.use_region),
                    institution_id(entry.use_region, "INV"),
                    "external",
                    "institution",
                    "import_from_row_investment",
                    "balanced_use",
                    entry.product_sector,
                    entry.value,
                )
            else
                error("Unhandled ROW import use code $(entry.use_code)")
            end
            continue
        end

        product_region_eu || continue

        if entry.product_sector == "D1"
            payer_id, payer_type = payer_account(entry.use_region, entry.use_code, activity_code_set)
            payer_type == "activity" || error("Unexpected D1 payer $(entry.use_code)")
            add_flow!(
                flows,
                factor_id(entry.use_region, "LAB"),
                payer_id,
                "factor",
                payer_type,
                "labor_income",
                "balanced_use_special_rows",
                "D1",
                entry.value,
            )
        elseif entry.product_sector == "B2A3G"
            payer_id, payer_type = payer_account(entry.use_region, entry.use_code, activity_code_set)
            payer_type == "activity" || error("Unexpected B2A3G payer $(entry.use_code)")
            add_flow!(
                flows,
                factor_id(entry.use_region, "CAP"),
                payer_id,
                "factor",
                payer_type,
                "capital_income",
                "balanced_use_special_rows",
                "B2A3G",
                entry.value,
            )
        elseif entry.product_sector == "D29X39" || entry.product_sector == "D21X31"
            payer_id, payer_type = payer_account(entry.use_region, entry.use_code, activity_code_set)
            add_flow!(
                flows,
                institution_id(entry.use_region, "GOV"),
                payer_id,
                "institution",
                payer_type,
                entry.product_sector == "D29X39" ? "production_taxes_less_subsidies" : "product_taxes_less_subsidies",
                "balanced_use_special_rows",
                entry.product_sector,
                entry.value,
            )
        elseif entry.product_sector == "OP_NRES"
            tourism_in[entry.use_region] += entry.value
            add_flow!(
                flows,
                institution_id(entry.use_region, "HH"),
                external_id(entry.use_region),
                "institution",
                "external",
                "tourism_inbound_adjustment",
                "balanced_use_special_rows",
                "OP_NRES",
                entry.value,
            )
        elseif entry.product_sector == "OP_RES"
            tourism_out[entry.use_region] += entry.value
            add_flow!(
                flows,
                external_id(entry.use_region),
                institution_id(entry.use_region, "HH"),
                "external",
                "institution",
                "tourism_outbound_adjustment",
                "balanced_use_special_rows",
                "OP_RES",
                entry.value,
            )
        end
    end

    activity_residuals = add_activity_residual_capital!(flows, regions, activity_codes)

    rowsums, colsums = row_col_sums(flows)

    for region in regions
        for factor_code in ("LAB", "CAP")
            id = factor_id(region, factor_code)
            gap = get(rowsums, id, 0.0) - get(colsums, id, 0.0)
            if gap > TOL
                add_flow!(
                    flows,
                    institution_id(region, "HH"),
                    id,
                    "institution",
                    "factor",
                    factor_code == "LAB" ? "labor_income_to_households" : "capital_income_to_households",
                    "closure",
                    factor_code,
                    gap,
                )
            elseif gap < -TOL
                add_flow!(
                    flows,
                    id,
                    institution_id(region, "HH"),
                    "factor",
                    "institution",
                    factor_code == "LAB" ? "household_support_to_labor" : "household_support_to_capital",
                    "closure",
                    factor_code,
                    -gap,
                )
            end
        end
    end

    rowsums, colsums = row_col_sums(flows)

    household_saving = Dict{String,Float64}()
    government_saving = Dict{String,Float64}()
    for region in regions
        hh_id = institution_id(region, "HH")
        gov_id = institution_id(region, "GOV")

        hh_gap = get(rowsums, hh_id, 0.0) - get(colsums, hh_id, 0.0)
        household_saving[region] = hh_gap
        if hh_gap > TOL
            add_flow!(
                flows,
                institution_id(region, "INV"),
                hh_id,
                "institution",
                "institution",
                "household_saving",
                "closure",
                "HH",
                hh_gap,
            )
        elseif hh_gap < -TOL
            add_flow!(
                flows,
                hh_id,
                institution_id(region, "INV"),
                "institution",
                "institution",
                "household_borrowing",
                "closure",
                "HH",
                -hh_gap,
            )
        end

        rowsums, colsums = row_col_sums(flows)
        gov_gap = get(rowsums, gov_id, 0.0) - get(colsums, gov_id, 0.0)
        government_saving[region] = gov_gap
        if gov_gap > TOL
            add_flow!(
                flows,
                institution_id(region, "INV"),
                gov_id,
                "institution",
                "institution",
                "government_saving",
                "closure",
                "GOV",
                gov_gap,
            )
        elseif gov_gap < -TOL
            add_flow!(
                flows,
                gov_id,
                institution_id(region, "INV"),
                "institution",
                "institution",
                "government_borrowing",
                "closure",
                "GOV",
                -gov_gap,
            )
        end
    end

    rowsums, colsums = row_col_sums(flows)

    external_balance = Dict{String,Float64}()
    for region in regions
        inv_id = institution_id(region, "INV")
        ext_id = external_id(region)
        ext_gap = get(rowsums, ext_id, 0.0) - get(colsums, ext_id, 0.0)
        external_balance[region] = ext_gap
        if ext_gap > TOL
            add_flow!(
                flows,
                inv_id,
                ext_id,
                "institution",
                "external",
                "foreign_saving",
                "closure",
                "EXT",
                ext_gap,
            )
        elseif ext_gap < -TOL
            add_flow!(
                flows,
                ext_id,
                inv_id,
                "external",
                "institution",
                "net_lending_abroad",
                "closure",
                "EXT",
                -ext_gap,
            )
        end
    end

    rowsums, colsums = row_col_sums(flows)

    inv_pool_id = institution_id("GLOBAL", "INV_POOL")
    for region in regions
        inv_id = institution_id(region, "INV")
        inv_gap = get(rowsums, inv_id, 0.0) - get(colsums, inv_id, 0.0)
        if inv_gap > TOL
            add_flow!(
                flows,
                inv_pool_id,
                inv_id,
                "institution",
                "institution",
                "interregional_net_lending",
                "closure",
                "INV_POOL",
                inv_gap,
            )
        elseif inv_gap < -TOL
            add_flow!(
                flows,
                inv_id,
                inv_pool_id,
                "institution",
                "institution",
                "interregional_financing",
                "closure",
                "INV_POOL",
                -inv_gap,
            )
        end
    end

    account_ids, matrix = build_matrix(accounts, flows)
    matrix_header, matrix_rows_out = matrix_rows(account_ids, matrix)
    balance_rows_out, max_abs_balance, total_abs_balance = balance_rows(accounts, matrix)

    macro_rows = Vector{Vector{String}}()
    for region in regions
        activity_resid_pos = sum(max(get(activity_residuals, (region, code), 0.0), 0.0) for code in activity_codes)
        activity_resid_neg = sum(max(-get(activity_residuals, (region, code), 0.0), 0.0) for code in activity_codes)
        push!(macro_rows, [
            region,
            string(household_consumption[region]),
            string(government_consumption[region]),
            string(investment_demand[region]),
            string(tourism_in[region]),
            string(tourism_out[region]),
            string(household_saving[region]),
            string(government_saving[region]),
            string(external_balance[region]),
            string(activity_resid_pos),
            string(activity_resid_neg),
        ])
    end

    validation_rows = [
        ["n_accounts", string(length(accounts))],
        ["n_flows", string(length(flows))],
        ["max_abs_balance", string(max_abs_balance)],
        ["total_abs_balance", string(total_abs_balance)],
        ["household_npish_rule", "P3_S15 merged into households"],
        ["activity_residual_rule", "residual assigned to regional capital"],
    ]

    write_tsv(OUT_ACCOUNTS, ["account_id", "account_type", "region", "code", "label"], accounts)
    write_tsv(OUT_FLOWS, ["row_account_id", "column_account_id", "row_type", "column_type", "flow_kind", "source_table", "source_code", "value"], sorted_flow_rows(flows))
    write_tsv(OUT_MATRIX, matrix_header, matrix_rows_out)
    write_tsv(OUT_BALANCES, ["account_id", "account_type", "region", "code", "row_sum", "column_sum", "balance"], balance_rows_out)
    write_tsv(
        OUT_SUMMARY,
        [
            "region",
            "household_consumption",
            "government_consumption",
            "investment_demand",
            "tourism_in",
            "tourism_out",
            "household_saving",
            "government_saving",
            "external_balance",
            "activity_residual_positive",
            "activity_residual_negative",
        ],
        macro_rows,
    )
    write_tsv(OUT_VALIDATION, ["key", "value"], validation_rows)

    println("Wrote stage-6 artifacts to ", OUTDIR)
end

main()
