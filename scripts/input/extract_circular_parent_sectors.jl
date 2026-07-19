#!/usr/bin/env julia

"""
Extract candidate FIGARO parent sectors that can anchor the monetary side of
the circular-route accounts.

This step does not build the final SAM accounts yet. It identifies the parent
service and waste sectors that are plausible monetary anchors for:
- repair,
- recycling and disposal,
- possible refurbishment/reuse splits.

It also summarizes:
- regional output levels of those parent sectors in the base SUT,
- use of their products by the disaggregated CE-RISE manufacturing families.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")
const STRUCTURE_DIR = joinpath(ROOT_DIR, "data", "interim", "structure")
const FIGARO_CODE_MAP = joinpath(ROOT_DIR, "data", "interim", "figaro_2016", "figaro_2016_code_map.tsv")
const SUPPLY_FILE = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const USE_FILE = joinpath(SUT_DIR, "sut_use_disaggregated_unbalanced.tsv")
const SPLIT_MAP_FILE = joinpath(SUT_DIR, "sut_split_sector_map.tsv")

const OUT_CANDIDATES = joinpath(STRUCTURE_DIR, "circular_parent_candidates.tsv")
const OUT_ACTIVITY = joinpath(STRUCTURE_DIR, "circular_parent_activity_output.tsv")
const OUT_FAMILY_USE = joinpath(STRUCTURE_DIR, "circular_parent_use_by_family.tsv")

const ACTIVITY_LABEL_OVERRIDES = Dict(
    "E37-E39" => "Sewerage, waste management, remediation activities",
)

const CANDIDATES = [
    (
        role_id = "REPAIR_MACHINERY",
        role_label = "Repair and installation services of machinery and equipment",
        product_code = "CPA_C33",
        activity_code = "C33",
        intended_accounts = "REP_ELMA;REP_OFMA;REP_RATV",
        confidence = "direct",
        notes = "Strong candidate monetary anchor for repair and installation linked to machinery, electrical equipment, and electronics.",
    ),
    (
        role_id = "REPAIR_HOUSEHOLD",
        role_label = "Repair services of computers and personal and household goods",
        product_code = "CPA_S95",
        activity_code = "S95",
        intended_accounts = "REP_ELMA;REP_OFMA;REP_RATV",
        confidence = "direct",
        notes = "Direct candidate monetary anchor for consumer-electronics, computer, and household-goods repair.",
    ),
    (
        role_id = "WASTE_RECOVERY",
        role_label = "Waste treatment, disposal, and materials recovery services",
        product_code = "CPA_E37-39",
        activity_code = "E37-E39",
        intended_accounts = "REC_EE;INC_EE",
        confidence = "direct_mixed",
        notes = "Contains both recycling/materials recovery and disposal activities, so it can anchor the recycling/disposal monetary parent sector before finer splits are introduced.",
    ),
    (
        role_id = "WHOLESALE_CHANNEL",
        role_label = "Wholesale trade services",
        product_code = "CPA_G46",
        activity_code = "G46",
        intended_accounts = "REF_*;REU_*",
        confidence = "tentative",
        notes = "Possible channel for refurbishment/reuse distribution margins, but not a direct route definition by itself.",
    ),
    (
        role_id = "RETAIL_CHANNEL",
        role_label = "Retail trade services",
        product_code = "CPA_G47",
        activity_code = "G47",
        intended_accounts = "REF_*;REU_*",
        confidence = "tentative",
        notes = "Possible channel for refurbishment/reuse sales to final users, subject to later semantic validation.",
    ),
    (
        role_id = "LEASING_CHANNEL",
        role_label = "Rental and leasing services",
        product_code = "CPA_N77",
        activity_code = "N77",
        intended_accounts = "REU_*;TST_*",
        confidence = "tentative",
        notes = "Possible monetary anchor for access-based service models and repeated-use channels, but still conceptually tentative.",
    ),
]

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

function load_code_labels()
    product_labels = Dict{String,String}()
    activity_labels = Dict{String,String}()
    for row in read_tsv(FIGARO_CODE_MAP)
        length(row) == 3 || continue
        scheme, code, label = row
        if scheme in ("prd_ava", "cpa2_1")
            get!(product_labels, code, label)
        elseif scheme in ("ind_use", "nace_r2")
            get!(activity_labels, code, label)
        end
    end
    for (code, label) in ACTIVITY_LABEL_OVERRIDES
        activity_labels[code] = label
    end
    return product_labels, activity_labels
end

function load_split_family_map()
    rows = read_tsv(SPLIT_MAP_FILE)
    family_map = Dict{String,Tuple{String,String}}()
    for row in rows[2:end]
        ce_rise_parent = row[2]
        ce_rise_parent_label = row[3]
        activity_code = row[8]
        family_map[activity_code] = (ce_rise_parent, ce_rise_parent_label)
    end
    return family_map
end

function aggregate_activity_output(candidate_by_activity)
    activity_total = Dict{Tuple{String,String},Float64}()
    own_product_total = Dict{Tuple{String,String,String},Float64}()
    product_total = Dict{Tuple{String,String},Float64}()

    rows = read_tsv(SUPPLY_FILE)
    for row in rows[2:end]
        product_region, product_code, activity_region, activity_code, value_str = row
        value = parse(Float64, value_str)

        if haskey(candidate_by_activity, activity_code)
            activity_total[(activity_region, activity_code)] = get(activity_total, (activity_region, activity_code), 0.0) + value
            candidate = candidate_by_activity[activity_code]
            if product_code == candidate.product_code && product_region == activity_region
                own_product_total[(activity_region, activity_code, product_code)] =
                    get(own_product_total, (activity_region, activity_code, product_code), 0.0) + value
            end
        end

        if any(c.product_code == product_code for c in CANDIDATES)
            product_total[(product_region, product_code)] = get(product_total, (product_region, product_code), 0.0) + value
        end
    end

    return activity_total, own_product_total, product_total
end

function aggregate_family_use(candidate_by_product, family_map)
    totals = Dict{Tuple{String,String,String,String},Float64}()
    domestic = Dict{Tuple{String,String,String,String},Float64}()
    imported = Dict{Tuple{String,String,String,String},Float64}()

    rows = read_tsv(USE_FILE)
    for row in rows[2:end]
        product_region, product_code, use_region, use_code, value_str = row
        haskey(candidate_by_product, product_code) || continue
        haskey(family_map, use_code) || continue

        ce_rise_parent, ce_rise_parent_label = family_map[use_code]
        key = (use_region, ce_rise_parent, ce_rise_parent_label, product_code)
        value = parse(Float64, value_str)
        totals[key] = get(totals, key, 0.0) + value
        if product_region == use_region
            domestic[key] = get(domestic, key, 0.0) + value
        else
            imported[key] = get(imported, key, 0.0) + value
        end
    end

    return totals, domestic, imported
end

function main()
    ensure_dir(STRUCTURE_DIR)

    product_labels, activity_labels = load_code_labels()
    family_map = load_split_family_map()

    candidate_by_activity = Dict(c.activity_code => c for c in CANDIDATES)
    candidate_by_product = Dict(c.product_code => c for c in CANDIDATES)

    candidate_rows = Vector{Vector{String}}()
    for c in CANDIDATES
        push!(candidate_rows, [
            c.role_id,
            c.role_label,
            c.product_code,
            get(product_labels, c.product_code, c.product_code),
            c.activity_code,
            get(activity_labels, c.activity_code, c.activity_code),
            c.intended_accounts,
            c.confidence,
            c.notes,
        ])
    end

    activity_total, own_product_total, product_total = aggregate_activity_output(candidate_by_activity)
    activity_rows = Vector{Vector{String}}()
    for c in CANDIDATES
        for region in sort(unique(vcat(
            [key[1] for key in keys(activity_total) if key[2] == c.activity_code],
            [key[1] for key in keys(product_total) if key[2] == c.product_code],
        )))
            push!(activity_rows, [
                region,
                c.role_id,
                c.product_code,
                get(product_labels, c.product_code, c.product_code),
                c.activity_code,
                get(activity_labels, c.activity_code, c.activity_code),
                string(get(activity_total, (region, c.activity_code), 0.0)),
                string(get(own_product_total, (region, c.activity_code, c.product_code), 0.0)),
                string(get(product_total, (region, c.product_code), 0.0)),
                c.confidence,
            ])
        end
    end

    totals, domestic, imported = aggregate_family_use(candidate_by_product, family_map)
    family_use_rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(totals)))
        use_region, ce_rise_parent, ce_rise_parent_label, product_code = key
        candidate = candidate_by_product[product_code]
        push!(family_use_rows, [
            use_region,
            ce_rise_parent,
            ce_rise_parent_label,
            product_code,
            get(product_labels, product_code, product_code),
            candidate.role_id,
            string(totals[key]),
            string(get(domestic, key, 0.0)),
            string(get(imported, key, 0.0)),
        ])
    end

    write_tsv(
        OUT_CANDIDATES,
        [
            "role_id",
            "role_label",
            "product_code",
            "product_label",
            "activity_code",
            "activity_label",
            "intended_accounts",
            "confidence",
            "notes",
        ],
        candidate_rows,
    )
    write_tsv(
        OUT_ACTIVITY,
        [
            "region",
            "role_id",
            "product_code",
            "product_label",
            "activity_code",
            "activity_label",
            "activity_total_output_meur",
            "own_product_output_meur",
            "product_total_supply_meur",
            "confidence",
        ],
        activity_rows,
    )
    write_tsv(
        OUT_FAMILY_USE,
        [
            "use_region",
            "ce_rise_parent",
            "ce_rise_parent_label",
            "product_code",
            "product_label",
            "role_id",
            "total_use_meur",
            "domestic_use_meur",
            "imported_use_meur",
        ],
        family_use_rows,
    )

    println("Wrote:")
    println("  ", OUT_CANDIDATES)
    println("  ", OUT_ACTIVITY)
    println("  ", OUT_FAMILY_USE)
end

main()
