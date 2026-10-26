using Test

module ManufacturingPreparationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "disaggregate_sut.jl"))
end

module ManufacturingClassificationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "build_stage3_final_artifacts.jl"))
end

module ManufacturingValidationChecks
include(joinpath(@__DIR__, "..", "scripts", "input", "validate_sut_totals.jl"))
end

@testset "Complete electronics-family allocation" begin
    preparation = ManufacturingPreparationChecks
    classification = ManufacturingClassificationChecks
    validator = ManufacturingValidationChecks
    entries = preparation.load_parent_map()
    outputs = preparation.load_parent_outputs(entries)
    mktempdir() do dir
        splits = preparation.build_split_sectors(entries, outputs; output_dir = dir)
        for ((region, group), items) in splits
            @test isapprox(sum(item.within_group_share for item in items), 1.0; atol = 1e-12)
            @test Set(item.label for item in items) == (group == "C27" ? Set(["ELMA"]) : Set(["OFMA", "RATV"]))
            for item in items
                @test item.kind == "family"
                @test item.within_parent_share == 1.0
                @test item.output_tonnes == outputs[(region, item.parent)]
                @test classification.explicit_product_targets(region, item.product_code, nothing, nothing) ==
                    [("NEW_" * item.label, 1.0)]
                @test classification.explicit_use_targets(region, item.activity_code, nothing, nothing) ==
                    [("NEW_" * item.label, 1.0)]
            end
        end
        share_path = joinpath(dir, basename(preparation.OUT_SHARES))
        @test validator.manufacturing_family_check(share_path)[3] == "PASS"

        # A share table can preserve FIGARO totals while still discarding part
        # of a family. The source-aware check must reject that allocation.
        damaged = readlines(share_path)
        fields = split(damaged[2], '\t')
        fields[8] = string(0.7 * parse(Float64, fields[8]))
        fields[11] = "0.7"
        damaged[2] = join(fields, '\t')
        damaged_path = joinpath(dir, "incomplete.tsv")
        write(damaged_path, join(damaged, '\n') * "\n")
        @test validator.manufacturing_family_check(damaged_path)[3] == "FAIL"

        product_groups, activity_groups = preparation.target_group_maps(entries)
        for (label, base, splitter) in (
            ("supply", preparation.SUPPLY_FILE, preparation.split_supply),
            ("use", preparation.USE_FILE, preparation.split_use),
        )
            candidate = joinpath(dir, label * ".tsv")
            splitter(entries, splits, product_groups, activity_groups; outfile = candidate)
            result = validator.validate_pair(label, "replace", base, candidate,
                joinpath(dir, basename(preparation.OUT_PARENT_CHILD_MAP)))
            @test result["status"] == "PASS"
            @test result["n_diff"] == 0
        end

        # Old product-level splits and unexplained family remainders must not
        # silently enter OTHER_MANUFACTURING when stale artifacts are read.
        for code in ("CPA_C27_PV", "CPA_C27_ELMA_res", "CPA_C26_OFMA_res", "CPA_C26_RATV_res")
            @test_throws ErrorException classification.explicit_product_targets("DE", code, nothing, nothing)
        end
        for code in ("C27_PV", "C27_ELMA_res", "C26_OFMA_res", "C26_RATV_res")
            @test_throws ErrorException classification.explicit_use_targets("DE", code, nothing, nothing)
        end
        @test classification.explicit_product_targets("DE", "CPA_C28", nothing, nothing) == [("OTHER_MANUFACTURING", 1.0)]
        @test classification.explicit_use_targets("DE", "C28", nothing, nothing) == [("OTHER_MANUFACTURING", 1.0)]
    end
end
