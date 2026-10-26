#!/usr/bin/env julia

# Regional discarded-equipment treatment-service totals. Electronics purchases
# by repair or waste businesses are not treated as used-device throughput.

include(joinpath(@__DIR__, "discarded_equipment_treatment.jl"))
using .DiscardedEquipmentTreatment

const OUTDIR = normpath(joinpath(@__DIR__, "..", "..", "data", "interim", "structure"))
const OUT_TOTALS = joinpath(OUTDIR, "discarded_equipment_treatment_totals.tsv")

function main()
    totals = treatment_totals()
    mkpath(OUTDIR)
    open(OUT_TOTALS, "w") do io
        println(io, "region\troute_category\tphysical_unit\tvalue_service_tonnes")
        for (region, category) in sort!(collect(keys(totals)))
            println(io, join((region, category, "tonnes (service)", totals[(region, category)]), '\t'))
        end
    end
    println("Wrote recorded treatment-service totals to ", OUT_TOTALS)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
