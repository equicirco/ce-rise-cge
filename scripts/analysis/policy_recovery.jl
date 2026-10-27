module PolicyRecovery

using CSV
using DataFrames
using CERiseCGE

export point_key, point_file, accepted_points, empty_trace, combine_checkpoints,
    policy_model, source_policy_solution, source_policy_start, source_baseline_start,
    declared_key, checkpoint_complete

const PointKey = Tuple{Symbol,Symbol,Float64}

point_key(profile, instrument, wedge) =
    (Symbol(profile), Symbol(instrument), Float64(wedge))
point_key(row) = point_key(row.sensitivity_profile, row.instrument, row.wedge)

function declared_key(row)
    wedge = hasproperty(row, :declared_wedge) && !ismissing(row.declared_wedge) ?
        row.declared_wedge : row.wedge
    return point_key(row.sensitivity_profile, row.instrument, wedge)
end

function point_file(directory, profile, instrument, wedge)
    return CERiseCGE._policy_point_file(directory, profile, instrument, wedge)
end

"""Accepted declared endpoints only; successful intermediate trials are excluded."""
function accepted_points(table::DataFrame)
    accepted = Set{PointKey}()
    for row in eachrow(table)
        ismissing(row.instrument) && continue
        valid = hasproperty(row, :trial_accepted) ? coalesce(row.trial_accepted, false) :
            coalesce(row.solver_valid, false)
        hasproperty(row, :solver_valid) && (valid &= coalesce(row.solver_valid, false))
        valid || continue
        if hasproperty(row, :trial_fraction) && !ismissing(row.trial_fraction)
            row.trial_fraction == 1.0 || continue
        end
        key = declared_key(row)
        trial = hasproperty(row, :trial_wedge) && !ismissing(row.trial_wedge) ?
            Float64(row.trial_wedge) : Float64(row.wedge)
        trial == key[3] || continue
        push!(accepted, key)
    end
    return accepted
end

accepted_points(path::AbstractString) = isfile(path) ?
    accepted_points(CSV.read(path, DataFrame)) : Set{PointKey}()

function empty_trace()
    return DataFrame(sensitivity_profile=String[], instrument=String[], wedge=Float64[],
        declared_wedge=Float64[], solver_valid=Bool[], max_scaled_residual=Float64[],
        source_profile=String[], changed_parameter=String[], parameter_distance=Float64[],
        target_profile=String[], trial_fraction=Float64[], trial_accepted=Bool[],
        continuation_phase=String[], attempt=Int[], trial_wedge=Float64[])
end

function combine_checkpoints(paths, output_file)
    tables = DataFrame[CSV.read(path, DataFrame) for path in paths]
    combined = isempty(tables) ? empty_trace() : vcat(tables...; cols=:union)
    mkpath(dirname(output_file))
    CERiseCGE._write_atomic_csv(output_file, combined)
    return combined
end

function endpoint_file_matches(path, key; summary::Bool)
    isfile(path) || return false
    try
        columns = summary ? [:sensitivity_profile, :instrument, :wedge, :solver_valid] :
            [:sensitivity_profile, :instrument, :wedge]
        table = CSV.read(path, DataFrame; select=columns)
        Set(columns) ⊆ Set(propertynames(table)) || return false
        nrow(table) > 0 && (!summary || nrow(table) == 1) || return false
        return all(point_key(row) == key && (!summary || coalesce(row.solver_valid, false))
            for row in eachrow(table))
    catch err
        err isa InterruptException && rethrow()
        return false
    end
end

"""A finished attempt needs output files only for endpoints actually accepted."""
function checkpoint_complete(path, requested, summary_dir, outcome_dir; baseline_dir=nothing)
    isfile(path) || return false
    table = CSV.read(path, DataFrame)
    nrow(table) > 0 || return false
    pairs = Set((key[1], key[2]) for key in requested)
    all(ismissing(row.instrument) ? any(pair -> pair[1] === Symbol(row.sensitivity_profile), pairs) :
        (Symbol(row.sensitivity_profile), Symbol(row.instrument)) in pairs for row in eachrow(table)) || return false
    recovered = intersect(accepted_points(table), Set(requested))
    if baseline_dir !== nothing
        all(key -> CERiseCGE._checkpoint_files_valid(point_file(
            joinpath(dirname(baseline_dir), "variables", "recovered"), key...) * ".complete.csv"), recovered) || return false
    end
    return all(key -> (summary_dir === nothing || endpoint_file_matches(
        point_file(summary_dir, key...), key; summary=true)) &&
        (outcome_dir === nothing || endpoint_file_matches(
        point_file(outcome_dir, key...), key; summary=false)), recovered)
