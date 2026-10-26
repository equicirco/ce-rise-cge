module DiscardedEquipmentTreatment

export TREATMENT_FILE, TREATMENT_DOI, TREATMENT_ROUTES, treatment_totals,
       treatment_shares, treatment_configuration, write_treatment_shares,
       read_treatment_shares, SHARE_HEADER, seed_output_floor, treatment_budgets

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const TREATMENT_FILE = joinpath(ROOT, "data", "disaggregation", "bonsai_discarded_equipment_treatment.tsv")
const TREATMENT_DOI = "10.5281/zenodo.23157221"
const TREATMENT_ROUTES = Dict(
    "A_DE_RECY" => ("C_DE_RECY", "recycling"),
    "A_DE_INCI" => ("C_DE_INCI", "incineration_energy"),
    "A_DE_INCI_no_recov" => ("C_DE_INCI_no_recov", "incineration"),
    "A_DE_LAND" => ("C_DE_LAND", "landfill"),
    "A_DE_OTHE" => ("C_DE_OTHE", "other_disposal"),
)
const REGIONS = ("DE", "FR", "IT", "PL", "SK", "REU")
const SHARE_HEADER = ["source_area", "mix_basis", "reference_recycling_service_tonnes",
    "reference_disposal_service_tonnes", "recorded_recycling_share", "recorded_disposal_share",
    "calibrated_recycling_share", "calibrated_disposal_share", "disposal_seeded"]

function treatment_configuration()
    rows = readlines(joinpath(ROOT, "data", "mappings", "treatment_allocation.tsv"))
    options = Dict(split(row, '\t')[1] => parse(Float64, split(row, '\t')[2]) for row in rows[2:end])
    0 < options["zero_disposal_share"] < 1 || error("Invalid zero-disposal calibration share")
    options["seed_bound_multiple"] > 1 || error("Invalid seed bound multiple")
    return options
end

"""Monetary output corresponding to the declared margin above the model quantity bound."""
function seed_output_floor()
    rows = readlines(joinpath(ROOT, "data", "mappings", "model_configuration.tsv"))
    options = Dict((split(row, '\t')[1], split(row, '\t')[2]) => split(row, '\t')[3] for row in rows[2:end])
    bound = parse(Float64, options[("numerical", "model_positive_lower")])
    price = parse(Float64, options[("normalization", "base_price")])
    return bound * price * treatment_configuration()["seed_bound_multiple"]
end

"""Monetary output allocated to electronics treatment before the recycling/disposal split."""
function treatment_budgets(path)
    totals = Dict{String,Float64}()
    open(path, "r") do io
        readline(io)
        for line in eachline(io)
            fields = split(line, '\t')
            any(fields[4] == prefix * family for prefix in ("E37-E39_", "E37-39_")
                for family in ("ELMA", "OFMA", "RATV")) || continue
            region = String(fields[3])
            totals[region] = get(totals, region, 0.0) + parse(Float64, fields[5])
        end
    end
    return totals
end

"""Recorded treatment-service outputs, aggregated to the six European regions."""
function treatment_totals(; path = TREATMENT_FILE)
    maprows = readlines(joinpath(ROOT, "data", "mappings", "figaro_region_map.tsv"))
    region_map = Dict(Pair(split(row, '\t')...) for row in maprows[2:end])
    categories = sort!([route[2] for route in values(TREATMENT_ROUTES)])
    totals = Dict((region, category) => 0.0 for region in REGIONS for category in categories)
    lines = readlines(path)
    split(lines[1], '\t') == ["source_country", "activity_code", "product_code", "route", "physical_unit", "value_service_tonnes"] ||
        error("Unexpected discarded-equipment treatment header")
    seen = Set{Tuple{String,String}}()
    for line in lines[2:end]
        country, activity, product, route, unit, raw = split(line, '\t')
        haskey(TREATMENT_ROUTES, activity) && TREATMENT_ROUTES[activity] == (product, route) ||
            error("Unsupported discarded-equipment treatment record: $line")
        unit == "tonnes (service)" || error("Treatment outputs must be in tonnes (service)")
        value = parse(Float64, raw)
        isfinite(value) && value > 0 || error("Invalid recorded treatment output")
        key = (String(country), String(activity))
        key in seen && error("Duplicate recorded treatment output: $key")
        push!(seen, key)
        haskey(region_map, country) || error("Unmapped treatment source country: $country")
        region = region_map[country]
        region in REGIONS || error("Unexpected non-European treatment record: $country")
        totals[(region, route)] += value
    end
    return totals
end

"""
Use the same regional treatment mix for each electronics family. A positive
disposal seed changes calibration shares only, never the source observations.
The pooled European mix allocates extra-European transactions; it is not an
observed treatment mix or production system for a modeled ROW region.
"""
function treatment_shares(; path = TREATMENT_FILE, zero_disposal_share = treatment_configuration()["zero_disposal_share"])
    0 < zero_disposal_share < 1 || error("Invalid zero-disposal calibration share")
    totals = treatment_totals(; path)
    rows = NamedTuple[]
    for region in REGIONS
        recycling = totals[(region, "recycling")]
        disposal = sum(totals[(region, category)] for category in
            ("incineration_energy", "incineration", "landfill", "other_disposal"))
        recycling > 0 || error("Missing positive recorded recycling for $region")
        seeded = disposal == 0
        observed = disposal / (recycling + disposal)
        calibrated = seeded ? zero_disposal_share : observed
        push!(rows, (region = region, basis = "regional_records", recycling = recycling,
            disposal = disposal, observed_rec = 1 - observed, observed_inc = observed,
            calibrated_rec = 1 - calibrated, calibrated_inc = calibrated, seeded = seeded))
    end
    recycling = sum(row.recycling for row in rows)
    disposal = sum(row.disposal for row in rows)
    share = disposal / (recycling + disposal)
    push!(rows, (region = "ROW", basis = "pooled_european_external_trade_proxy",
        recycling = recycling, disposal = disposal, observed_rec = 1 - share, observed_inc = share,
        calibrated_rec = 1 - share, calibrated_inc = share, seeded = false))
    return rows
end

function write_treatment_shares(path, rows)
    open(path, "w") do io
        println(io, join(SHARE_HEADER, '\t'))
        for row in rows
            println(io, join(string.(values(row)), '\t'))
        end
    end
end

function read_treatment_shares(path)
    lines = readlines(path)
    split(lines[1], '\t') == SHARE_HEADER || error("Unexpected treatment-share header")
    rows = NamedTuple[]
    for line in lines[2:end]
        fields = split(line, '\t')
        length(fields) == length(SHARE_HEADER) || error("Malformed treatment-share row")
        a = parse.(Float64, fields[3:8])
        push!(rows, (region = String(fields[1]), basis = String(fields[2]), recycling = a[1],
            disposal = a[2], observed_rec = a[3], observed_inc = a[4],
            calibrated_rec = a[5], calibrated_inc = a[6], seeded = parse(Bool, fields[9])))
    end
    expected = treatment_shares()
    rows == expected || error("Treatment shares differ from their recorded source and calibration rule; regenerate them")
    return rows
end

end
