using Test

module PhysicalAnchorChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "build_stage9_physical_satellite.jl"))
end

module PhysicalAnchorValidationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "validate_sut_totals.jl"))
end

@testset "Verified physical-anchor coverage" begin
    builder = PhysicalAnchorChecks
    validator = PhysicalAnchorValidationChecks
    detail = builder.collected_flows(builder.read_region_map(builder.REGION_MAP_FILE))
    @test all(key[3] == "NEW" && key[4] == "new_product_output" for key in keys(detail))
    @test all(!occursin("GLAS", key[6]) && !occursin("GLAS", key[7]) for key in keys(detail))
    summary = builder.summary_rows(detail)
    @test length(summary) == 18
    registry = read(joinpath(@__DIR__, "..", "data", "mappings", "final_sector_registry.tsv"), String)
    @test !occursin("A_GLAS_reuse", registry)
    @test all(row[2] == "pass" for row in builder.validation_rows(summary))

    # Positive business purchases must not pass as observed device throughput.
    invalid = deepcopy(summary)
    push!(invalid, ["DE", "ELMA", "REU", "route_input_mass", "tonnes", "1.0", "1",
        "observed", "bottle reuse", "legacy route match"])
    @test any(row[2] == "fail" for row in builder.validation_rows(invalid))
    bad_detail = copy(detail)
    bad_detail[("DE", "ELMA", "REU", "route_input_mass", "DE", "M_ELMA", "A_GLAS_reuse", "tonnes")] = 1.0
    @test_throws ErrorException builder.summary_rows(bad_detail)
    wrong_mass = deepcopy(summary)
    wrong_mass[1][6] = string(parse(Float64, wrong_mass[1][6]) + 1.0)
    @test any(row[1] == "V2_source_output_match" && row[2] == "fail" for row in builder.validation_rows(wrong_mass))

    mktempdir() do dir
        builder.main(; outdir = dir)
        path = joinpath(dir, basename(builder.OUT_SUMMARY))
        @test length(readlines(path)) == 19
        @test validator.physical_anchor_check(path)[3] == "PASS"
        open(path, "a") do io
            println(io, join(invalid[end], '\t'))
        end
        @test validator.physical_anchor_check(path)[3] == "FAIL"
    end
end
