#!/usr/bin/env julia

"""
Build the stage-8 EU single-region canonical calibration bundle.

This stage exports data and mappings only. It does not yet create the empirical
JCGE model specification. The bundle aggregates the selected European benchmark
regions into one region and represents omitted non-European interactions
through a synthetic external account.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const STAGE6_DIR = joinpath(ROOT_DIR, "data", "artifacts", "06_closed_sam")
const STAGE7_DIR = joinpath(ROOT_DIR, "data", "artifacts", "07_model_scaffold")
const MAPPING_DIR = joinpath(ROOT_DIR, "data", "mappings")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "08_eu_single_region_bundle")

const IN_ACCOUNTS = joinpath(STAGE6_DIR, "closed_sam_accounts.tsv")
const IN_FLOWS = joinpath(STAGE6_DIR, "closed_sam_flows.tsv")
const IN_FINAL_SECTORS = joinpath(MAPPING_DIR, "final_sector_registry.tsv")
const IN_FAMILY_REGISTRY = joinpath(STAGE7_DIR, "single_region_family_registry.tsv")
const IN_ROUTE_REGISTRY = joinpath(STAGE7_DIR, "single_region_route_registry.tsv")
const IN_PHYSICAL_BRIDGE = joinpath(STAGE7_DIR, "physical_quantity_bridge_template.tsv")
const IN_PHYSICAL_COEFFS = joinpath(STAGE7_DIR, "physical_coefficient_template.tsv")

const OUT_SAM = joinpath(OUTDIR, "sam.csv")
const OUT_SETS = joinpath(OUTDIR, "sets.csv")
const OUT_LABELS = joinpath(OUTDIR, "labels.csv")
const OUT_SUBSETS = joinpath(OUTDIR, "subsets.csv")
const OUT_MAPPINGS = joinpath(OUTDIR, "mappings.csv")
const OUT_ACCOUNTS = joinpath(OUTDIR, "bundle_account_registry.tsv")
const OUT_FLOWS = joinpath(OUTDIR, "bundle_flows.tsv")
const OUT_BALANCES = joinpath(OUTDIR, "bundle_account_balances.tsv")
const OUT_REGION_SCOPE = joinpath(OUTDIR, "eu_source_regions.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "bundle_validation.tsv")
const OUT_FAMILY_REGISTRY = joinpath(OUTDIR, "single_region_family_registry.tsv")
const OUT_ROUTE_REGISTRY = joinpath(OUTDIR, "single_region_route_registry.tsv")
const OUT_PHYSICAL_BRIDGE = joinpath(OUTDIR, "physical_quantity_bridge_template.tsv")
const OUT_PHYSICAL_COEFFS = joinpath(OUTDIR, "physical_coefficient_template.tsv")

const EU_REGIONS = ["DE", "FR", "IT", "PL", "SK"]
const BUNDLE_REGION = "EU"
const EXT_ACCOUNT = "EXT"
const TOL = 1.0e-8

struct AccountRow
    account_id::String
    account_type::String
    region::String
    code::String
    label::String
end

struct FlowRow
    row_account_id::String
    column_account_id::String
    row_type::String
    column_type::String
    flow_kind::String
    source_table::String
    source_code::String
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

function csv_escape(value)::String
    text = String(value)
    occursin('"', text) && (text = replace(text, "\"" => "\"\""))
    if occursin(',', text) || occursin('"', text) || occursin('\n', text)
        return "\"" * text * "\""
    end
    return text
end

function write_csv(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(csv_escape.(header), ','))
        for row in rows
            println(io, join(csv_escape.(row), ','))
        end
    end
end

function copy_text_file(src::AbstractString, dst::AbstractString)
    write(dst, read(src, String))
end

function unique_rows(rows::Vector{Vector{String}})
    seen = Set{Tuple{Vararg{String}}}()
    deduped = Vector{Vector{String}}()
    for row in rows
        key = Tuple(row)
        if !(key in seen)
            push!(seen, key)
            push!(deduped, row)
        end
    end
    return deduped
end

function load_account_rows(path::AbstractString)
    rows = read_tsv(path)
    return [AccountRow(row[1], row[2], row[3], row[4], row[5]) for row in rows[2:end]]
end

function load_flow_rows(path::AbstractString)
    rows = read_tsv(path)
    return [
        FlowRow(row[1], row[2], row[3], row[4], row[5], row[6], row[7], parse(Float64, row[8]))
        for row in rows[2:end]
    ]
end

function load_final_sector_rows(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))
    return [
        Dict(
            "sector_id" => row[idx["sector_id"]],
            "sector_label" => row[idx["sector_label"]],
            "role" => row[idx["role"]],
            "paper_observability" => row[idx["paper_observability"]],
        )
        for row in rows[2:end]
    ]
end

function load_stage7_rows(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))
    return [(Dict(name => row[i] for (name, i) in idx)) for row in rows[2:end]]
end

function map_source_account(row::AccountRow)
    if row.account_type == "external"
        return nothing
    elseif !(row.region in EU_REGIONS)
        return nothing
    elseif row.account_type == "activity"
        return "ACT_" * row.code
    elseif row.account_type == "commodity"
        return "COM_" * row.code
    elseif row.account_type == "factor"
        return row.code
    elseif row.account_type == "institution"
        return row.code
    end
    return nothing
end

function bundle_account_type(item::AbstractString)
    startswith(item, "ACT_") && return "activity"
    startswith(item, "COM_") && return "commodity"
    item in ("CAP", "LAB") && return "factor"
    item in ("HH", "GOV", "INV") && return "institution"
    item == EXT_ACCOUNT && return "external"
    error("Unknown bundle account item $(item)")
end

function rowcol_sums(flows::Dict{Tuple{String,String},Float64}, accounts::Vector{String})
    rowsums = Dict(a => 0.0 for a in accounts)
    colsums = Dict(a => 0.0 for a in accounts)
    for ((row, col), value) in flows
        rowsums[row] = get(rowsums, row, 0.0) + value
        colsums[col] = get(colsums, col, 0.0) + value
    end
    return rowsums, colsums
end

function aggregate_eu_submatrix(accounts::Vector{AccountRow}, flows::Vector{FlowRow})
    source_to_bundle = Dict(row.account_id => map_source_account(row) for row in accounts)
    bundle_flows = Dict{Tuple{String,String},Float64}()
    for flow in flows
        row_bundle = get(source_to_bundle, flow.row_account_id, nothing)
        col_bundle = get(source_to_bundle, flow.column_account_id, nothing)
        if row_bundle === nothing || col_bundle === nothing
            continue
        end
        key = (row_bundle, col_bundle)
        bundle_flows[key] = get(bundle_flows, key, 0.0) + flow.value
    end
    return bundle_flows
end

function add_synthetic_external!(bundle_flows::Dict{Tuple{String,String},Float64}, base_accounts::Vector{String})
    rowsums, colsums = rowcol_sums(bundle_flows, base_accounts)
    ext_rows = Vector{Vector{String}}()
    for account in base_accounts
        gap = rowsums[account] - colsums[account]
        if gap > TOL
            key = (EXT_ACCOUNT, account)
            bundle_flows[key] = get(bundle_flows, key, 0.0) + gap
            push!(ext_rows, [EXT_ACCOUNT, account, "synthetic_external_balance", "row_surplus", string(gap)])
        elseif gap < -TOL
            key = (account, EXT_ACCOUNT)
            bundle_flows[key] = get(bundle_flows, key, 0.0) - gap
            push!(ext_rows, [account, EXT_ACCOUNT, "synthetic_external_balance", "column_surplus", string(-gap)])
        end
    end
    return ext_rows
end

function bundle_account_order(final_sector_rows)
    sector_ids = [row["sector_id"] for row in final_sector_rows]
    activities = ["ACT_" * sector for sector in sector_ids]
    commodities = ["COM_" * sector for sector in sector_ids]
    factors = ["CAP", "LAB"]
    institutions = ["HH", "GOV", "INV"]
    externals = [EXT_ACCOUNT]
    return activities, commodities, factors, institutions, externals
end

function sector_label_lookup(final_sector_rows)
    return Dict(row["sector_id"] => row["sector_label"] for row in final_sector_rows)
end

function bundle_account_rows(activities, commodities, factors, institutions, externals, sector_labels)
    rows = Vector{Vector{String}}()
    for item in activities
        code = replace(item, "ACT_" => "")
        push!(rows, [item, "activity", BUNDLE_REGION, code, "EU activity: " * sector_labels[code]])
    end
    for item in commodities
        code = replace(item, "COM_" => "")
        push!(rows, [item, "commodity", BUNDLE_REGION, code, "EU commodity: " * sector_labels[code]])
    end
    for item in factors
        label = item == "CAP" ? "EU factor: Capital" : "EU factor: Labor"
        push!(rows, [item, "factor", BUNDLE_REGION, item, label])
    end
    for item in institutions
        label = item == "HH" ? "EU institution: Households (+ NPISH)" :
                item == "GOV" ? "EU institution: Government" :
                "EU institution: Investment"
        push!(rows, [item, "institution", BUNDLE_REGION, item, label])
    end
    for item in externals
        push!(rows, [item, "external", "GLOBAL", item, "External balance against omitted non-European accounts"])
    end
    return rows
end

function bundle_flow_rows(bundle_flows::Dict{Tuple{String,String},Float64}, ext_rows::Vector{Vector{String}})
    rows = Vector{Vector{String}}()
    ext_lookup = Dict((row[1], row[2]) => (row[3], row[4]) for row in ext_rows)
    for ((row, col), value) in sort!(collect(bundle_flows); by = x -> (x[1][1], x[1][2]))
        flow_kind, note = haskey(ext_lookup, (row, col)) ? ext_lookup[(row, col)] : ("aggregated_closed_sam_flow", "eu_submatrix")
        push!(rows, [
            row,
            col,
            bundle_account_type(row),
            bundle_account_type(col),
            flow_kind,
            note,
            string(value),
        ])
    end
    return rows
end

function sam_matrix_rows(account_order::Vector{String}, bundle_flows::Dict{Tuple{String,String},Float64})
    rows = Vector{Vector{String}}()
    for row_id in account_order
        row = String[row_id]
        for col_id in account_order
            push!(row, string(get(bundle_flows, (row_id, col_id), 0.0)))
        end
        push!(rows, row)
    end
    return rows
end

function account_balance_rows(account_order::Vector{String}, bundle_flows::Dict{Tuple{String,String},Float64})
    rowsums, colsums = rowcol_sums(bundle_flows, account_order)
    rows = Vector{Vector{String}}()
    for account in account_order
        row_sum = rowsums[account]
        col_sum = colsums[account]
        push!(rows, [
            account,
            bundle_account_type(account),
            string(row_sum),
            string(col_sum),
            string(row_sum - col_sum),
        ])
    end
    return rows
end

function sets_rows(activities, commodities, factors, institutions, externals, families, routes, service_targets, eol_targets, material_targets)
    rows = Vector{Vector{String}}()
    for item in activities
        push!(rows, ["activities", item])
    end
    for item in commodities
        push!(rows, ["commodities", item])
    end
    for item in factors
        push!(rows, ["factors", item])
    end
    for item in institutions
        push!(rows, ["institutions", item])
    end
    for item in externals
        push!(rows, ["externals", item])
    end
    for item in families
        push!(rows, ["families", item])
    end
    for item in routes
        push!(rows, ["routes", item])
    end
    for item in service_targets
        push!(rows, ["service_targets", item])
    end
    for item in eol_targets
        push!(rows, ["eol_targets", item])
    end
    for item in material_targets
        push!(rows, ["material_targets", item])
    end
    return rows
end

function labels_rows(activities, commodities, sector_labels, families, routes, service_targets, eol_targets, material_targets, family_registry)
    rows = Vector{Vector{String}}()
    for item in activities
        code = replace(item, "ACT_" => "")
        push!(rows, ["activities", item, "Activity: " * sector_labels[code], "EU activity account"])
    end
    for item in commodities
        code = replace(item, "COM_" => "")
        push!(rows, ["commodities", item, "Commodity: " * sector_labels[code], "EU commodity account"])
    end
    push!(rows, ["factors", "CAP", "Capital", "Primary factor"])
    push!(rows, ["factors", "LAB", "Labor", "Primary factor"])
    push!(rows, ["institutions", "HH", "Households (+ NPISH)", "Merged household institution"])
    push!(rows, ["institutions", "GOV", "Government", "Government institution"])
    push!(rows, ["institutions", "INV", "Investment", "Savings-investment account"])
    push!(rows, ["externals", "EXT", "External balance", "Synthetic external account after omission of non-European benchmark regions"])
    family_labels = Dict(row["family"] => row["family_label"] for row in family_registry)
    for family in families
        push!(rows, ["families", family, family_labels[family], "CE-RISE product family"])
    end
    route_labels = Dict(
        "NEW" => "New production",
        "REF" => "Refurbishment",
        "REP" => "Repair",
        "REU" => "Reuse",
        "REC" => "Recycling",
        "INC" => "Incineration or disposal",
    )
    for route in routes
        push!(rows, ["routes", route, route_labels[route], "Circular-economy route"])
    end
    for target in service_targets
        family = replace(target, "TST_" => "")
        push!(rows, ["service_targets", target, "Service composite for " * family_labels[family], "Target service composite used later in the empirical model"])
    end
    for target in eol_targets
        family = replace(target, "EOL_" => "")
        push!(rows, ["eol_targets", target, "End-of-life flow for " * family_labels[family], "Target end-of-life account used later in the empirical model"])
    end
    push!(rows, ["material_targets", "VMTL_EE", "Primary metal pool for CE-RISE routes", "Target primary-material account used later in the empirical model"])
    push!(rows, ["material_targets", "RMTL_EE", "Recycled metal pool for CE-RISE routes", "Target secondary-material account used later in the empirical model"])
    return rows
end

function subsets_rows(final_sector_rows, route_registry)
    rows = Vector{Vector{String}}()
    service_codes = Set(["NEW_" * fam for fam in ("ELMA", "OFMA", "RATV")] )
    union!(service_codes, Set(["REF_" * fam for fam in ("ELMA", "OFMA", "RATV")]))
    union!(service_codes, Set(["REP_" * fam for fam in ("ELMA", "OFMA", "RATV")]))
    union!(service_codes, Set(["REU_" * fam for fam in ("ELMA", "OFMA", "RATV")]))
    ce_rise_codes = Set(["NEW_" * fam for fam in ("ELMA", "OFMA", "RATV")])
    union!(ce_rise_codes, Set(["REP_" * fam for fam in ("ELMA", "OFMA", "RATV")]))
    union!(ce_rise_codes, Set(["REF_" * fam for fam in ("ELMA", "OFMA", "RATV")]))
    union!(ce_rise_codes, Set(["REU_" * fam for fam in ("ELMA", "OFMA", "RATV")]))
    union!(ce_rise_codes, Set(["REC_EE", "INC_EE"]))
    upstream_codes = Set(["BASIC_METALS", "METAL_COMPONENTS"])

    for row in final_sector_rows
        code = row["sector_id"]
        act = "ACT_" * code
        com = "COM_" * code
        if code in ce_rise_codes
            push!(rows, ["ce_rise_activities", "activities", act])
            push!(rows, ["ce_rise_commodities", "commodities", com])
        end
        if code in service_codes
            push!(rows, ["service_route_activities", "activities", act])
            push!(rows, ["service_route_commodities", "commodities", com])
        end
        if startswith(code, "NEW_")
            push!(rows, ["new_route_activities", "activities", act])
            push!(rows, ["new_route_commodities", "commodities", com])
        elseif startswith(code, "REP_")
            push!(rows, ["repair_route_activities", "activities", act])
            push!(rows, ["repair_route_commodities", "commodities", com])
        elseif startswith(code, "REF_")
            push!(rows, ["refurbishment_route_activities", "activities", act])
            push!(rows, ["refurbishment_route_commodities", "commodities", com])
        elseif startswith(code, "REU_")
            push!(rows, ["reuse_route_activities", "activities", act])
            push!(rows, ["reuse_route_commodities", "commodities", com])
        elseif code in ("REC_EE", "INC_EE")
            push!(rows, ["eol_processing_activities", "activities", act])
            push!(rows, ["eol_processing_commodities", "commodities", com])
        end
        if code in upstream_codes
            push!(rows, ["upstream_material_activities", "activities", act])
            push!(rows, ["upstream_material_commodities", "commodities", com])
        end
    end

    for route in ("NEW", "REF", "REP", "REU")
        push!(rows, ["service_routes", "routes", route])
    end
    for route in ("REF", "REP", "REU")
        push!(rows, ["life_extension_routes", "routes", route])
    end
    for route in ("REF", "REP", "REU", "REC", "INC")
        push!(rows, ["eol_routes", "routes", route])
    end
    return rows
end

function mappings_rows(final_sector_rows, family_registry, route_registry)
    rows = Vector{Vector{String}}()
    commodity_set = Set("COM_" * row["sector_id"] for row in final_sector_rows)
    for row in final_sector_rows
        code = row["sector_id"]
        push!(rows, ["activity_to_commodity", "ACT_" * code, "COM_" * code])
    end

    family_to_service = Dict(row["family"] => row["service_account"] for row in family_registry)
    family_to_eol = Dict(row["family"] => row["eol_account"] for row in family_registry)

    for row in route_registry
        route = row["route"]
        family = row["family"]
        act = "ACT_" * row["route_activity"]
        com = "COM_" * row["route_commodity"]

        push!(rows, ["activity_to_route", act, route])
        if com in commodity_set
            push!(rows, ["commodity_to_route", com, route])
        end

        if family != ""
            push!(rows, ["activity_to_family", act, family])
            if com in commodity_set
                push!(rows, ["commodity_to_family", com, family])
            end
        end

        if row["service_account"] != ""
            push!(rows, ["activity_to_service_target", act, row["service_account"]])
            if com in commodity_set
                push!(rows, ["commodity_to_service_target", com, row["service_account"]])
            end
        end

        if row["eol_account"] != ""
            push!(rows, ["activity_to_eol_target", act, row["eol_account"]])
            if com in commodity_set
                push!(rows, ["commodity_to_eol_target", com, row["eol_account"]])
            end
        end
    end

    for (family, target) in sort!(collect(family_to_service); by = first)
        push!(rows, ["family_to_service_target", family, target])
    end
    for (family, target) in sort!(collect(family_to_eol); by = first)
        push!(rows, ["family_to_eol_target", family, target])
    end

    for act in ("ACT_BASIC_METALS", "ACT_METAL_COMPONENTS")
        push!(rows, ["activity_to_material_target", act, "VMTL_EE"])
    end
    push!(rows, ["activity_to_material_target", "ACT_REC_EE", "RMTL_EE"])
    for com in ("COM_BASIC_METALS", "COM_METAL_COMPONENTS")
        push!(rows, ["commodity_to_material_target", com, "VMTL_EE"])
    end
    push!(rows, ["commodity_to_material_target", "COM_REC_EE", "RMTL_EE"])

    return unique_rows(rows)
end

function validation_rows(account_order, activities, commodities, factors, institutions, externals, bundle_flows, ext_rows)
    rowsums, colsums = rowcol_sums(bundle_flows, account_order)
    max_gap = maximum(abs(rowsums[a] - colsums[a]) for a in account_order)
    sam_square = true
    return [
        ["single_region_scope", "aggregate_europe_only"],
        ["synthetic_external_rule", "row_col_gap_after_eu_submatrix"],
        ["source_eu_regions", join(EU_REGIONS, ";")],
        ["excluded_regions", "ROW"],
        ["bundle_region_label", BUNDLE_REGION],
        ["bundle_activity_count", string(length(activities))],
        ["bundle_commodity_count", string(length(commodities))],
        ["bundle_factor_count", string(length(factors))],
        ["bundle_institution_count", string(length(institutions))],
        ["bundle_external_count", string(length(externals))],
        ["bundle_account_count", string(length(account_order))],
        ["synthetic_external_entries", string(length(ext_rows))],
        ["sam_square", string(sam_square)],
        ["max_abs_balance", string(max_gap)],
        ["balance_tolerance", string(TOL)],
    ]
end

function main()
    ensure_dir(OUTDIR)

    account_rows = load_account_rows(IN_ACCOUNTS)
    flow_rows = load_flow_rows(IN_FLOWS)
    final_sector_rows = load_final_sector_rows(IN_FINAL_SECTORS)
    family_registry = load_stage7_rows(IN_FAMILY_REGISTRY)
    route_registry = load_stage7_rows(IN_ROUTE_REGISTRY)

    activities, commodities, factors, institutions, externals = bundle_account_order(final_sector_rows)
    account_order = vcat(activities, commodities, factors, institutions, externals)
    sector_labels = sector_label_lookup(final_sector_rows)

    bundle_flows = aggregate_eu_submatrix(account_rows, flow_rows)
    ext_rows = add_synthetic_external!(bundle_flows, vcat(activities, commodities, factors, institutions))

    bundle_accounts = bundle_account_rows(activities, commodities, factors, institutions, externals, sector_labels)
    bundle_flow_table = bundle_flow_rows(bundle_flows, ext_rows)
    bundle_balance_table = account_balance_rows(account_order, bundle_flows)

    families = [row["family"] for row in family_registry]
    routes = ["NEW", "REF", "REP", "REU", "REC", "INC"]
    service_targets = [row["service_account"] for row in family_registry]
    eol_targets = [row["eol_account"] for row in family_registry]
    material_targets = ["VMTL_EE", "RMTL_EE"]

    write_csv(OUT_SAM, vcat(["label"], account_order), sam_matrix_rows(account_order, bundle_flows))
    write_csv(OUT_SETS, ["set", "item"], sets_rows(activities, commodities, factors, institutions, externals, families, routes, service_targets, eol_targets, material_targets))
    write_csv(OUT_LABELS, ["set", "item", "label", "description"], labels_rows(activities, commodities, sector_labels, families, routes, service_targets, eol_targets, material_targets, family_registry))
    write_csv(OUT_SUBSETS, ["subset", "parent_set", "item"], subsets_rows(final_sector_rows, route_registry))
    write_csv(OUT_MAPPINGS, ["map", "from_item", "to_item"], mappings_rows(final_sector_rows, family_registry, route_registry))

    write_tsv(OUT_ACCOUNTS, ["account_id", "account_type", "region", "code", "label"], bundle_accounts)
    write_tsv(OUT_FLOWS, ["row_account_id", "column_account_id", "row_type", "column_type", "flow_kind", "note", "value"], bundle_flow_table)
    write_tsv(OUT_BALANCES, ["account_id", "account_type", "row_sum", "column_sum", "gap"], bundle_balance_table)
    write_tsv(OUT_REGION_SCOPE, ["scope_key", "scope_value"], [["source_eu_regions", join(EU_REGIONS, ";")], ["excluded_region", "ROW"], ["bundle_region", BUNDLE_REGION]])
    write_tsv(OUT_VALIDATION, ["key", "value"], validation_rows(account_order, activities, commodities, factors, institutions, externals, bundle_flows, ext_rows))

    copy_text_file(IN_FAMILY_REGISTRY, OUT_FAMILY_REGISTRY)
    copy_text_file(IN_ROUTE_REGISTRY, OUT_ROUTE_REGISTRY)
    copy_text_file(IN_PHYSICAL_BRIDGE, OUT_PHYSICAL_BRIDGE)
    copy_text_file(IN_PHYSICAL_COEFFS, OUT_PHYSICAL_COEFFS)

    println("Wrote:")
    println("  ", OUT_SAM)
    println("  ", OUT_SETS)
    println("  ", OUT_LABELS)
    println("  ", OUT_SUBSETS)
    println("  ", OUT_MAPPINGS)
    println("  ", OUT_ACCOUNTS)
    println("  ", OUT_FLOWS)
    println("  ", OUT_BALANCES)
    println("  ", OUT_REGION_SCOPE)
    println("  ", OUT_VALIDATION)
    println("  ", OUT_FAMILY_REGISTRY)
    println("  ", OUT_ROUTE_REGISTRY)
    println("  ", OUT_PHYSICAL_BRIDGE)
    println("  ", OUT_PHYSICAL_COEFFS)
end

main()
