using Test

module BonsaiImportChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "import_bonsai_family_outputs.jl"))
end

module BonsaiPreparationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "prepare_sut.jl"))
end

module BonsaiSatelliteChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "build_stage9_physical_satellite.jl"))
end

@testset "BONSAI V2 family-output input" begin
    source = BonsaiImportChecks.BonsaiFamilyOutputs
    outputs = source.load_family_outputs()
    @test Set(keys(outputs)) == BonsaiImportChecks.supplied_output_keys()
    @test outputs[("DE", "ELMA")] == 1829735.60418535
    @test outputs[("DE", "OFMA")] == 639.392520745985
    @test outputs[("DE", "RATV")] == 17420072.3577093

    region_map = BonsaiSatelliteChecks.read_region_map(BonsaiSatelliteChecks.REGION_MAP_FILE)
    totals = source.aggregate_family_outputs(region_map; outputs)
    # Independently checked V2 workbook totals, in kilotonnes. REU follows the
    # source-country map, rather than the workbook's narrower Other-EU27 sum.
    expected_kt = Dict(
        "DE" => [1829.735604, 0.639393, 17420.072358],
        "FR" => [757.252259, 0.084175, 1767.230817],
        "IT" => [1342.380626, 1180.479886, 4122.516121],
        "PL" => [524.823686, 446.466140, 16768.611359],
        "SK" => [114.523470, 0.076828, 8243.654365],
        "REU" => [82262.726242, 1721.100084, 30490.035280],
    )
    for (region, values) in expected_kt, (family, expected) in zip(("ELMA", "OFMA", "RATV"), values)
        @test isapprox(totals[(region, family)] / 1000, expected; atol = 1e-6, rtol = 0)
    end
    other_eu27 = Set(["AT", "BE", "BG", "CY", "CZ", "DK", "EE", "ES", "FI", "GR", "HR",
                      "HU", "IE", "LT", "LU", "LV", "MT", "NL", "PT", "RO", "SE", "SI"])
    for (family, expected) in zip(("ELMA", "OFMA", "RATV"),
                                 (3101.179722, 1029.820646, 18165.860308))
        subtotal = sum(tonnes for ((country, f), tonnes) in outputs if country in other_eu27 && f == family)
        @test isapprox(subtotal / 1000, expected; atol = 1e-6, rtol = 0)
    end

    # Exercise the physical-reporting consumer without writing calibration
    # artifacts or invoking any model or solver.
    detail = BonsaiSatelliteChecks.collected_flows(region_map)
    for region in keys(expected_kt), family in ("ELMA", "OFMA", "RATV")
        mass = sum(value for (key, value) in detail if key[1:4] ==
            (region, family, "NEW", "new_product_output"))
        @test isapprox(mass, totals[(region, family)]; rtol = 1e-12)
    end

    mktempdir() do dir
        fixture = joinpath(dir, "supplied.csv")
        normalized = joinpath(dir, "normalized.tsv")
        units = joinpath(dir, "units.tsv")
        write(fixture,
            "from_node_location,from_node_name,to_node_location,to_node_name,unit,value\n" *
            "DE,A_ELMA,DE,C_ELMA,tonnes,1811287.3667117427\n" *
            "DE,M_ELMA,DE,A_REPAIR,tonnes,10.0\n" *
            "DE,A_ELMA_c,DE,C_ELMA_c,tonnes,11.0\n")
        BonsaiPreparationChecks.normalize_disaggregation_overlay(;
            infile = fixture, outfile = normalized, units_file = units,
        )
        rows = readlines(normalized)
        @test parse(Float64, split(rows[2], '\t')[6]) == outputs[("DE", "ELMA")]
        @test rows[3] == "DE\tM_ELMA\tDE\tA_REPAIR\ttonnes\t10.0"
        @test rows[4] == "DE\tA_ELMA_c\tDE\tC_ELMA_c\ttonnes\t11.0"

        invalid = joinpath(dir, "invalid.tsv")
        header = "source_country\tfamily\toutput_tonnes\n"
        write(invalid, header * "DE\tELMA\t1\nDE\tELMA\t2\n")
        @test_throws ErrorException source.load_family_outputs(invalid)
        write(invalid, header * "DE\tELMA\t-1\n")
        @test_throws ErrorException source.load_family_outputs(invalid)
        write(invalid, header * "DE\tELMA\tNaN\n")
        @test_throws ErrorException source.load_family_outputs(invalid)
    end
end
