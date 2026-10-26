using Test

module TreatmentAllocationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "build_stage3_final_artifacts.jl"))
end

module TreatmentValidationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "validate_sut_totals.jl"))
end

@testset "Discarded-equipment treatment allocation" begin
    stage = TreatmentAllocationChecks
    treatment = stage.DiscardedEquipmentTreatment
    validator = TreatmentValidationChecks
    recorded = treatment.treatment_totals()
    rows = treatment.treatment_shares()
    pl = only(filter(row -> row.region == "PL", rows))
    @test isapprox(pl.recycling, 380905.0000092245; atol = 1e-6)
    @test pl.disposal == 0
    @test pl.observed_inc == 0
    @test pl.observed_rec == 1
    @test pl.calibrated_inc == 0.0001
    @test pl.calibrated_rec == 0.9999
    @test pl.seeded
    @test count(row -> row.seeded, rows) == 1
    @test sum(value for ((region, category), value) in recorded if region == "PL" && category != "recycling") == 0
    external = only(filter(row -> row.region == "ROW", rows))
    @test external.basis == "pooled_european_external_trade_proxy"
    @test external.recycling == sum(row.recycling for row in rows if row.region != "ROW")
    for row in rows
        @test row.calibrated_rec + row.calibrated_inc == 1
        @test 0 < row.calibrated_inc < 1
        if !row.seeded
            @test row.calibrated_inc == row.observed_inc
        end
    end

    mktempdir() do dir
        path = joinpath(dir, "shares.tsv")
        treatment.write_treatment_shares(path, rows)
        @test treatment.read_treatment_shares(path) == rows
        shares, metadata = stage.load_waste_route_shares(path)
        for row in rows, family in ("ELMA", "OFMA", "RATV")
            @test stage.waste_split(row.region, family, shares, metadata) == (row.calibrated_rec, row.calibrated_inc)
            @test stage.explicit_product_targets(row.region, "CPA_E37-39_" * family, shares, metadata) ==
                [("REC_EE", row.calibrated_rec), ("INC_EE", row.calibrated_inc)]
        end
        @test_throws ErrorException stage.waste_split("UNKNOWN", "ELMA", shares, metadata)

        fixture = joinpath(dir, "supply.tsv")
        open(fixture, "w") do io
            println(io, "product_region\tproduct_code\tactivity_region\tactivity_code\tvalue_meur")
            for row in rows, (family, value) in zip(("ELMA", "OFMA", "RATV"), (10.0, 20.0, 30.0))
                println(io, join((row.region, "CPA_E37-39_" * family, row.region, "E37-E39_" * family, value), '\t'))
            end
        end
        supply, _ = stage.aggregate_supply(shares, metadata; infile = fixture)
        uses, _ = stage.aggregate_use(shares, metadata; infile = fixture)
        @test isapprox(sum(values(supply)), 420.0; atol = 1e-10)
        @test isapprox(sum(values(uses)), 420.0; atol = 1e-10)
        audit = joinpath(dir, "audit.tsv")
        stage.write_treatment_allocation(audit, supply, metadata; source_file = fixture)
        @test validator.treatment_allocation_check(audit; source_file = fixture)[3] == "PASS"
        tiny_supply = Dict(key => value * 1e-8 for (key, value) in supply)
        tiny_fixture = joinpath(dir, "tiny.tsv")
        write(tiny_fixture, replace(read(fixture, String), "10.0" => "1e-7", "20.0" => "2e-7", "30.0" => "3e-7"))
        @test_throws ErrorException stage.write_treatment_allocation(joinpath(dir, "too_small.tsv"), tiny_supply, metadata; source_file = tiny_fixture)
        for row in rows
            inc = sum(value for (key, value) in supply if key[3] == row.region && key[4] == "INC_EE")
            rec = sum(value for (key, value) in supply if key[3] == row.region && key[4] == "REC_EE")
            @test isapprox(inc + rec, 60.0; atol = 1e-10)
            @test isapprox(inc / (inc + rec), row.calibrated_inc; atol = 1e-12)
        end
        # A ten-times-smaller seed also preserves accounting; this is not an
        # equilibrium or policy-outcome stability test.
        smaller = treatment.treatment_shares(; zero_disposal_share = 1e-5)
        smaller_shares = Dict(row.region => (row.calibrated_rec, row.calibrated_inc) for row in smaller)
        smaller_supply, _ = stage.aggregate_supply(smaller_shares, smaller; infile = fixture)
        stage.write_treatment_allocation(joinpath(dir, "smaller.tsv"), smaller_supply, smaller; source_file = fixture)
        @test isapprox(sum(values(smaller_supply)), sum(values(supply)); atol = 1e-10)

        bad = readlines(audit)
        index = Dict(name => i for (i, name) in enumerate(split(bad[1], '\t')))
        pl_row = findfirst(line -> startswith(line, "PL\t"), bad)
        fields = split(bad[pl_row], '\t')
        fields[index["reference_disposal_service_tonnes"]] = "1.0"
        bad[pl_row] = join(fields, '\t')
        write(audit, join(bad, '\n') * "\n")
        @test validator.treatment_allocation_check(audit; source_file = fixture)[3] == "FAIL"
    end
end
