using Test
using CERiseCGE
using DataFrames

@testset "Information and fiscal scenario specification" begin
    grid = information_parameter_grid()
    @test nrow(grid) == 12
    @test Set(grid.mechanism) == Set(INFORMATION_MECHANISMS)
    design = policy_experiment_design()
    @test nrow(design) == 56
    @test allunique(design.scenario_id)
    counts = Dict(kind => count(==(kind), design.scenario_kind) for kind in unique(design.scenario_kind))
    @test counts == Dict(:reference => 1, :fiscal => 20, :information_single => 12,
        :information_package => 3, :joint => 20)
    @test length(unique(design.regions)) == 1
    @test only(unique(design.regions)) == "DE;FR;IT;PL;SK;REU"
    @test only(unique(design.families)) == "ELMA;OFMA;RATV"
    @test (nrow(design) - 1) * length(sensitivity_profiles()) == 120285
    for row in eachrow(design)
        values = [row[mechanism] for mechanism in INFORMATION_MECHANISMS]
        if row.scenario_kind == :information_single
            @test count(!iszero, values) == 1
            @test row[row.information_mechanism] == row.information_strength
            @test ismissing(row.fiscal_instrument) && iszero(row.fiscal_wedge)
        elseif row.scenario_kind in (:information_package, :joint)
            @test all(==(row.information_strength), values)
            if row.scenario_kind == :joint
                @test row.information_strength == 0.10
                @test row.fiscal_instrument in CIRCULAR_POLICY_INSTRUMENTS
                @test abs(row.fiscal_wedge) in (0.0025, 0.005, 0.01, 0.02)
            end
        else
            @test all(iszero, values)
        end
    end
    comparisons = policy_experiment_comparisons(design)
    @test nrow(comparisons) == 270
    @test length(unique(comparisons.comparison_id)) == 115
    @test all(scenario -> scenario in design.scenario_id, comparisons.scenario_id)
    for group in groupby(comparisons, :comparison_id)
        @test sum(group.coefficient) == 0.0
        kind = only(unique(group.comparison_kind))
        @test nrow(group) == (kind == :interaction ? 4 : 2)
        # Synthetic additive effects have zero interaction. An extra reduction
        # under the combined intervention is recovered with its actual sign.
        if kind == :interaction
            scenario_kind(id) = only(filter(:scenario_id => ==(id), design).scenario_kind)
            level(id) = Dict(:reference => 100.0, :information_package => 90.0,
                :fiscal => 80.0, :joint => 70.0)[scenario_kind(id)]
            @test sum(row.coefficient * level(row.scenario_id) for row in eachrow(group)) == 0.0
            enhanced(id) = scenario_kind(id) == :joint ? 65.0 : level(id)
            @test sum(row.coefficient * enhanced(row.scenario_id) for row in eachrow(group)) == -5.0
        end
    end
    bad = copy(grid)
    bad.value[1] = 1.0
    @test_throws ErrorException policy_experiment_design(; information_grid=bad)
    bad = copy(grid)
    bad.value[1] = NaN
    @test_throws ErrorException policy_experiment_design(; information_grid=bad)
    bad = copy(grid)
    bad.sequence[1] = 2
    @test_throws ErrorException policy_experiment_design(; information_grid=bad)
    @test_throws ErrorException policy_experiment_design(; information_grid=grid[2:end, :])
end