end

function policy_model(profile, bundle, instrument, wedge)
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    scenario = CERiseCGE.eu_wide_policy_scenario(instrument, wedge; bundle=profile_bundle)
    return CERiseCGE.multi_region_model(; bundle=profile_bundle, calibration, scenario)
end

"""Reproduce a source solution at the same instrument and signed wedge as its target."""
function source_policy_solution(profile, bundle, instrument, wedge)
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    baseline_model = CERiseCGE.multi_region_model(; bundle=profile_bundle, calibration)
    baseline = CERiseCGE.run_baseline(baseline_model)
    CERiseCGE._valid_policy_solution(baseline) || return (baseline=baseline, policy=nothing)
    models = filter(model -> abs(CERiseCGE.policy_wedge(model.scenario, instrument)) <= abs(wedge),
        CERiseCGE.policy_sweep_models(instrument; bundle=profile_bundle, calibration))
    records = CERiseCGE._run_declared_policy_points(models;
        baseline_start_values=CERiseCGE.solution_start_values(baseline))
    endpoint = only(filter(record -> CERiseCGE.policy_wedge(record.model.scenario, instrument) == wedge,
        records))
    return (baseline=baseline, policy=endpoint.solver_valid ? endpoint.result : nothing)
end

function source_baseline_start(profile, bundle; baseline_dir=nothing)
    model = CERiseCGE.multi_region_model(; bundle=CERiseCGE.sensitivity_bundle(profile; bundle))
    saved = CERiseCGE._load_policy_baseline(profile, model, baseline_dir)
    if baseline_dir !== nothing
        return (baseline_valid=saved !== nothing, policy_valid=saved !== nothing,
            starts=saved === nothing ? Dict{Symbol,Float64}() : saved.starts)
    end
    baseline_model = CERiseCGE.multi_region_model(; bundle=model.outline.bundle, calibration=model.calibration)
    result = CERiseCGE.run_baseline(baseline_model)
    valid = CERiseCGE._valid_policy_solution(result)
    return (baseline_valid=valid, policy_valid=valid,
        starts=valid ? CERiseCGE.solution_start_values(result) : Dict{Symbol,Float64}())
end

function source_policy_start(profile, bundle, instrument, wedge; baseline_dir=nothing)
    if baseline_dir === nothing
        run = source_policy_solution(profile, bundle, instrument, wedge)
        baseline_valid = CERiseCGE._valid_policy_solution(run.baseline)
        valid = run.policy !== nothing && CERiseCGE._valid_policy_solution(run.policy)
        return (baseline_valid=baseline_valid, policy_valid=valid,
            starts=valid ? CERiseCGE.solution_start_values(run.policy) : Dict{Symbol,Float64}())
    end
    baseline = source_baseline_start(profile, bundle; baseline_dir)
    baseline.baseline_valid || return baseline
    root = dirname(dirname(baseline_dir))
    checkpoint = CERiseCGE._policy_checkpoint_paths(joinpath(root, "policy_sensitivity_grid_checkpoints"),
        joinpath(root, "data", "outcomes", "direct"), profile.name, instrument, wedge)
    if CERiseCGE._checkpoint_files_valid(checkpoint.manifest) &&
        only(CSV.read(checkpoint.summary, DataFrame).solver_valid)
        return (baseline_valid=true, policy_valid=true,
            starts=CERiseCGE._read_variable_values(checkpoint.variables))
    end
    path = point_file(joinpath(dirname(baseline_dir), "variables", "recovered"), profile.name, instrument, wedge)
    valid = CERiseCGE._checkpoint_files_valid(path * ".complete.csv")
    return (baseline_valid=true, policy_valid=valid,
        starts=valid ? CERiseCGE._read_variable_values(path) : Dict{Symbol,Float64}())
end

end
