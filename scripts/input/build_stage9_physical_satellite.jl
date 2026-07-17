#!/usr/bin/env julia

"""
Build observed physical-flow anchors for the CE-RISE physical satellite.

Only direct BONSAI flows recorded in tonnes are retained.  The output does not
construct product counts, metal contents, recovery yields, or a complete
end-of-life stream.  It records:

- family-level new-product output from parent activity-to-product flows;
- identified mass flows from family markets to repair, reuse, recycling, and
  incineration/landfill activities.

The latter are labelled `route_input_mass`: they are observed inputs to an
identified circular route, not an assertion that they exhaust all end-of-life
products in a region.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DISAGGREGATION_FILE = joinpath(
    ROOT_DIR,
    "data",
    "disaggregation",
    "parent_and_disaggregated_rows_sup_and_use.csv",
)
const REGION_MAP_FILE = joinpath(ROOT_DIR, "data", "mappings", "figaro_region_map.tsv")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "08_six_region_bundle")
const OUT_DETAIL = joinpath(OUTDIR, "regional_observed_physical_flow_detail.tsv")
const OUT_SUMMARY = joinpath(OUTDIR, "regional_observed_physical_flows.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "physical_satellite_validation.tsv")

const MODEL_REGIONS = Set(["DE", "FR", "IT", "PL", "SK", "REU"])
const PARENT_OUTPUTS = Dict(
    "A_ELMA" => (family = "ELMA", product = "C_ELMA"),
    "A_OFMA" => (family = "OFMA", product = "C_OFMA"),
    "A_RATV" => (family = "RATV", product = "C_RATV"),
)
const FAMILY_MARKETS = Dict(
    "M_ELMA" => "ELMA",
    "M_ELMA_c" => "ELMA",
    "M_HPP" => "ELMA",
    "M_PV" => "ELMA",
    "M_BAT" => "ELMA",
    "M_OFMA" => "OFMA",
    "M_OFMA_c" => "OFMA",
    "M_LAP" => "OFMA",
    "M_DES" => "OFMA",
    "M_PRI" => "OFMA",
    "M_RATV" => "RATV",
    "M_RATV_c" => "RATV",
    "M_MOB" => "RATV",
    "M_MON" => "RATV",
)

function read_region_map(path::AbstractString)
    map = Dict{String,String}()
    open(path, "r") do io
        first = true
        for line in eachline(io)
            first && (first = false; continue)
            isempty(line) && continue
            source, target = split(line, '\t')
            map[source] = target
        end
    end
    return map
end

function write_tsv(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(header, '\t'))
        for row in rows
            println(io, join(row, '\t'))
        end
    end
end

function route_for_activity(node::AbstractString)
    node in ("A_REPAIR", "A_REP_INST", "A_ORGA|A_PERS_SER|A_REPAIR") && return "REP"
    node == "A_GLAS_reuse" && return "REU"
    occursin(r"^A_.*_RECY$", node) && return "REC"
    occursin(r"^A_.*_(INCI|LAND)$", node) && return "INC"
    return nothing
end

function parse_header(path::AbstractString)
    header = split(chomp(readline(path)), ',')
    index = Dict(name => position for (position, name) in enumerate(header))
    required = [
        "from_node_location",
        "from_node_name",
        "to_node_location",
        "to_node_name",
        "unit",
        "value",
    ]
    for name in required
        haskey(index, name) || error("Missing $(name) in $(path)")
    end
    return index
end

function collected_flows(region_map)
    detail = Dict{NTuple{8,String},Float64}()
    index = open(DISAGGREGATION_FILE, "r") do io
        parse_header(DISAGGREGATION_FILE)
    end

    open(DISAGGREGATION_FILE, "r") do io
        readline(io)
        for line in eachline(io)
            isempty(line) && continue
            fields = split(chomp(line), ',')
            maximum(values(index)) <= length(fields) ||
                error("Malformed row in $(DISAGGREGATION_FILE): $(line)")
            origin_country = fields[index["from_node_location"]]
            destination_country = fields[index["to_node_location"]]
            origin_country == destination_country || continue
            region = get(region_map, origin_country, nothing)
            region in MODEL_REGIONS || continue
            unit = fields[index["unit"]]
            unit == "tonnes" || continue
            source = fields[index["from_node_name"]]
            target = fields[index["to_node_name"]]
            value = parse(Float64, fields[index["value"]])
            value > 0.0 || continue

            if haskey(PARENT_OUTPUTS, source) && target == PARENT_OUTPUTS[source].product
                family = PARENT_OUTPUTS[source].family
                key = (region, family, "NEW", "new_product_output", origin_country, source, target, unit)
                detail[key] = get(detail, key, 0.0) + value
            end

            family = get(FAMILY_MARKETS, source, nothing)
            route = route_for_activity(target)
            if family !== nothing && route !== nothing
                key = (region, family, route, "route_input_mass", origin_country, source, target, unit)
                detail[key] = get(detail, key, 0.0) + value
            end
        end
    end
    return detail
end

function summary_rows(detail)
    summary = Dict{NTuple{5,String},Tuple{Float64,Int}}()
    for (key, value) in detail
        region, family, route, flow_kind, _, _, _, unit = key
        summary_key = (region, family, route, flow_kind, unit)
        current_value, current_count = get(summary, summary_key, (0.0, 0))
        summary[summary_key] = (current_value + value, current_count + 1)
    end
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(summary)))
        value, count = summary[key]
        region, family, route, flow_kind, unit = key
        source_rule = flow_kind == "new_product_output" ?
            "family parent activity to matching family parent product" :
            "selected family market to identified circular-route activity"
        push!(rows, [
            region,
            family,
            route,
            flow_kind,
            unit,
            string(value),
            string(count),
            "observed",
            "BONSAI-derived CE-RISE disaggregation",
            source_rule,
        ])
    end
    return rows
end

function validation_rows(summary)
    new_keys = Set((row[1], row[2]) for row in summary if row[3] == "NEW" && row[4] == "new_product_output")
    expected = Set((region, family) for region in MODEL_REGIONS for family in ("ELMA", "OFMA", "RATV"))
    missing_new = sort!(collect(setdiff(expected, new_keys)))
    positive = all(parse(Float64, row[6]) > 0.0 for row in summary)
    tonnes_only = all(row[5] == "tonnes" for row in summary)
    observed_only = all(row[8] == "observed" for row in summary)
    return [
        ["new_product_output_coverage", isempty(missing_new) ? "pass" : "fail", string(length(new_keys)), "18", isempty(missing_new) ? "All region-family new-product mass anchors are present." : join([join(key, ":") for key in missing_new], ";")],
        ["positive_mass_flows", positive ? "pass" : "fail", positive ? "all_positive" : "nonpositive_present", "all_positive", "Observed physical flows must be strictly positive."],
        ["tonnes_only", tonnes_only ? "pass" : "fail", tonnes_only ? "tonnes" : "mixed_units", "tonnes", "The first satellite retains the observed mass basis without product-count conversion."],
        ["observed_only", observed_only ? "pass" : "fail", observed_only ? "observed" : "other_status", "observed", "This stage does not construct physical values."],
    ]
end

function main()
    isfile(DISAGGREGATION_FILE) || error("Missing supplied disaggregation data: $(DISAGGREGATION_FILE)")
    mkpath(OUTDIR)
    detail = collected_flows(read_region_map(REGION_MAP_FILE))
    detail_rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(detail)))
        region, family, route, flow_kind, source_country, source, target, unit = key
        push!(detail_rows, [
            region,
            family,
            route,
            flow_kind,
            source_country,
            source,
            target,
            unit,
            string(detail[key]),
            "observed",
            "BONSAI-derived CE-RISE disaggregation",
        ])
    end
    summary = summary_rows(detail)
    validation = validation_rows(summary)
    write_tsv(
        OUT_DETAIL,
        ["region", "family", "route", "flow_kind", "source_country", "source_node", "target_node", "physical_unit", "value_tonnes", "status", "source"],
        detail_rows,
    )
    write_tsv(
        OUT_SUMMARY,
        ["region", "family", "route", "flow_kind", "physical_unit", "value_tonnes", "source_flow_count", "status", "source", "source_rule"],
        summary,
    )
    write_tsv(OUT_VALIDATION, ["check", "status", "observed", "expected", "notes"], validation)
    println("Wrote:")
    println("  ", OUT_DETAIL)
    println("  ", OUT_SUMMARY)
    println("  ", OUT_VALIDATION)
end

main()
