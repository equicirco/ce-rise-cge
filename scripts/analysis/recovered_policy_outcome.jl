module RecoveredPolicyOutcome

using DataFrames
using CERiseCGE

"""Write detailed outcomes for one accepted endpoint recovered by continuation."""
function write_outcome(path::AbstractString, target::CERiseCGE.SensitivityProfile,
    bundle, endpoint_model, endpoint_result; baseline_dir=nothing)
    CERiseCGE._valid_policy_solution(endpoint_result) ||
        error("Cannot write outcomes for an invalid recovered endpoint $(target.name).")
    saved = CERiseCGE._load_policy_baseline(target, endpoint_model, baseline_dir)
    baseline_dir !== nothing && saved === nothing && error("The saved reference for $(target.name) is incomplete.")
    if saved === nothing
    target_bundle = CERiseCGE.sensitivity_bundle(target; bundle=bundle)
    calibration = CERiseCGE.multi_region_calibration(target_bundle)
    baseline_model = CERiseCGE.multi_region_model(; bundle=target_bundle,
        calibration=calibration)
    baseline_result = CERiseCGE.run_baseline(baseline_model)
    CERiseCGE._valid_policy_solution(baseline_result) ||
        error("Baseline for recovered profile $(target.name) is not valid.")
    outcomes = CERiseCGE.policy_outcome_comparison(baseline_result, baseline_model,
        endpoint_result, endpoint_model)
    else
        policy = CERiseCGE.equilibrium_outcomes(endpoint_result, endpoint_model; physical_reference=saved.reference)
        outcomes = CERiseCGE._policy_outcome_tables(saved.outcomes, policy, endpoint_model)
    end
    outcomes.sensitivity_profile = fill(target.name, nrow(outcomes))
    mkpath(dirname(path))
    CERiseCGE._write_atomic_csv(path, outcomes)
    if baseline_dir !== nothing
        directory = joinpath(dirname(baseline_dir), "variables", "recovered")
        mkpath(directory)
        variables = joinpath(directory, basename(path))
        CERiseCGE._write_variable_values(variables,
            CERiseCGE.solution_start_values(endpoint_result))
        summary = joinpath(dirname(dirname(baseline_dir)), "recovered_endpoint_summaries", basename(path))
        files = [path, variables]
        isfile(summary) && push!(files, summary)
        CERiseCGE._checkpoint_manifest(variables * ".complete.csv", files)
    end
    return nothing
end

end
