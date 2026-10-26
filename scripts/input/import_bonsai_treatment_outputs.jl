#!/usr/bin/env julia

#=
Import discarded-equipment treatment outputs from the 2016 BONSAI supply table
in DOI 10.5281/zenodo.23157221 (D3.2. V1.zip).

Usage: julia --project=. scripts/input/import_bonsai_treatment_outputs.jl [archive.zip | supply.csv]

With no argument, download the archived ZIP temporarily. Keep only treatment
activity-to-matching-product outputs in tonnes (service), excluding emissions,
by-products, purchases of electronics by treatment activities and other waste.
Source quantities, including their numerical precision, are not adjusted.
=#
using CSV
using Downloads
using SHA

include(joinpath(@__DIR__, "discarded_equipment_treatment.jl"))
using .DiscardedEquipmentTreatment

const ARCHIVE_URL = "https://zenodo.org/api/records/23157221/files/D3.2.%20V1.zip/content"
const ARCHIVE_SHA256 = "399d8ebe9887264450e8205cb5922f1f7e7debc9d00b04f9d8467a408836d725"
const SUPPLY_SHA256 = "2fd05246a296996d83d389e8ca833898ed295fd625b74e3a1dd25bbe797b4a1e"
const TABLES_ENTRY = "D3.2. V1/CE-RISE D3.2 Tables.zip"
const SUPPLY_ENTRY = "BONSAI disaggregation/code delivery/BONSAI data/september version/hybrid_supply_w_characteristic_unit.csv"

function check_hash(path, expected)
    bytes2hex(open(sha256, path)) == expected || error("File differs from the verified BONSAI archive: $path")
end

function import_treatment_supply(path; outfile = TREATMENT_FILE)
    check_hash(path, SUPPLY_SHA256)
    totals = Dict{Tuple{String,String},Float64}()
    for row in CSV.File(path)
        activity = row[Symbol("Exio act code")]
        haskey(TREATMENT_ROUTES, activity) || continue
        product, _ = TREATMENT_ROUTES[activity]
        row[Symbol("Exio prod code")] == product && row.layer == "WASTE_SERVICE" &&
            row.unit == "tonnes (service)" || continue
        origin = row[Symbol("Exio origin country code")]
        origin == row[Symbol("Exio destin. country code")] || error("Cross-country treatment supply")
        isfinite(row.Value) && row.Value >= 0 || error("Invalid source treatment output")
        row.Value == 0 && continue
        key = (String(origin), String(activity))
        totals[key] = get(totals, key, 0.0) + row.Value
    end
    isempty(totals) && error("No discarded-equipment treatment outputs found")
    mkpath(dirname(outfile))
    open(outfile, "w") do io
        println(io, "source_country\tactivity_code\tproduct_code\troute\tphysical_unit\tvalue_service_tonnes")
        for (country, activity) in sort!(collect(keys(totals)))
            product, route = TREATMENT_ROUTES[activity]
            println(io, join((country, activity, product, route, "tonnes (service)", totals[(country, activity)]), '\t'))
        end
    end
    treatment_totals(; path = outfile)
    println("Imported ", length(totals), " recorded treatment outputs from ", TREATMENT_DOI)
end

function import_archive(path)
    check_hash(path, ARCHIVE_SHA256)
    unzip = Sys.which("unzip")
    unzip === nothing && error("The system unzip utility is required")
    mktempdir() do dir
        nested = joinpath(dir, "tables.zip")
        supply = joinpath(dir, "supply.csv")
        run(pipeline(`$unzip -p $path $TABLES_ENTRY`; stdout = nested))
        run(pipeline(`$unzip -p $nested $SUPPLY_ENTRY`; stdout = supply))
        import_treatment_supply(supply)
    end
end

function main(args = ARGS)
    length(args) <= 1 || error("Usage: import_bonsai_treatment_outputs.jl [archive.zip | supply.csv]")
    if isempty(args)
        mktempdir() do dir
            archive = Downloads.download(ARCHIVE_URL, joinpath(dir, "archive.zip"))
            import_archive(archive)
        end
    elseif endswith(lowercase(only(args)), ".csv")
        import_treatment_supply(only(args))
    else
        import_archive(only(args))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
