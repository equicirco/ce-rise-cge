module RecoveredPolicyOutcome

using DataFrames
using CERiseCGE

"""Write detailed outcomes for one accepted endpoint recovered by continuation."""
function write_outcome(path::AbstractString, target::CERiseCGE.SensitivityProfile,
    bundle, endpoint_model, endpoint_result)
    CERiseCGE._valid_policy_solution(endpoint_result) ||
        error("Cannot write outcomes for an invalid recovered endpoint $(target.name).")
    target_bundle = CERiseCGE.sensitivity_bundle(target; bundle=bundle)
    calibration = CERiseCGE.multi_region_calibration(target_bundle)
    baseline_model = CERiseCGE.multi_region_model(; bundle=target_bundle,
        calibration=calibration)
    baseline_result = CERiseCGE.run_baseline(baseline_model)
    CERiseCGE._valid_policy_solution(baseline_result) ||
        error("Baseline for recovered profile $(target.name) is not valid.")
    outcomes = CERiseCGE.policy_outcome_comparison(baseline_result, baseline_model,
        endpoint_result, endpoint_model)
    outcomes.sensitivity_profile = fill(target.name, nrow(outcomes))
    mkpath(dirname(path))
    CERiseCGE._write_atomic_csv(path, outcomes)
    return nothing
end

end
