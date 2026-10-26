module BonsaiFamilyOutputs

export FAMILY_OUTPUT_FILE, SOURCE_DOI, load_family_outputs,
       aggregate_family_outputs, output_family

const FAMILY_OUTPUT_FILE = normpath(joinpath(
    @__DIR__, "..", "..", "data", "disaggregation", "bonsai_family_outputs.tsv",
))
const SOURCE_DOI = "10.5281/zenodo.23342753"
const FAMILIES = ("ELMA", "OFMA", "RATV")

"""Identify a same-country family activity-to-product output recorded in tonnes."""
function output_family(origin, source, destination, target, unit)
    origin == destination && unit == "tonnes" || return nothing
    for family in FAMILIES
        source == "A_" * family && target == "C_" * family && return family
    end
    return nothing
end

"""
Read the positive family outputs extracted from the V2 workbook's
`Production_result.parent_production` column. Repeated child rows contribute
one parent value, not their sum. Regenerate with import_bonsai_family_outputs.jl.
"""
function load_family_outputs(path::AbstractString = FAMILY_OUTPUT_FILE)
    isfile(path) || error("Missing BONSAI V2 family outputs: $path")
    outputs = Dict{Tuple{String,String},Float64}()
    open(path, "r") do io
        split(readline(io), '\t') == ["source_country", "family", "output_tonnes"] ||
            error("Unexpected BONSAI family-output header in $path")
        for line in eachline(io)
            isempty(line) && continue
            fields = split(line, '\t')
            length(fields) == 3 || error("Malformed family-output row in $path")
            country, family, value = fields
            family in FAMILIES || error("Unknown electronics family: $family")
            tonnes = parse(Float64, value)
            isfinite(tonnes) && tonnes > 0 || error("Invalid family output: $line")
            key = (String(country), String(family))
            haskey(outputs, key) && error("Duplicate family output: $key")
            outputs[key] = tonnes
        end
    end
    isempty(outputs) && error("Empty BONSAI family-output table: $path")
    return outputs
end

"""Aggregate source-country outputs using the same regional map as the SUT."""
function aggregate_family_outputs(region_map; outputs = load_family_outputs())
    totals = Dict{Tuple{String,String},Float64}()
    for ((country, family), tonnes) in outputs
        haskey(region_map, country) || error("Missing regional mapping for $country")
        key = (region_map[country], family)
        totals[key] = get(totals, key, 0.0) + tonnes
    end
    return totals
end

end
