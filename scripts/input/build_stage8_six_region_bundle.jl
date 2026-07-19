#!/usr/bin/env julia

"""
Build the canonical six-region calibration bundle from the closed 2016 SAM.

The bundle retains the six European regions separately.  Each region has its
own 25 industries, labour and capital accounts, household, government and
investment institutions, and an external account for transactions with the
rest of the world.  The global investment-pool account closes transfers among
the six regional investment accounts.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const STAGE6_DIR = joinpath(ROOT_DIR, "data", "artifacts", "06_closed_sam")
const STAGE7_DIR = joinpath(ROOT_DIR, "data", "artifacts", "07_model_scaffold")
const STAGE4B_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04b_symmetric_io")
const MAPPING_DIR = joinpath(ROOT_DIR, "data", "mappings")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "08_six_region_bundle")

const IN_ACCOUNTS = joinpath(STAGE6_DIR, "closed_sam_accounts.tsv")
const IN_FLOWS = joinpath(STAGE6_DIR, "closed_sam_flows.tsv")
const IN_FINAL_SECTORS = joinpath(MAPPING_DIR, "final_sector_registry.tsv")
const IN_FAMILY_REGISTRY = joinpath(STAGE7_DIR, "family_registry.tsv")
const IN_ROUTE_REGISTRY = joinpath(STAGE7_DIR, "route_registry.tsv")
const IN_PHYSICAL_BRIDGE = joinpath(STAGE7_DIR, "physical_quantity_bridge_template.tsv")
const IN_PHYSICAL_COEFFS = joinpath(STAGE7_DIR, "physical_coefficient_template.tsv")
const IN_MODEL_CONFIGURATION = joinpath(MAPPING_DIR, "model_configuration.tsv")
const IN_IO_INTERMEDIATE = joinpath(STAGE4B_DIR, "industry_by_industry_intermediate.tsv")
const IN_IO_FINAL = joinpath(STAGE4B_DIR, "industry_by_final_demand.tsv")

const OUT_SAM = joinpath(OUTDIR, "sam.csv")
const OUT_SETS = joinpath(OUTDIR, "sets.csv")
const OUT_LABELS = joinpath(OUTDIR, "labels.csv")
const OUT_SUBSETS = joinpath(OUTDIR, "subsets.csv")
const OUT_MAPPINGS = joinpath(OUTDIR, "mappings.csv")
const OUT_ACCOUNTS = joinpath(OUTDIR, "bundle_account_registry.tsv")
const OUT_FLOWS = joinpath(OUTDIR, "bundle_flows.tsv")
const OUT_BALANCES = joinpath(OUTDIR, "bundle_account_balances.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "bundle_validation.tsv")
const OUT_FAMILY_REGISTRY = joinpath(OUTDIR, "regional_family_registry.tsv")
const OUT_ROUTE_REGISTRY = joinpath(OUTDIR, "regional_route_registry.tsv")
const OUT_PHYSICAL_BRIDGE = joinpath(OUTDIR, "regional_physical_quantity_bridge_template.tsv")
const OUT_PHYSICAL_COEFFS = joinpath(OUTDIR, "regional_physical_coefficient_template.tsv")
const OUT_MODEL_CONFIGURATION = joinpath(OUTDIR, "model_configuration.tsv")
const OUT_PRODUCT_USE_REGISTRY = joinpath(OUTDIR, "regional_product_use_registry.tsv")
const OUT_TRADE_REGISTRY = joinpath(OUTDIR, "regional_trade_registry.tsv")

const REGIONS = ["DE", "FR", "IT", "PL", "SK", "REU"]
const ROUTES = ["NEW", "REF", "REP", "REU", "REC", "INC"]
const TOL = 1.0e-6

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
    return occursin(',', text) || occursin('"', text) || occursin('\n', text) ? "\"" * text * "\"" : text
end

function write_csv(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(csv_escape.(header), ','))
        for row in rows
            println(io, join(csv_escape.(row), ','))
        end
    end
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

function table_rows(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    return header, [Dict(name => row[i] for (i, name) in enumerate(header)) for row in rows[2:end]]
end

function canonical_account_id(account::AccountRow)
    account.region in REGIONS ||
        (account.account_type == "investment_pool" && account.region == "GLOBAL") ||
        error("Unexpected account in closed SAM: $(account.account_id)")

    if account.account_type == "industry"
        return "IND_$(account.region)_$(account.code)"
    elseif account.account_type == "factor"
        return "FAC_$(account.region)_$(account.code)"
    elseif account.account_type == "institution"
        return "INS_$(account.region)_$(account.code)"
    elseif account.account_type == "external"
        return "EXT_$(account.region)_$(account.code)"
    elseif account.account_type == "investment_pool"
        return "INV_POOL"
    end
    error("Unsupported account type $(account.account_type)")
end

function canonical_type(account::AccountRow)
    account.account_type == "investment_pool" && return "investment_pool"
    return account.account_type
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

function bundle_flows(account_rows, flow_rows)
    ids = Dict(row.account_id => canonical_account_id(row) for row in account_rows)
    out = Dict{Tuple{String,String},Float64}()
    for flow in flow_rows
        key = (ids[flow.row_account_id], ids[flow.column_account_id])
        out[key] = get(out, key, 0.0) + flow.value
    end
    return out
end

function account_order(account_rows)
    return [canonical_account_id(row) for row in account_rows]
end

function account_rows(account_rows)
    return [[
        canonical_account_id(row),
        canonical_type(row),
        row.region,
        row.code,
        row.label,
    ] for row in account_rows]
end

function sam_matrix_rows(account_order::Vector{String}, flows)
    rows = Vector{Vector{String}}()
    for row_id in account_order
        row = [String(row_id)]
        for col_id in account_order
            push!(row, string(get(flows, (row_id, col_id), 0.0)))
        end
        push!(rows, row)
    end
    return rows
end

function balance_rows(account_order, account_lookup, flows)
    rowsums, colsums = rowcol_sums(flows, account_order)
    return [[
        account,
        canonical_type(account_lookup[account]),
        string(rowsums[account]),
        string(colsums[account]),
        string(rowsums[account] - colsums[account]),
    ] for account in account_order]
end

function bundle_flow_rows(source_flows, source_accounts)
    rows = Vector{Vector{String}}()
    for flow in source_flows
        row_account = source_accounts[flow.row_account_id]
        col_account = source_accounts[flow.column_account_id]
        push!(rows, [
            canonical_account_id(row_account),
            canonical_account_id(col_account),
            canonical_type(row_account),
            canonical_type(col_account),
            flow.flow_kind,
            flow.source_table,
            flow.source_code,
            string(flow.value),
        ])
    end
    return rows
end

function sector_rows(path)
    _, rows = table_rows(path)
    return rows
end

function base_sets(account_rows, families)
    industries = [canonical_account_id(row) for row in account_rows if row.account_type == "industry"]
    factors = [canonical_account_id(row) for row in account_rows if row.account_type == "factor"]
    institutions = [canonical_account_id(row) for row in account_rows if row.account_type == "institution"]
    investment_pools = [canonical_account_id(row) for row in account_rows if row.account_type == "investment_pool"]
    externals = [canonical_account_id(row) for row in account_rows if row.account_type == "external"]
    regional_families = ["$(region)__$(family)" for region in REGIONS for family in families]
    service_targets = ["TST_$(region)_$(family)" for region in REGIONS for family in families]
    eol_targets = ["EOL_$(region)_$(family)" for region in REGIONS for family in families]
    material_targets = ["METAL"]
    return (; industries, factors, institutions, investment_pools, externals,
        regional_families, service_targets, eol_targets, material_targets)
end

function set_rows(sets, families)
    rows = Vector{Vector{String}}()
    for region in REGIONS
        push!(rows, ["regions", region])
    end
    for (name, items) in pairs(sets)
        set_name = String(name)
        for item in items
            push!(rows, [set_name, item])
        end
    end
    for family in families
        push!(rows, ["families", family])
    end
    for route in ROUTES
        push!(rows, ["routes", route])
    end
    return rows
end

function labels_rows(account_rows, families, family_rows, sets)
    rows = Vector{Vector{String}}()
    family_labels = Dict(row["family"] => row["family_label"] for row in family_rows)
    for row in account_rows
        item = canonical_account_id(row)
        set_name = row.account_type == "industry" ? "industries" :
                   row.account_type == "factor" ? "factors" :
                   row.account_type == "institution" ? "institutions" :
                   row.account_type == "external" ? "externals" : "investment_pools"
        push!(rows, [set_name, item, row.label, "Calibration-SAM account"])
    end
    for region in REGIONS
        push!(rows, ["regions", region, region, "European model region"])
    end
    for family in families
        push!(rows, ["families", family, family_labels[family], "CE-RISE product family"])
    end
    for (route, label) in zip(ROUTES, ["New production", "Refurbishment", "Repair", "Reuse", "Recycling", "Incineration or disposal"])
        push!(rows, ["routes", route, label, "Circular-economy route"])
    end
    for regional_family in sets.regional_families
        region, family = split(regional_family, "__"; limit = 2)
        push!(rows, ["regional_families", regional_family, "$(region): $(family_labels[family])", "Region-product-family pair"])
    end
    for target in sets.service_targets
        region, family = split(replace(target, "TST_" => ""), "_"; limit = 2)
        push!(rows, ["service_targets", target, "$(region) service composite: $(family_labels[family])", "Family-specific service composite"])
    end
    for target in sets.eol_targets
        region, family = split(replace(target, "EOL_" => ""), "_"; limit = 2)
        push!(rows, ["eol_targets", target, "$(region) end-of-life flow: $(family_labels[family])", "Family-specific end-of-life flow"])
    end
    push!(rows, ["material_targets", "METAL", "Metal", "Single metal commodity supplied by primary production, recycling, and trade"])
    return rows
end

function add_subset!(rows, subset, parent_set, item)
    push!(rows, [subset, parent_set, item])
end

function subset_rows(account_rows, families)
    rows = Vector{Vector{String}}()
    for account in account_rows
        item = canonical_account_id(account)
        if account.region in REGIONS
            parent_set = account.account_type == "industry" ? "industries" :
                         account.account_type == "factor" ? "factors" :
                         account.account_type == "institution" ? "institutions" : "externals"
            add_subset!(rows, "$(lowercase(account.region))_$(parent_set)", parent_set, item)
        end
        if account.account_type == "industry"
            code = account.code
            if startswith(code, "NEW_") || startswith(code, "REF_") || startswith(code, "REP_") || startswith(code, "REU_")
                add_subset!(rows, "service_route_industries", "industries", item)
            end
            if startswith(code, "NEW_")
                add_subset!(rows, "new_route_industries", "industries", item)
            elseif startswith(code, "REF_")
                add_subset!(rows, "refurbishment_route_industries", "industries", item)
            elseif startswith(code, "REP_")
                add_subset!(rows, "repair_route_industries", "industries", item)
            elseif startswith(code, "REU_")
                add_subset!(rows, "reuse_route_industries", "industries", item)
            elseif code in ("REC_EE", "INC_EE")
                add_subset!(rows, "eol_processing_industries", "industries", item)
            elseif code in ("BASIC_METALS", "METAL_COMPONENTS")
                add_subset!(rows, "upstream_material_industries", "industries", item)
            end
        end
    end
    for route in ("NEW", "REF", "REP", "REU")
        add_subset!(rows, "service_routes", "routes", route)
    end
    for route in ("REF", "REP", "REU")
        add_subset!(rows, "life_extension_routes", "routes", route)
    end
    for route in ("REF", "REP", "REU", "REC", "INC")
        add_subset!(rows, "eol_routes", "routes", route)
    end
    return rows
end

function mapping_rows(account_rows, route_rows, families)
    rows = Vector{Vector{String}}()
    for account in account_rows
        item = canonical_account_id(account)
        if account.region in REGIONS
            if account.account_type == "industry"
                push!(rows, ["industry_to_region", item, account.region])
            elseif account.account_type == "factor"
                push!(rows, ["factor_to_region", item, account.region])
            elseif account.account_type == "institution"
                push!(rows, ["institution_to_region", item, account.region])
            elseif account.account_type == "external"
                push!(rows, ["external_to_region", item, account.region])
            end
        end
    end
    for region in REGIONS, row in route_rows
        family = row["family"]
        route = row["route"]
        industry = "IND_$(region)_$(row["route_activity"])"
        regional_family = "$(region)__$(family)"
        push!(rows, ["industry_to_region", industry, region])
        push!(rows, ["industry_to_route", industry, route])
        push!(rows, ["industry_to_family", industry, family])
        push!(rows, ["industry_to_regional_family", industry, regional_family])
        if row["service_account"] != ""
            push!(rows, ["industry_to_service_target", industry, "TST_$(region)_$(family)"])
        end
        if row["eol_account"] != ""
            push!(rows, ["industry_to_eol_target", industry, "EOL_$(region)_$(family)"])
        end
        if row["route_activity"] == "BASIC_METALS"
            push!(rows, ["industry_to_material_target", industry, "METAL"])
        elseif row["route_activity"] == "REC_EE"
            push!(rows, ["industry_to_material_target", industry, "METAL"])
        end
    end
    for region in REGIONS, family in families
        regional_family = "$(region)__$(family)"
        push!(rows, ["regional_family_to_service_target", regional_family, "TST_$(region)_$(family)"])
        push!(rows, ["regional_family_to_eol_target", regional_family, "EOL_$(region)_$(family)"])
    end
    for region in REGIONS
        push!(rows, ["industry_to_material_target", "IND_$(region)_BASIC_METALS", "METAL"])
        push!(rows, ["industry_to_material_target", "IND_$(region)_REC_EE", "METAL"])
    end
    return unique(rows)
end

function regional_family_rows(source_header, family_rows)
    header = ["region"; source_header]
    rows = Vector{Vector{String}}()
    for region in REGIONS, row in family_rows
        family = row["family"]
        values = [row[key] for key in header[2:end]]
        replacements = Dict(
            "service_account" => "TST_$(region)_$(family)",
            "eol_account" => "EOL_$(region)_$(family)",
            "new_route" => "IND_$(region)_$(row["new_route"])",
            "repair_route" => "IND_$(region)_$(row["repair_route"])",
            "refurbishment_route" => "IND_$(region)_$(row["refurbishment_route"])",
            "reuse_route" => "IND_$(region)_$(row["reuse_route"])",
            "recycling_activity" => "IND_$(region)_$(row["recycling_activity"])",
            "disposal_activity" => "IND_$(region)_$(row["disposal_activity"])",
            "metal_commodity" => "METAL",
            "primary_metal_activity" => "IND_$(region)_BASIC_METALS",
        )
        for (i, key) in enumerate(header[2:end])
            haskey(replacements, key) && (values[i] = replacements[key])
        end
        push!(rows, vcat([region], values))
    end
    return header, rows
end

function regional_route_rows(source_header, route_rows)
    header = ["region"; source_header]
    rows = Vector{Vector{String}}()
    for region in REGIONS, row in route_rows
        family = row["family"]
        values = [row[key] for key in header[2:end]]
        for (i, key) in enumerate(header[2:end])
            if key == "service_account" && values[i] != ""
                values[i] = "TST_$(region)_$(family)"
            elseif key == "eol_account" && values[i] != ""
                values[i] = "EOL_$(region)_$(family)"
            elseif key == "route_activity" && values[i] != ""
                values[i] = "IND_$(region)_$(values[i])"
            elseif key == "route_commodity" && values[i] != "" && values[i] != "METAL"
                values[i] = "IND_$(region)_$(values[i])"
            elseif key == "source_sector_id" && values[i] != ""
                values[i] = "IND_$(region)_$(values[i])"
            end
        end
        push!(rows, vcat([region], values))
    end
    return header, rows
end

function regional_template_target(region, value)
    value == "" && return value
    if startswith(value, "P_")
        return "P_" * regional_template_target(region, value[3:end])
    elseif startswith(value, "TST_") || startswith(value, "EOL_")
        return replace(value, "_" => "_$(region)_"; count = 1)
    elseif startswith(value, "NEW_") || startswith(value, "REF_") ||
           startswith(value, "REP_") || startswith(value, "REU_") ||
           value in ("REC_EE", "INC_EE")
        return "IND_$(region)_$(value)"
    end
    return value
end

function regional_template_rows(header, template_rows)
    out_header = ["region"; header]
    rows = Vector{Vector{String}}()
    for region in REGIONS, row in template_rows
        values = [row[key] for key in header]
        for id_column in ("coefficient_id", "bridge_id")
            idx = findfirst(==(id_column), header)
            if idx !== nothing
                values[idx] = "$(region)_$(values[idx])"
            end
        end
        for account_column in ("linked_account", "benchmark_value_anchor", "benchmark_price_anchor")
            idx = findfirst(==(account_column), header)
            idx === nothing || (values[idx] = regional_template_target(region, values[idx]))
        end
        push!(rows, vcat([region], values))
    end
    return out_header, rows
end

function configuration_value(configuration_rows, component::String, key::String)
    matches = [row for row in configuration_rows if row["component"] == component && row["key"] == key]
    length(matches) == 1 || error("Expected one model-configuration row for $(component).$(key).")
    return matches[1]["value"]
end

function final_demand_roles(configuration_rows)
    household_codes = Set(split(configuration_value(configuration_rows, "final_demand", "household_codes"), ';'))
    roles = Dict{String,String}(code => "household" for code in household_codes)
    roles[configuration_value(configuration_rows, "final_demand", "government_code")] = "government"
    roles[configuration_value(configuration_rows, "final_demand", "fixed_investment_code")] = "fixed_investment"
    roles[configuration_value(configuration_rows, "final_demand", "inventory_change_code")] = "inventory_change"
    return roles
end

function valid_trade_endpoint(region::String)
    return region in REGIONS || region == "ROW"
end

function regional_product_use_rows(intermediate_rows, final_rows, roles)
    rows = Vector{Vector{String}}()
    for row in intermediate_rows
        origin = row["row_region"]
        destination = row["column_region"]
        valid_trade_endpoint(origin) && valid_trade_endpoint(destination) || continue
        origin == "ROW" && destination == "ROW" && continue
        value = parse(Float64, row["value_meur"])
        abs(value) <= 1.0e-12 && continue
        target = destination in REGIONS ? "IND_$(destination)_$(row["column_sector"])" : "ROW_$(row["column_sector"])"
        push!(rows, [
            row["row_sector"],
            origin,
            destination,
            "intermediate",
            target,
            string(value),
        ])
    end
    for row in final_rows
        origin = row["row_region"]
        destination = row["final_demand_region"]
        valid_trade_endpoint(origin) && valid_trade_endpoint(destination) || continue
        origin == "ROW" && destination == "ROW" && continue
        code = row["final_demand_code"]
        haskey(roles, code) || error("No final-demand role is configured for $(code).")
        value = parse(Float64, row["value_meur"])
        abs(value) <= 1.0e-12 && continue
        role = roles[code]
        target = destination == "ROW" ? "ROW_$(code)" :
                 role == "household" ? "INS_$(destination)_HH" :
                 role == "government" ? "INS_$(destination)_GOV" :
                 role == "fixed_investment" ? "INS_$(destination)_INV" :
                 "INV_CHANGE_$(destination)_$(row["row_sector"])"
        push!(rows, [row["row_sector"], origin, destination, role, target, string(value)])
    end
    sort!(rows, by = row -> join(row, '\t'))
    return rows
end

function regional_trade_rows(intermediate_rows, final_rows, roles)
    values = Dict{Tuple{String,String,String,String},Float64}()
    function add!(product, origin, destination, use_kind, value)
        valid_trade_endpoint(origin) && valid_trade_endpoint(destination) || return
        origin == "ROW" && destination == "ROW" && return
        key = (String(product), String(origin), String(destination), String(use_kind))
        values[key] = get(values, key, 0.0) + value
    end

    for row in intermediate_rows
        add!(row["row_sector"], row["row_region"], row["column_region"], "intermediate", parse(Float64, row["value_meur"]))
    end
    for row in final_rows
        code = row["final_demand_code"]
        haskey(roles, code) || error("No final-demand role is configured for $(code).")
        add!(row["row_sector"], row["row_region"], row["final_demand_region"], roles[code], parse(Float64, row["value_meur"]))
    end

    route_keys = sort!(collect(Set((key[1], key[2], key[3]) for key in keys(values))))
    rows = Vector{Vector{String}}()
    for (product, origin, destination) in route_keys
        component(kind) = get(values, (product, origin, destination, kind), 0.0)
        intermediate = component("intermediate")
        household = component("household")
        government = component("government")
        fixed_investment = component("fixed_investment")
        inventory_change = component("inventory_change")
        marketed = intermediate + household + government + fixed_investment
        marketed > TOL || continue
        push!(rows, [
            product,
            origin,
            destination,
            string(intermediate),
            string(household),
            string(government),
            string(fixed_investment),
            string(inventory_change),
            string(marketed),
        ])
    end
    return rows
end

function validation_rows(account_rows, account_order, flows, families)
    rowsums, colsums = rowcol_sums(flows, account_order)
    max_gap = maximum(abs(rowsums[a] - colsums[a]) for a in account_order)
    counts = Dict(type => count(row -> row.account_type == type, account_rows) for type in unique(row.account_type for row in account_rows))
    return [
        ["model_scope", "six_european_regions_with_regional_external_accounts"],
        ["regions", join(REGIONS, ";")],
        ["regional_industry_count", "25"],
        ["bundle_industry_count", string(get(counts, "industry", 0))],
        ["bundle_factor_count", string(get(counts, "factor", 0))],
        ["bundle_institution_count", string(get(counts, "institution", 0))],
        ["bundle_external_count", string(get(counts, "external", 0))],
        ["bundle_investment_pool_count", string(get(counts, "investment_pool", 0))],
        ["bundle_account_count", string(length(account_order))],
        ["family_count", string(length(families))],
        ["sam_square", "true"],
        ["max_abs_balance", string(max_gap)],
        ["balance_tolerance", string(TOL)],
    ]
end

function main()
    ensure_dir(OUTDIR)

    accounts = load_account_rows(IN_ACCOUNTS)
    flows = load_flow_rows(IN_FLOWS)
    family_source_header, family_rows = table_rows(IN_FAMILY_REGISTRY)
    route_source_header, route_rows = table_rows(IN_ROUTE_REGISTRY)
    coefficient_header, coefficient_rows = table_rows(IN_PHYSICAL_COEFFS)
    quantity_header, quantity_rows = table_rows(IN_PHYSICAL_BRIDGE)
    configuration_header, configuration_rows = table_rows(IN_MODEL_CONFIGURATION)
    _, io_intermediate_rows = table_rows(IN_IO_INTERMEDIATE)
    _, io_final_rows = table_rows(IN_IO_FINAL)
    families = [row["family"] for row in family_rows]

    order = account_order(accounts)
    lookup = Dict(canonical_account_id(row) => row for row in accounts)
    values = bundle_flows(accounts, flows)
    sets = base_sets(accounts, families)

    family_header, family_table = regional_family_rows(family_source_header, family_rows)
    route_header, route_table = regional_route_rows(route_source_header, route_rows)
    quantity_out_header, quantity_table = regional_template_rows(quantity_header, quantity_rows)
    coefficient_out_header, coefficient_table = regional_template_rows(coefficient_header, coefficient_rows)
    roles = final_demand_roles(configuration_rows)
    product_use_table = regional_product_use_rows(io_intermediate_rows, io_final_rows, roles)
    trade_table = regional_trade_rows(io_intermediate_rows, io_final_rows, roles)

    write_csv(OUT_SAM, vcat(["label"], order), sam_matrix_rows(order, values))
    write_csv(OUT_SETS, ["set", "item"], set_rows(sets, families))
    write_csv(OUT_LABELS, ["set", "item", "label", "description"], labels_rows(accounts, families, family_rows, sets))
    write_csv(OUT_SUBSETS, ["subset", "parent_set", "item"], subset_rows(accounts, families))
    write_csv(OUT_MAPPINGS, ["map", "from_item", "to_item"], mapping_rows(accounts, route_rows, families))
    write_tsv(OUT_ACCOUNTS, ["account_id", "account_type", "region", "code", "label"], account_rows(accounts))
    write_tsv(OUT_FLOWS, ["row_account_id", "column_account_id", "row_type", "column_type", "flow_kind", "source_table", "source_code", "value"], bundle_flow_rows(flows, Dict(row.account_id => row for row in accounts)))
    write_tsv(OUT_BALANCES, ["account_id", "account_type", "row_sum", "column_sum", "gap"], balance_rows(order, lookup, values))
    write_tsv(OUT_VALIDATION, ["key", "value"], validation_rows(accounts, order, values, families))
    write_tsv(OUT_FAMILY_REGISTRY, family_header, family_table)
    write_tsv(OUT_ROUTE_REGISTRY, route_header, route_table)
    write_tsv(OUT_PHYSICAL_BRIDGE, quantity_out_header, quantity_table)
    write_tsv(OUT_PHYSICAL_COEFFS, coefficient_out_header, coefficient_table)
    write_tsv(OUT_MODEL_CONFIGURATION, configuration_header, [[row[key] for key in configuration_header] for row in configuration_rows])
    write_tsv(OUT_PRODUCT_USE_REGISTRY, ["product", "origin", "destination", "use_kind", "use_target", "value_meur"], product_use_table)
    write_tsv(OUT_TRADE_REGISTRY, ["product", "origin", "destination", "intermediate_value_meur", "household_value_meur", "government_value_meur", "fixed_investment_value_meur", "inventory_change_value_meur", "marketed_value_meur"], trade_table)

    println("Wrote six-region calibration bundle to ", OUTDIR)
end

main()
