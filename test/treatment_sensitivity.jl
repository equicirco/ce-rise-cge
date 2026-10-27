using Test

module TreatmentSensitivityPreparation
include(joinpath(@__DIR__, "..", "scripts", "input", "prepare_treatment_sensitivity.jl"))
end

module TreatmentSensitivityStage
include(joinpath(@__DIR__, "..", "scripts", "input", "build_stage3_final_artifacts.jl"))
end

module TreatmentSensitivityValidation
include(joinpath(@__DIR__, "..", "scripts", "input", "validate_sut_totals.jl"))
end

@testset "Treatment-calibration sensitivity inputs" begin
    preparation = TreatmentSensitivityPreparation
    stage = TreatmentSensitivityStage
    treatment = stage.DiscardedEquipmentTreatment
    validator = TreatmentSensitivityValidation
    source = read(treatment.TREATMENT_FILE)
    configuration_source = read(preparation.CONFIGURATION_FILE)
    baseline = Dict(row.region => row for row in treatment.treatment_shares())

    mktempdir() do dir
        cases = preparation.prepare_treatment_sensitivity(dir)
        @test length(cases) == 5
        @test Set(case.name for case in cases) == Set(("reference", "disposal_seed_low",
            "disposal_seed_high", "disposal_cost_low", "disposal_cost_high"))
        profile = [split(line, '\t') for line in readlines(joinpath(dir, "behavioural_profile.tsv"))[2:end]]
        @test length(profile) == 7
        @test all(parse(Float64, row[3]) == 1.0 for row in profile)
        @test read(joinpath(dir, "policy_wedge_grid.tsv")) ==
            read(joinpath(preparation.MAPPING_DIR, "policy_wedge_grid.tsv"))

        fixture = joinpath(dir, "supply.tsv")
        open(fixture, "w") do io
            println(io, "product_region\tproduct_code\tactivity_region\tactivity_code\tvalue_meur")
            for region in keys(baseline), (family, value) in zip(("ELMA", "OFMA", "RATV"), (10.0, 20.0, 30.0))
                println(io, join((region, "CPA_E37-39_" * family, region, "E37-E39_" * family, value), '\t'))
            end
        end

        for case in cases
            @testset "$(case.name)" begin
                case_dir = joinpath(dir, case.name)
                config = treatment.treatment_configuration(joinpath(case_dir, "treatment_configuration.tsv"))
                @test config["zero_disposal_share"] == case.zero_disposal_share
                @test config["disposal_cost_ratio"] == case.disposal_cost_ratio
                path = joinpath(case_dir, "treatment_shares.tsv")
                shares, rows = stage.load_waste_route_shares(path; configuration=config)
                @test length(rows) == 7
                for row in rows
                    ref = baseline[row.region]
                    @test (row.recycling, row.disposal, row.observed_rec, row.observed_inc) ==
                        (ref.recycling, ref.disposal, ref.observed_rec, ref.observed_inc)
                    @test row.cost_ratio == case.disposal_cost_ratio
                    expected = row.seeded ? case.zero_disposal_share :
                        case.disposal_cost_ratio * row.disposal /
                        (row.recycling + case.disposal_cost_ratio * row.disposal)
                    @test row.calibrated_inc == expected
                    @test row.calibrated_rec + row.calibrated_inc == 1.0
                    if row.seeded
                        @test row.region == "PL" && row.disposal == 0.0
                    elseif case.changed_assumption == "zero_disposal_share"
                        @test row.calibrated_inc == ref.calibrated_inc
                    elseif case.disposal_cost_ratio < 1.0
                        @test row.calibrated_inc < ref.calibrated_inc
                    elseif case.disposal_cost_ratio > 1.0
                        @test row.calibrated_inc > ref.calibrated_inc
                    end
                end
                supply, _ = stage.aggregate_supply(shares, rows; infile=fixture)
                use, _ = stage.aggregate_use(shares, rows; infile=fixture)
                @test isapprox(sum(values(supply)), 420.0; atol=1.0e-10)
                @test isapprox(sum(values(use)), 420.0; atol=1.0e-10)
                for row in rows
                    recycling = sum(value for (key, value) in supply
                        if key[3] == row.region && key[4] == "REC_EE")
                    disposal = sum(value for (key, value) in supply
                        if key[3] == row.region && key[4] == "INC_EE")
                    @test isapprox(recycling + disposal, 60.0; atol=1.0e-10)
                    @test isapprox(disposal / 60.0, row.calibrated_inc; atol=1.0e-12)
                    @test !row.seeded || disposal > treatment.seed_output_floor(; configuration=config)
                end
                audit = joinpath(case_dir, "treatment_allocation.tsv")
                stage.write_treatment_allocation(audit, supply, rows;
                    source_file=fixture, configuration=config)
                @test validator.treatment_allocation_check(audit;
                    source_file=fixture, configuration=config)[3] == "PASS"
                audit_rows = [split(line, '\t') for line in readlines(audit)]
                index = Dict(name => i for (i, name) in enumerate(first(audit_rows)))
                for row in audit_rows[2:end]
                    seeded = parse(Bool, row[index["disposal_seeded"]])
                    @test seeded || parse(Float64, row[index["disposal_seed_meur"]]) == 0.0
                    @test !seeded || parse(Float64, row[index["disposal_cost_reallocation_meur"]]) == 0.0
                end
                if case.name != "reference"
                    @test_throws ErrorException stage.load_waste_route_shares(path)
                    @test validator.treatment_allocation_check(audit; source_file=fixture)[3] == "FAIL"
                end
            end
        end

        for ratio in (0.0, -1.0, Inf, NaN)
            @test_throws ErrorException treatment.treatment_shares(; disposal_cost_ratio=ratio)
        end
        bad = joinpath(dir, "invalid_design.tsv")
        write(bad, "case\tchanged_assumption\tzero_disposal_share\tdisposal_cost_ratio\n" *
            "reference\tnone\t0.0001\t1.0\n" *
            "two_changes\tzero_disposal_share\t0.00001\t0.5\n")
        @test_throws ErrorException preparation.treatment_sensitivity_cases(bad)
    end
    @test read(treatment.TREATMENT_FILE) == source
    @test read(preparation.CONFIGURATION_FILE) == configuration_source
end
