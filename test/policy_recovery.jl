using Test
using CSV
using DataFrames
using CERiseCGE

include(joinpath(@__DIR__, "..", "scripts", "analysis", "run_failed_policy_path_trace.jl"))
include(joinpath(@__DIR__, "..", "scripts", "analysis", "run_parameter_neighbor_continuation.jl"))
include(joinpath(@__DIR__, "..", "scripts", "analysis", "run_parameter_bisection_continuation.jl"))
include(joinpath(@__DIR__, "..", "scripts", "analysis", "materialize_recovered_policy_results.jl"))

@testset "Recovery routing for every declared policy point" begin
    recovery = FailedPolicyPathTrace.PolicyRecovery
    neighbor = ParameterNeighborContinuation
    bisection = ParameterBisectionContinuation
    materialize = MaterializeRecoveredPolicyResults
    bundle = default_calibration_bundle()
    profiles = sensitivity_profiles(bundle)
    target, source = profiles[1:2]
    wedges = policy_wedge_grid(bundle)
    grid = DataFrame([(sensitivity_profile=String(profile.name), instrument=String(row.instrument),
        wedge=row.wedge, solver_valid=profile.name === source.name, outcome=Float64(index))
        for profile in (target, source) for (index, row) in enumerate(eachrow(wedges))])
    key(row) = recovery.point_key(row)

    mktempdir() do dir
        grid_file = joinpath(dir, "grid.csv")
        CSV.write(grid_file, grid)
        tasks = FailedPolicyPathTrace.failed_path_tasks(grid_file, joinpath(dir, "paths"))
        @test length(tasks) == 5
        @test sum(length(task.wedges) for task in tasks) == 20
        for task in tasks
            declared = filter(row -> Symbol(row.instrument) === task.instrument, eachrow(wedges))
            @test Set(task.wedges) == Set(row.wedge for row in declared)
        end
        filenames = [recovery.point_file(dir, target.name, row.instrument, row.wedge)
            for row in eachrow(wedges)]
        @test length(unique(filenames)) == 20

        trace = DataFrame(
            sensitivity_profile=fill(String(target.name), 5),
            instrument=["virgin_metal_tax", "refurbishment_support", "repair_support", "repair_support", "reuse_support"],
            wedge=[0.0025, -0.005, -0.01, -0.0025, -0.02],
            declared_wedge=[0.0025, -0.005, -0.01, -0.02, -0.02],
            trial_wedge=[0.0025, -0.005, -0.01, -0.0025, -0.02],
            trial_accepted=[true, true, true, true, false],
            solver_valid=[true, true, true, true, false],
            continuation_phase=["direct_target", "continuation_trial", "predictor_target", "continuation_trial", "direct_target"],
        )
        predictor = joinpath(dir, "predictor.csv")
        CSV.write(predictor, trace)
        accepted = recovery.accepted_points(predictor)
        @test length(accepted) == 3
        @test recovery.point_key(target.name, :repair_support, -0.02) ∉ accepted
        @test recovery.point_key(target.name, :reuse_support, -0.02) ∉ accepted

        tasks = neighbor.continuation_tasks(grid_file, predictor, joinpath(dir, "neighbor");
            summary_dir=joinpath(dir, "summaries"))
        @test length(tasks) == 17
        @test all(task.target === target.name for task in tasks)
        @test length(unique(task.output_path for task in tasks)) == 17
        @test length(unique(task.summary_path for task in tasks)) == 17
        @test all(length(task.candidates) == 1 && only(task.candidates).profile === source.name
            for task in tasks)
        @test Set(recovery.point_key(task.target, task.instrument, task.wedge) for task in tasks) ==
            setdiff(Set(key(row) for row in eachrow(grid) if !row.solver_valid), accepted)

        # A missing adjacent source is retained as an unresolved point, rather
        # than aborting recovery for every other instrument and wedge.
        blocked = copy(grid)
        blocked.solver_valid[(blocked.instrument .== "recycling_support") .& (blocked.wedge .== -0.01)] .= false
        blocked_file = joinpath(dir, "blocked.csv")
        CSV.write(blocked_file, blocked)
        blocked_tasks = neighbor.continuation_tasks(blocked_file, predictor, joinpath(dir, "blocked"))
        no_sources = filter(task -> isempty(task.candidates), blocked_tasks)
        @test length(no_sources) == 2
        attempt = merge(first(no_sources), (outcome_path=nothing,))
        neighbor.run_task(attempt) # The empty candidate list invokes no model solve.
        failed = CSV.read(attempt.output_path, DataFrame)
        @test nrow(failed) == 1 && !only(failed.solver_valid)
        @test key(first(eachrow(failed))) == recovery.point_key(attempt.target, attempt.instrument, attempt.wedge)

        attempts = DataFrame([(sensitivity_profile=String(task.target), instrument=String(task.instrument),
            wedge=task.wedge, source_profile=String(source.name),
            changed_parameter=only(task.candidates).parameter,
            parameter_distance=only(task.candidates).distance, solver_valid=false,
            max_scaled_residual=0.1) for task in tasks])
        attempts_file = joinpath(dir, "neighbor.csv")
        CSV.write(attempts_file, attempts)
        bisect_tasks = bisection.choose_tasks(attempts_file, joinpath(dir, "bisection");
            summary_dir=joinpath(dir, "summaries"))
        @test length(bisect_tasks) == 17
        @test Set(recovery.point_key(task.target, task.instrument, task.wedge) for task in bisect_tasks) ==
            Set(key(row) for row in eachrow(attempts))
        @test length(unique(task.output_path for task in bisect_tasks)) == 17

        previous = DataFrame(
            sensitivity_profile=fill(String(target.name), 3),
            instrument=["repair_support", "repair_support", "virgin_metal_tax"],
            wedge=[-0.01, -0.005, 0.005], declared_wedge=[-0.01, -0.02, 0.005],
            trial_fraction=[1.0, 0.5, 1.0], trial_accepted=[true, true, false],
        )
        previous_file = joinpath(dir, "previous.csv")
        CSV.write(previous_file, previous)
        remaining = bisection.unresolved_endpoint_points(previous_file)
        @test remaining == Set((recovery.point_key(target.name, :repair_support, -0.02),
            recovery.point_key(target.name, :virgin_metal_tax, 0.005)))
        selected = bisection.choose_tasks(attempts_file, joinpath(dir, "fine"); remaining_from=previous_file)
        @test length(selected) == 2

        no_source_file = joinpath(dir, "no_source.csv")
        CSV.write(no_source_file, failed)
        no_source_bisection = only(bisection.choose_tasks(no_source_file, joinpath(dir, "no_source_bisection")))
        @test isempty(no_source_bisection.sources)
        bisection.trace_task(merge(no_source_bisection, (outcome_path=nothing,)))
        @test bisection.unresolved_endpoint_points(no_source_bisection.output_path) ==
            Set((recovery.point_key(attempt.target, attempt.instrument, attempt.wedge),))

        # Construct each declared endpoint and its diagonal midpoint without
        # invoking a solver. Support wedges must keep their negative sign.
        for row in eachrow(wedges)
            endpoint = recovery.policy_model(target, bundle, row.instrument, row.wedge)
            @test policy_wedge(endpoint.scenario, row.instrument) == row.wedge
            midpoint_profile = bisection.intermediate_profile(source, target,
                first(SENSITIVITY_PARAMETER_KEYS), 0.5)
            midpoint = recovery.policy_model(midpoint_profile, bundle, row.instrument, row.wedge / 2)
            @test policy_wedge(midpoint.scenario, row.instrument) == row.wedge / 2
        end
        throwing_runner(model; start_values) = error("simulated solver exception")
        endpoint = recovery.policy_model(target, bundle, :repair_support, -0.005)
        exception = FailedPolicyPathTrace._policy_attempt(target, endpoint, :direct_target,
            :repair_support, -0.005, 0.0, 1; start_values=Dict{Symbol,Float64}(), runner=throwing_runner)
        @test exception.result === nothing
        @test !exception.row.trial_accepted && !exception.row.solver_valid
        @test recovery.declared_key(exception.row) == recovery.point_key(target.name, :repair_support, -0.005)
        @test occursin("simulated solver exception", exception.row.solver_message)
        interrupted_runner(model; start_values) = throw(InterruptException())
        @test_throws InterruptException FailedPolicyPathTrace._policy_attempt(target, endpoint,
            :direct_target, :repair_support, -0.005, 0.0, 1;
            start_values=Dict{Symbol,Float64}(), runner=interrupted_runner)

        # Consolidation can recover several points in one profile. It must
        # preserve previously accepted values, even if an old summary exists.
        recovered = copy(grid[[1, 2, 5, 21], :])
        recovered.solver_valid .= true
        recovered.outcome .= -123.0
        recovered.recovery_stage = fill("predictor", nrow(recovered))
        final = materialize.merge_recovered_results(grid, recovered)
        @test nrow(final) == nrow(grid)
        @test Set(key(row) for row in eachrow(final)) == Set(key(row) for row in eachrow(grid))
        @test count(final.solver_valid) == 23
        for original in eachrow(grid)
            original.solver_valid || continue
            retained = only(filter(row -> key(row) == key(original), eachrow(final)))
            @test retained.outcome == original.outcome
            @test retained.recovery_stage == "declared_policy_path"
        end
        @test_throws ErrorException materialize.merge_recovered_results(grid, vcat(recovered, recovered[1:1, :]))
        invalid = copy(recovered)
        invalid.wedge[1] = 0.0075
        @test_throws ErrorException materialize.merge_recovered_results(grid, invalid)
        invalid = copy(recovered)
        invalid.solver_valid[1] = false
        @test_throws ErrorException materialize.merge_recovered_results(grid, invalid)

        summary_dir = joinpath(dir, "summaries")
        mkpath(summary_dir)
        for row in eachrow(recovered)
            CSV.write(recovery.point_file(summary_dir, key(row)...), DataFrame([NamedTuple(row)]))
        end
        @test nrow(materialize.read_recovered_summaries(summary_dir)) == 4
        requested = [recovery.declared_key(row) for row in eachrow(trace)]
        @test !recovery.checkpoint_complete(predictor, requested, summary_dir, nothing)
        for point in accepted
            path = recovery.point_file(summary_dir, point...)
            isfile(path) || CSV.write(path, DataFrame(sensitivity_profile=[String(point[1])],
                instrument=[String(point[2])], wedge=[point[3]], solver_valid=[true], recovery_stage=["predictor"]))
        end
        @test recovery.checkpoint_complete(predictor, requested, summary_dir, nothing)
        wrong_file = recovery.point_file(summary_dir, first(accepted)...)
        correct = CSV.read(wrong_file, DataFrame)
        wrong = copy(correct)
        wrong.wedge[1] /= 2
        CSV.write(wrong_file, wrong)
        @test !recovery.checkpoint_complete(predictor, requested, summary_dir, nothing)
        CSV.write(wrong_file, correct)

        # When all points already solve, all recovery CLIs must complete with
        # empty traces, no workers and unchanged policy outcomes.
        all_valid = copy(grid)
        all_valid.solver_valid .= true
        valid_file = joinpath(dir, "valid.csv")
        CSV.write(valid_file, all_valid)
        saved_args = copy(ARGS)
        try
            predictor_empty = joinpath(dir, "empty_predictor.csv")
            neighbor_empty = joinpath(dir, "empty_neighbor.csv")
            bisection_empty = joinpath(dir, "empty_bisection.csv")
            final_file = joinpath(dir, "final.csv")
            for (mod, args) in (
                (FailedPolicyPathTrace, ["--input", valid_file, "--output", predictor_empty, "--workers", "1"]),
                (neighbor, ["--grid", valid_file, "--predictor", predictor_empty, "--output", neighbor_empty, "--workers", "1"]),
                (bisection, ["--input", neighbor_empty, "--output", bisection_empty, "--workers", "1"]),
                (materialize, ["--grid", valid_file, "--summary-dir", joinpath(dir, "none"), "--output", final_file]),
            )
                empty!(ARGS)
                append!(ARGS, args)
                mod.main()
            end
            @test nrow(CSV.read(predictor_empty, DataFrame)) == 0
            @test nrow(CSV.read(neighbor_empty, DataFrame)) == 0
            @test nrow(CSV.read(bisection_empty, DataFrame)) == 0
            @test nrow(CSV.read(final_file, DataFrame)) == nrow(grid)
        finally
            empty!(ARGS)
            append!(ARGS, saved_args)
        end
    end
end
