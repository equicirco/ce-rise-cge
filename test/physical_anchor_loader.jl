using Test
using CSV
using DataFrames
using CERiseCGE

@testset "Physical observations in model construction" begin
    bundle = default_calibration_bundle()
    @test nrow(bundle.physical_flows) == 18
    @test all(bundle.physical_flows.route .== "NEW")
    @test isempty(CERiseCGE._observed_recycling_rows(bundle))
    model = multi_region_model(; bundle)
    @test length(physical_flow_anchors(model)) == 18
    @test nrow(bundle.route_registry) == 108
    structure = CERiseCGE._circular_metal_structure(model, model.circular_metal)
    @test isempty(structure.recovery_driver)
    @test isempty(structure.observed_recycled_inputs)
    @test length(circular_metal_blocks(model, model.circular_metal)) == 4
    coverage = circular_metal_coverage(model)
    @test coverage.complete == Bool[true, false, false, false, false, false]
    @test all(==(0), coverage.observed_rows[2:end])
    mktempdir() do dir
        path = joinpath(dir, "observations.tsv")
        CSV.write(path, bundle.physical_flows; delim = '\t')
        @test nrow(CERiseCGE._load_observed_physical_flows(path, bundle.sets)) == 18
        unsupported = copy(bundle.physical_flows)
        unsupported.route[1] = "REU"
        unsupported.flow_kind[1] = "route_input_mass"
        CSV.write(path, unsupported; delim = '\t')
        @test_throws ErrorException CERiseCGE._load_observed_physical_flows(path, bundle.sets)
        duplicate = vcat(bundle.physical_flows, bundle.physical_flows[1:1, :])
        CSV.write(path, duplicate; delim = '\t')
        @test_throws ErrorException CERiseCGE._load_observed_physical_flows(path, bundle.sets)
        CSV.write(path, bundle.physical_flows[2:end, :]; delim = '\t')
        @test_throws ErrorException CERiseCGE._load_observed_physical_flows(path, bundle.sets)
    end
end
