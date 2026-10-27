using Test
using CSV
using DataFrames
using CERiseCGE

include(joinpath(@__DIR__, "..", "scripts", "analysis", "compile_policy_outcomes_database.jl"))
include(joinpath(@__DIR__, "..", "scripts", "analysis", "run_checkpoints.jl"))
include(joinpath(@__DIR__, "..", "scripts", "analysis", "policy_recovery.jl"))

@testset "Single-run outcome persistence and database reconstruction" begin
    bundle = default_calibration_bundle()
    profile = first(sensitivity_profiles(bundle))
    calls = Tuple{Symbol,Float64}[]
    baseline_calls = Ref(0)
    interrupt = Ref(true)

    # Synthetic reporting fixtures exercise file handling and resumption only.
    # The test never invokes an optimizer or generates scientific results.
    function capture(profile, model, directory; tol=nothing)
        baseline_calls[] += 1
        rows = [
            CERiseCGE._outcome_row(:economic, :activity_output_volume_index;
                region=:SK, account=:IND_SK_NEW_OFMA, unit=:index, level=1.0),
            CERiseCGE._outcome_row(:fiscal, :policy_household_transfer_million_eur;
                region=:SK, unit=:million_eur, level=0.0),
            CERiseCGE._outcome_row(:physical, :observed_new_product_output;
                region=:SK, family=:OFMA, route=:NEW, unit=:tonnes, level=100.0),
        ]
        outcomes = DataFrame(rows)
        outcomes.sensitivity_profile = fill(profile.name, nrow(outcomes))
        measures = (primary_metal_market_demand_tonnes=100.0,)
        starts = Dict(anchor.driver => 1.0 for anchor in physical_flow_anchors(model))
        paths = CERiseCGE._baseline_paths(directory, profile.name)
        mkpath(directory)
        CERiseCGE._write_atomic_csv(paths.outcomes, outcomes)
        CERiseCGE._write_atomic_csv(paths.measures, DataFrame([measures]))
        CERiseCGE._write_variable_values(paths.variables, starts)
        CERiseCGE._checkpoint_manifest(paths.manifest, [paths.outcomes, paths.measures, paths.variables])
        return CERiseCGE._load_policy_baseline(profile, model, directory)
    end

    function execute(profile, model, baseline, starts, strength; tol=nothing, on_progress=nothing)
        if interrupt[] && length(calls) == 7
            throw(InterruptException())
        end
        instrument = CERiseCGE._active_policy_instrument(model)
        wedge = policy_wedge(model.scenario, instrument)
        if instrument === :recycling_support && wedge == -0.02
            @test strength == 0.01
            @test all(isapprox(value, 1.01) for value in values(starts))
        end
        push!(calls, (instrument, wedge))
        accepted = !(instrument === :reuse_support && wedge == -0.02)
        summary = DataFrame(sensitivity_profile=[profile.name], scenario=[model.scenario.name],
            instrument=[instrument], wedge=[wedge], solver_valid=[accepted],
            solver_message=[accepted ? missing : "synthetic rejection"])
        if !accepted
            return (summary=summary, outcomes=DataFrame(), starts=Dict{Symbol,Float64}())
        end
        policy = copy(baseline.outcomes)
        policy.level .*= (1.0 - abs(wedge))
        outcomes = CERiseCGE._policy_outcome_tables(baseline.outcomes, policy, model)
        outcomes.sensitivity_profile = fill(profile.name, nrow(outcomes))
        return (summary=summary, outcomes=outcomes,
            starts=Dict(name => 1.0 + abs(wedge) for name in keys(starts)))
    end

    mktempdir() do dir
        checkpoints = joinpath(dir, "policy_sensitivity_grid_checkpoints")
        outcomes = joinpath(dir, "data", "outcomes", "direct")
        baselines = joinpath(dir, "data", "baselines")
        @test_throws InterruptException CERiseCGE._checkpointed_sensitivity_profile(profile,
            bundle, collect(CIRCULAR_POLICY_INSTRUMENTS), checkpoints;
            outcome_dir=outcomes, baseline_dir=baselines, execute_point=execute, capture_baseline=capture)
        @test length(calls) == 7 && baseline_calls[] == 1
        @test length(readdir(outcomes)) == 7
        interrupt[] = false
        result = CERiseCGE._checkpointed_sensitivity_profile(profile,
            bundle, collect(CIRCULAR_POLICY_INSTRUMENTS), checkpoints;
            outcome_dir=outcomes, baseline_dir=baselines, execute_point=execute, capture_baseline=capture)
        @test length(calls) == 20 && length(unique(calls)) == 20
        @test baseline_calls[] == 1
        saved = CERiseCGE._load_policy_baseline(profile, multi_region_model(; bundle), baselines)
        warm = PolicyRecovery.source_policy_start(profile, bundle, :repair_support, -0.01; baseline_dir=baselines)
        @test warm.baseline_valid && warm.policy_valid
        @test all(isapprox(value, 1.01) for value in values(warm.starts))
        @test PolicyRecovery.source_baseline_start(profile, bundle; baseline_dir=baselines).starts == saved.starts
        @test result.solver_valid_rows == 19 && result.solver_rejected_rows == 1
        @test length(readdir(outcomes)) == 19
        @test CERiseCGE._profile_checkpoint_complete(profile, bundle, checkpoints, outcomes, baselines)
        @test saved !== nothing && nrow(saved.outcomes) == 3
        @test length(saved.starts) == 18

        # A damaged outcome is repaired individually; other completed points
        # and the exact saved reference remain available.
        damaged = CERiseCGE._policy_point_file(outcomes, profile.name, :repair_support, -0.01)
        open(damaged, "a") do io
            println(io, "damaged")
        end
        @test !CERiseCGE._profile_checkpoint_complete(profile, bundle, checkpoints, outcomes, baselines)
        CERiseCGE._checkpointed_sensitivity_profile(profile, bundle,
            collect(CIRCULAR_POLICY_INSTRUMENTS), checkpoints;
            outcome_dir=outcomes, baseline_dir=baselines, execute_point=execute, capture_baseline=capture)
        @test length(calls) == 21 && last(calls) == (:repair_support, -0.01)
        @test baseline_calls[] == 1

        solutions = joinpath(dir, "policy_sensitivity_solutions.csv")
        cp(result.result_path, solutions)
        compiler = CompilePolicyOutcomes
        options = compiler.command_options(["--input", solutions])
        summary = compiler.compile_database(options)
        @test summary.policy_points == 20 && summary.outcome_rows == 57
        database = compiler.DuckDB.DB(options.database; readonly=true)
        connection = compiler.DBInterface.connect(database)
        try
            @test only(DataFrame(compiler.DBInterface.execute(connection,
                "SELECT count(*) AS n FROM policy_variables")).n) == 19 * 18
            @test only(DataFrame(compiler.DBInterface.execute(connection,
                "SELECT count(*) AS n FROM baseline_variables")).n) == 18
        finally
            compiler.DBInterface.close!(connection)
            close(database)
        end
        @test compiler.compile_database(options) == summary
        @test length(calls) == 21 && baseline_calls[] == 1
        rebuilt = merge(options, (database=joinpath(dir, "rebuilt.duckdb"),))
        @test compiler.compile_database(rebuilt) == summary

        # Missing, duplicate and inconsistent saved outcomes are errors in
        # compilation; none triggers a model run to hide the missing data.
        backup = read(damaged)
        rm(damaged)
        @test_throws ErrorException compiler.compile_database(merge(options,
            (database=joinpath(dir, "missing.duckdb"),)))
        write(damaged, backup)
        duplicate = joinpath(outcomes, "duplicate.csv")
        cp(damaged, duplicate)
        @test_throws ErrorException compiler.compile_database(merge(options,
            (database=joinpath(dir, "duplicate.duckdb"),)))
        rm(duplicate)
        invalid = CSV.read(damaged, DataFrame)
        invalid.baseline_level[1] += 1
        CSV.write(damaged, invalid)
        @test_throws ErrorException compiler.compile_database(merge(options,
            (database=joinpath(dir, "inconsistent.duckdb"),)))
        @test_throws ErrorException compiler.compile_database(options)
        write(damaged, backup)
        @test length(calls) == 21

        # Recovered endpoints also retain their raw values and reference data.
        # Missing values make their checkpoint incomplete, rather than being
        # silently omitted from a resumed database build.
        recovery_out = joinpath(dir, "data", "outcomes", "recovered")
        recovery_summaries = joinpath(dir, "recovered_endpoint_summaries")
        recovery_vars = joinpath(dir, "data", "variables", "recovered")
        for directory in (recovery_out, recovery_summaries, recovery_vars)
            mkpath(directory)
        end
        recovered_key = (profile.name, :reuse_support, -0.02)
        report = DataFrame(sensitivity_profile=[profile.name], instrument=[:reuse_support],
            wedge=[-0.02], solver_valid=[true], trial_accepted=[true], declared_wedge=[-0.02])
        trace = joinpath(dir, "recovered_trace.csv")
        CSV.write(trace, report)
        summary_path = PolicyRecovery.point_file(recovery_summaries, recovered_key...)
        outcome_path = PolicyRecovery.point_file(recovery_out, recovered_key...)
        variable_path = PolicyRecovery.point_file(recovery_vars, recovered_key...)
        CSV.write(summary_path, report)
        CSV.write(outcome_path, report)
        CERiseCGE._write_variable_values(variable_path, saved.starts)
        CERiseCGE._checkpoint_manifest(variable_path * ".complete.csv", [summary_path, outcome_path, variable_path])
        @test PolicyRecovery.checkpoint_complete(trace, [recovered_key], recovery_summaries,
            recovery_out; baseline_dir=baselines)
        @test PolicyRecovery.source_policy_start(profile, bundle, :reuse_support, -0.02;
            baseline_dir=baselines).policy_valid
        rm(variable_path)
        @test !PolicyRecovery.checkpoint_complete(trace, [recovered_key], recovery_summaries,
            recovery_out; baseline_dir=baselines)

        failure_profile = sensitivity_profiles(bundle)[2]
        rejected_baseline(profile, model, directory; tol=nothing) = error("synthetic baseline rejection")
        failed = CERiseCGE._checkpointed_sensitivity_profile(failure_profile, bundle,
            collect(CIRCULAR_POLICY_INSTRUMENTS), checkpoints; outcome_dir=outcomes,
            baseline_dir=baselines, execute_point=execute, capture_baseline=rejected_baseline)
        @test failed.solver_valid_rows == 0 && failed.solver_rejected_rows == 20
        @test CERiseCGE._profile_checkpoint_complete(failure_profile, bundle, checkpoints, outcomes, baselines)

        run_dir = joinpath(dir, "run")
        signature = DataFrame(file=["model", "calibration"], sha256=["a", "b"])
        RunCheckpoints.verify_run!(run_dir, signature)
        @test isfile(RunCheckpoints.verify_run!(run_dir, signature))
        changed = copy(signature)
        changed.sha256[2] = "different"
        @test_throws ErrorException RunCheckpoints.verify_run!(run_dir, changed)
        legacy = joinpath(dir, "legacy")
        mkpath(legacy)
        write(joinpath(legacy, "old.csv"), "old\n")
        @test_throws ErrorException RunCheckpoints.verify_run!(legacy, signature)
    end
end
