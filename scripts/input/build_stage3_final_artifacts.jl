#!/usr/bin/env julia

"""
Build the stage-3 final-preparation artifact set.

Stage 3 aggregates the replacement-integrated SUT to the current final sector
specification, including explicit constructed REF/REU sectors so the target
SUT already matches the intended model routes.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const ARTIFACT2_DIR = joinpath(ROOT_DIR, "data", "artifacts", "02_integrated_sut")
const STRUCTURE_DIR = joinpath(ROOT_DIR, "data", "interim", "structure")
const MAP_DIR = joinpath(ROOT_DIR, "data", "mappings")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "03_final_preparation")

const IN_SUPPLY = joinpath(ARTIFACT2_DIR, "integrated_supply.tsv")
const IN_USE = joinpath(ARTIFACT2_DIR, "integrated_use.tsv")
const ROUTE_TOTALS = joinpath(STRUCTURE_DIR, "circular_route_category_totals.tsv")
const FINAL_REGISTRY = joinpath(MAP_DIR, "final_sector_registry.tsv")

const OUT_SUPPLY = joinpath(OUTDIR, "final_supply_explicit.tsv")
const OUT_USE = joinpath(OUTDIR, "final_use_explicit.tsv")
const OUT_PRODUCT_MAP = joinpath(OUTDIR, "final_product_mapping.tsv")
const OUT_USE_MAP = joinpath(OUTDIR, "final_use_mapping.tsv")
const OUT_EXPLICIT_REGISTRY = joinpath(OUTDIR, "explicit_final_sector_registry.tsv")
const OUT_ROUTE_REGISTRY = joinpath(OUTDIR, "benchmark_construction_route_registry.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "final_validation.tsv")

const FINAL_DEMAND_CODES = Set(["P3_S13", "P3_S14", "P3_S15", "P51G", "P5M"])
const SPECIAL_USE_PRODUCT_ROWS = Set(["B2A3G", "D1", "D21X31", "D29X39", "OP_NRES", "OP_RES"])
const TOL = 1.0e-6

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

function add_value!(totals::Dict{NTuple{4,String},Float64}, key::NTuple{4,String}, value::Float64)
    abs(value) <= 1.0e-12 && return
    totals[key] = get(totals, key, 0.0) + value
end

function family_from_code(code::AbstractString)
    endswith(code, "_ELMA") && return "ELMA"
    endswith(code, "_OFMA") && return "OFMA"
    endswith(code, "_RATV") && return "RATV"
    return nothing
end

function load_waste_route_shares()
    rows = read_tsv(ROUTE_TOTALS)
    totals = Dict{Tuple{String,String,String},Float64}()
    family_global = Dict{Tuple{String,String},Float64}()

    for row in rows[2:end]
        region, family, route_category, _, value_str = row
        value = parse(Float64, value_str)
        totals[(region, family, route_category)] = value
        family_global[(family, route_category)] = get(family_global, (family, route_category), 0.0) + value
    end

    shares = Dict{Tuple{String,String},Tuple{Float64,Float64}}()
    for (region, family, _) in keys(totals)
        if haskey(shares, (region, family))
            continue
        end
        recycling = get(totals, (region, family, "recycling"), 0.0)
        disposal = get(totals, (region, family, "incineration"), 0.0) + get(totals, (region, family, "landfill"), 0.0)
        denominator = recycling + disposal
        if denominator > 0.0
            shares[(region, family)] = (recycling / denominator, disposal / denominator)
        end
    end

    fallback = Dict{String,Tuple{Float64,Float64}}()
    for family in ("ELMA", "OFMA", "RATV")
        recycling = get(family_global, (family, "recycling"), 0.0)
        disposal = get(family_global, (family, "incineration"), 0.0) + get(family_global, (family, "landfill"), 0.0)
        denominator = recycling + disposal
        fallback[family] = denominator > 0.0 ? (recycling / denominator, disposal / denominator) : (0.5, 0.5)
    end

    return shares, fallback
end

function waste_split(region::AbstractString, family::AbstractString, shares, fallback)
    return get(shares, (region, family), fallback[family])
end

function write_validation(path::AbstractString, supply_input_total::Float64, supply_output_total::Float64, use_input_total::Float64, use_output_total::Float64, supply_n_keys::Int, use_n_keys::Int)
    rows = Vector{Vector{String}}()
    for (table, input_total, output_total, n_keys) in (
        ("supply", supply_input_total, supply_output_total, supply_n_keys),
        ("use", use_input_total, use_output_total, use_n_keys),
    )
        diff = output_total - input_total
        tolerance = max(TOL, 1.0e-12 * max(abs(input_total), abs(output_total), 1.0))
        status = abs(diff) <= tolerance ? "PASS" : "FAIL"
        push!(rows, [table, string(input_total), string(output_total), string(diff), string(n_keys), status])
    end
    write_tsv(path, ["table", "input_total", "output_total", "diff", "n_output_keys", "status"], rows)
end

function total_from_file(path::AbstractString)
    rows = read_tsv(path)
    total = 0.0
    for row in rows[2:end]
        total += parse(Float64, row[5])
    end
    return total
end

function explicit_product_targets(region::AbstractString, code::AbstractString, waste_shares, waste_fallback)
    code in SPECIAL_USE_PRODUCT_ROWS && return [(code, 1.0)]

    code in ("CPA_C27_HPP", "CPA_C27_PV", "CPA_C27_BAT", "CPA_C27_ELMA_c") && return [("NEW_ELMA", 1.0)]
    code in ("CPA_C26_DES", "CPA_C26_LAP", "CPA_C26_PRI", "CPA_C26_OFMA_c") && return [("NEW_OFMA", 1.0)]
    code in ("CPA_C26_MOB", "CPA_C26_MON", "CPA_C26_RATV_c") && return [("NEW_RATV", 1.0)]

    code == "CPA_S95_ELMA" && return [("REP_ELMA", 1.0)]
    code == "CPA_S95_OFMA" && return [("REP_OFMA", 1.0)]
    code == "CPA_S95_RATV" && return [("REP_RATV", 1.0)]

    code == "CPA_C33_ELMA" && return [("REF_ELMA", 1.0)]
    code == "CPA_C33_OFMA" && return [("REF_OFMA", 1.0)]
    code == "CPA_C33_RATV" && return [("REF_RATV", 1.0)]

    code == "CPA_G46_ELMA" && return [("REF_ELMA", 1.0)]
    code == "CPA_G46_OFMA" && return [("REF_OFMA", 1.0)]
    code == "CPA_G46_RATV" && return [("REF_RATV", 1.0)]

    code in ("CPA_G47_ELMA", "CPA_N77_ELMA") && return [("REU_ELMA", 1.0)]
    code in ("CPA_G47_OFMA", "CPA_N77_OFMA") && return [("REU_OFMA", 1.0)]
    code in ("CPA_G47_RATV", "CPA_N77_RATV") && return [("REU_RATV", 1.0)]

    code == "CPA_E37-39_res" && return [("UTIL_WASTE", 1.0)]

    if startswith(code, "CPA_E37-39_")
        family = family_from_code(code)
        family == "ELMA" || family == "OFMA" || family == "RATV" || error("Unknown waste family for $(code)")
        rec_share, inc_share = waste_split(region, family, waste_shares, waste_fallback)
        return [("REC_EE", rec_share), ("INC_EE", inc_share)]
    end

    code in ("CPA_A01", "CPA_A02", "CPA_A03", "CPA_C10-12") && return [("AGRI_FOOD", 1.0)]
    (code == "CPA_B" || startswith(code, "CPA_B0")) && return [("EXTRACTIVE", 1.0)]
    code == "CPA_C24" && return [("BASIC_METALS", 1.0)]
    code == "CPA_C25" && return [("METAL_COMPONENTS", 1.0)]
    code == "CPA_F" && return [("CONSTRUCTION", 1.0)]
    code in ("CPA_D35", "CPA_E36") && return [("UTIL_WASTE", 1.0)]
    startswith(code, "CPA_G45") && return [("TRADE", 1.0)]
    startswith(code, "CPA_G46") && return [("TRADE", 1.0)]
    startswith(code, "CPA_G47") && return [("TRADE", 1.0)]
    startswith(code, "CPA_H") && return [("TRANSPORT", 1.0)]
    code in ("CPA_O84", "CPA_P85", "CPA_Q86", "CPA_Q87_88", "CPA_Q87_Q88") && return [("PUBLIC_SOCIAL", 1.0)]

    code in ("CPA_C26_OFMA_res", "CPA_C26_RATV_res", "CPA_C27_ELMA_res") && return [("OTHER_MANUFACTURING", 1.0)]
    code in ("CPA_C33_res", "CPA_S95_res", "CPA_N77_res") && return [("OTHER_SERVICES", 1.0)]

    startswith(code, "CPA_C") && return [("OTHER_MANUFACTURING", 1.0)]
    startswith(code, "CPA_I") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_J") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_K") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_L") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_M") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_N") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_R") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_S") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "CPA_T") && return [("OTHER_SERVICES", 1.0)]

    error("Unmapped product code $(code)")
end

function explicit_use_targets(region::AbstractString, code::AbstractString, waste_shares, waste_fallback)
    code in FINAL_DEMAND_CODES && return [(code, 1.0)]

    code in ("C27_HPP", "C27_PV", "C27_BAT", "C27_ELMA_c") && return [("NEW_ELMA", 1.0)]
    code in ("C26_DES", "C26_LAP", "C26_PRI", "C26_OFMA_c") && return [("NEW_OFMA", 1.0)]
    code in ("C26_MOB", "C26_MON", "C26_RATV_c") && return [("NEW_RATV", 1.0)]

    code == "S95_ELMA" && return [("REP_ELMA", 1.0)]
    code == "S95_OFMA" && return [("REP_OFMA", 1.0)]
    code == "S95_RATV" && return [("REP_RATV", 1.0)]

    code == "C33_ELMA" && return [("REF_ELMA", 1.0)]
    code == "C33_OFMA" && return [("REF_OFMA", 1.0)]
    code == "C33_RATV" && return [("REF_RATV", 1.0)]

    code == "G46_ELMA" && return [("REF_ELMA", 1.0)]
    code == "G46_OFMA" && return [("REF_OFMA", 1.0)]
    code == "G46_RATV" && return [("REF_RATV", 1.0)]

    code in ("G47_ELMA", "N77_ELMA") && return [("REU_ELMA", 1.0)]
    code in ("G47_OFMA", "N77_OFMA") && return [("REU_OFMA", 1.0)]
    code in ("G47_RATV", "N77_RATV") && return [("REU_RATV", 1.0)]

    code == "E37-E39_res" && return [("UTIL_WASTE", 1.0)]

    if startswith(code, "E37-E39_")
        family = family_from_code(code)
        family == "ELMA" || family == "OFMA" || family == "RATV" || error("Unknown waste family for $(code)")
        rec_share, inc_share = waste_split(region, family, waste_shares, waste_fallback)
        return [("REC_EE", rec_share), ("INC_EE", inc_share)]
    end

    code in ("A01", "A02", "A03", "C10-C12", "C10-12") && return [("AGRI_FOOD", 1.0)]
    (code == "B" || startswith(code, "B0")) && return [("EXTRACTIVE", 1.0)]
    code == "C24" && return [("BASIC_METALS", 1.0)]
    code == "C25" && return [("METAL_COMPONENTS", 1.0)]
    code == "F" && return [("CONSTRUCTION", 1.0)]
    code in ("D35", "E36", "E37-39") && return [("UTIL_WASTE", 1.0)]
    startswith(code, "G45") && return [("TRADE", 1.0)]
    startswith(code, "G46") && return [("TRADE", 1.0)]
    startswith(code, "G47") && return [("TRADE", 1.0)]
    startswith(code, "H") && return [("TRANSPORT", 1.0)]
    code in ("O84", "P85", "Q86", "Q87_88", "Q87_Q88") && return [("PUBLIC_SOCIAL", 1.0)]

    code in ("C26_OFMA_res", "C26_RATV_res", "C27_ELMA_res") && return [("OTHER_MANUFACTURING", 1.0)]
    code in ("C33_res", "S95_res", "N77_res") && return [("OTHER_SERVICES", 1.0)]

    startswith(code, "C") && return [("OTHER_MANUFACTURING", 1.0)]
    startswith(code, "I") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "J") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "K") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "L") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "M") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "N") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "R") && return [("OTHER_SERVICES", 1.0)]
    startswith(code, "S") && return [("OTHER_SERVICES", 1.0)]
    code == "T" && return [("OTHER_SERVICES", 1.0)]

    error("Unmapped use code $(code)")
end

function aggregate_supply(waste_shares, waste_fallback)
    rows = read_tsv(IN_SUPPLY)
    totals = Dict{NTuple{4,String},Float64}()
    map_rows = Vector{Vector{String}}()

    seen_maps = Set{Tuple{String,String,String,String}}()
    for row in rows[2:end]
        product_region, product_code, activity_region, activity_code, value_str = row
        value = parse(Float64, value_str)
        product_targets = explicit_product_targets(product_region, product_code, waste_shares, waste_fallback)
        activity_targets = explicit_use_targets(activity_region, activity_code, waste_shares, waste_fallback)

        for (psector, pshare) in product_targets
            map_key = (product_region, product_code, psector, string(pshare))
            map_key in seen_maps || (push!(seen_maps, map_key); push!(map_rows, [product_region, product_code, psector, string(pshare)]))
            for (asector, ashare) in activity_targets
                add_value!(totals, (product_region, psector, activity_region, asector), value * pshare * ashare)
            end
        end
    end

    return totals, sort!(map_rows, by = x -> join(x, '\t'))
end

function aggregate_use(waste_shares, waste_fallback)
    rows = read_tsv(IN_USE)
    totals = Dict{NTuple{4,String},Float64}()
    map_rows = Vector{Vector{String}}()

    seen_maps = Set{Tuple{String,String,String,String}}()
    for row in rows[2:end]
        product_region, product_code, use_region, use_code, value_str = row
        value = parse(Float64, value_str)
        product_targets = explicit_product_targets(product_region, product_code, waste_shares, waste_fallback)
        use_targets = explicit_use_targets(use_region, use_code, waste_shares, waste_fallback)

        for (use_sector, use_share) in use_targets
            map_key = (use_region, use_code, use_sector, string(use_share))
            map_key in seen_maps || (push!(seen_maps, map_key); push!(map_rows, [use_region, use_code, use_sector, string(use_share)]))
        end
        for (psector, pshare) in product_targets
            for (use_sector, use_share) in use_targets
                add_value!(totals, (product_region, psector, use_region, use_sector), value * pshare * use_share)
            end
        end
    end

    return totals, sort!(map_rows, by = x -> join(x, '\t'))
end

function write_matrix(path::AbstractString, totals::Dict{NTuple{4,String},Float64}; third_col::String, fourth_col::String)
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(totals)))
        value = totals[key]
        abs(value) <= 1.0e-12 && continue
        push!(rows, [key[1], key[2], key[3], key[4], string(value)])
    end
    write_tsv(path, ["product_region", "product_sector", third_col, fourth_col, "value_meur"], rows)
end

function write_registry_slices()
    rows = read_tsv(FINAL_REGISTRY)
    header = rows[1]
    explicit_rows = [row for row in rows[2:end] if row[6] == "explicit_sut_sector" || row[6] == "constructed_sut_sector"]
    route_rows = [row for row in rows[2:end] if row[6] == "constructed_sut_sector"]
    write_tsv(OUT_EXPLICIT_REGISTRY, header, explicit_rows)
    write_tsv(OUT_ROUTE_REGISTRY, header, route_rows)
end

function main()
    ensure_dir(OUTDIR)
    waste_shares, waste_fallback = load_waste_route_shares()

    supply_totals, product_map_rows = aggregate_supply(waste_shares, waste_fallback)
    use_totals, use_map_rows = aggregate_use(waste_shares, waste_fallback)
    supply_input_total = total_from_file(IN_SUPPLY)
    use_input_total = total_from_file(IN_USE)

    write_matrix(OUT_SUPPLY, supply_totals; third_col = "activity_region", fourth_col = "activity_sector")
    write_matrix(OUT_USE, use_totals; third_col = "use_region", fourth_col = "use_code")
    write_tsv(OUT_PRODUCT_MAP, ["region", "product_code", "product_sector", "share"], product_map_rows)
    write_tsv(OUT_USE_MAP, ["region", "product_code", "product_sector", "share"], use_map_rows)
    write_registry_slices()
    write_validation(OUT_VALIDATION, supply_input_total, sum(values(supply_totals)), use_input_total, sum(values(use_totals)), length(supply_totals), length(use_totals))

    println("Wrote stage-3 artifacts to ", OUTDIR)
end

main()
