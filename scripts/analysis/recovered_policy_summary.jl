module RecoveredPolicySummary

using DataFrames
using CERiseCGE

"""Write the full target-policy summary at the continuation stage that solved it."""
function write_summary(path::AbstractString, target::CERiseCGE.SensitivityProfile,
    bundle, endpoint_model, endpoint_result, stage::Symbol)
    CERiseCGE._valid_policy_solution(endpoint_result) ||
        error("Cannot materialize an invalid recovered endpoint for $(target.name).")
    target_bundle = CERiseCGE.sensitivity_bundle(target; bundle = bundle)
    calibration = CERiseCGE.multi_region_calibration(target_bundle)
    baseline_model = CERiseCGE.multi_region_model(; bundle = target_bundle,
        calibration = calibration)
    baseline = CERiseCGE.run_baseline(baseline_model)
    CERiseCGE._valid_policy_solution(baseline) ||
        error("Baseline for recovered profile $(target.name) is not valid.")
    summary = CERiseCGE.policy_sweep_summary(baseline, baseline_model,
        [(model = endpoint_model, result = endpoint_result)])
    nrow(summary) == 1 || error("Recovered endpoint summary must have one row.")
    summary.sensitivity_profile = [target.name]
    for (component, key) in CERiseCGE.SENSITIVITY_PARAMETER_KEYS
        summary[!, Symbol(key)] = [target.values[(component, key)]]
    end
    summary.solver_valid = [true]
    summary.solver_message = [missing]
    summary.solver_elapsed_seconds = [missing]
    summary.profile_elapsed_seconds = [missing]
    summary.solver_attempts = [missing]
    summary.recovery_stage = [String(stage)]
    mkpath(dirname(path))
    CERiseCGE._write_atomic_csv(path, summary)
    return nothing
end

end
