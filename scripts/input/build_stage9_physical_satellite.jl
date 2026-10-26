#!/usr/bin/env julia

# Observed physical anchors are the V2 parent-family production totals.
# Electronics purchased by repair or treatment businesses are intermediate
# inputs. A_GLAS_reuse is bottle reuse; it does not measure electronics reuse.

include(joinpath(@__DIR__, "bonsai_family_outputs.jl"))
using .BonsaiFamilyOutputs

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const REGION_MAP_FILE = joinpath(ROOT_DIR, "data", "mappings", "figaro_region_map.tsv")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "08_six_region_bundle")
const OUT_DETAIL = joinpath(OUTDIR, "regional_observed_physical_flow_detail.tsv")
const OUT_SUMMARY = joinpath(OUTDIR, "regional_observed_physical_flows.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "physical_satellite_validation.tsv")
const MODEL_REGIONS = Set(["DE", "FR", "IT", "PL", "SK", "REU"])
const SOURCE_LABEL = "BONSAI V2; DOI " * SOURCE_DOI

function read_region_map(path::AbstractString)
    rows = readlines(path)
    return Dict(String(a) => String(b) for (a, b) in (split(row, '\t') for row in rows[2:end]))
end

function write_tsv(path, header, rows)
    open(path, "w") do io
        println(io, join(header, '\t'))
        for row in rows
            println(io, join(row, '\t'))
        end
    end
end

function collected_flows(region_map)
    detail = Dict{NTuple{8,String},Float64}()
    for ((country, family), tonnes) in load_family_outputs()
        region = get(region_map, country, nothing)
        region in MODEL_REGIONS || continue
        detail[(region, family, "NEW", "new_product_output", country,
                "A_" * family, "C_" * family, "tonnes")] = tonnes
    end
    return detail
end

function summary_rows(detail)
    summary = Dict{Tuple{String,String},Tuple{Float64,Int}}()
    for (key, tonnes) in detail
        region, family, route, kind, _, _, _, unit = key
        route == "NEW" && kind == "new_product_output" && unit == "tonnes" ||
            error("Unsupported physical anchor: $key")
        value, count = get(summary, (region, family), (0.0, 0))
        summary[(region, family)] = (value + tonnes, count + 1)
    end
    return [[region, family, "NEW", "new_product_output", "tonnes", string(summary[(region, family)][1]),
        string(summary[(region, family)][2]), "observed", SOURCE_LABEL,
        "V2 parent production; each source-country family retained once"]
        for (region, family) in sort!(collect(keys(summary)))]
end

function validation_rows(summary)
    expected = Set((region, family) for region in MODEL_REGIONS for family in ("ELMA", "OFMA", "RATV"))
    keys_found = [(row[1], row[2]) for row in summary]
    coverage = Set(keys_found) == expected && length(keys_found) == length(expected)
    scope = all(row[3] == "NEW" && row[4] == "new_product_output" && row[8] == "observed" for row in summary)
    positive = all(isfinite(parse(Float64, row[6])) && parse(Float64, row[6]) > 0 for row in summary)
    units = all(row[5] == "tonnes" for row in summary)
    source = aggregate_family_outputs(read_region_map(REGION_MAP_FILE))
    gap = coverage ? maximum(abs(parse(Float64, row[6]) - source[(row[1], row[2])]) for row in summary) : Inf
    return [
        ["new_product_output_coverage", coverage ? "pass" : "fail", string(length(keys_found)), "18", "One production anchor for each modeled region and electronics family."],
        ["verified_observation_scope", scope ? "pass" : "fail", scope ? "NEW production only" : "unsupported observation", "NEW production only", "Business purchases and bottle reuse do not measure used-device throughput."],
        ["positive_mass_flows", positive ? "pass" : "fail", string(positive), "true", "Verified production masses are finite and strictly positive."],
        ["tonnes_only", units ? "pass" : "fail", string(units), "true", "Production anchors use tonnes; treatment-service quantities remain allocation proxies."],
        ["V2_source_output_match", gap <= 1e-6 ? "pass" : "fail", string(gap), "<= 1e-6 tonnes", "Aggregated anchors reproduce the V2 source outputs within summation precision."],
    ]
end

function main(; outdir = OUTDIR)
    mkpath(outdir)
    detail = collected_flows(read_region_map(REGION_MAP_FILE))
    detail_rows = [[collect(key)..., string(detail[key]), "observed", SOURCE_LABEL] for key in sort!(collect(keys(detail)))]
    summary = summary_rows(detail)
    validation = validation_rows(summary)
    all(row[2] == "pass" for row in validation) || error("Physical-anchor validation failed")
    write_tsv(joinpath(outdir, basename(OUT_DETAIL)),
        ["region", "family", "route", "flow_kind", "source_country", "source_node", "target_node", "physical_unit", "value_tonnes", "status", "source"], detail_rows)
    write_tsv(joinpath(outdir, basename(OUT_SUMMARY)),
        ["region", "family", "route", "flow_kind", "physical_unit", "value_tonnes", "source_flow_count", "status", "source", "source_rule"], summary)
    write_tsv(joinpath(outdir, basename(OUT_VALIDATION)), ["check", "status", "observed", "expected", "notes"], validation)
    println("Wrote 18 verified family-production anchors to ", outdir)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
