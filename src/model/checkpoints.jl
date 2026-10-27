"""Durable result files for resuming policy runs and rebuilding the outcome database."""

_file_digest(path) = open(io -> bytes2hex(SHA.sha256(io)), path)

function _checkpoint_manifest(path, files)
    mkpath(dirname(path))
    table = DataFrame(file=[relpath(file, dirname(path)) for file in files],
        sha256=[_file_digest(file) for file in files])
    _write_atomic_csv(path, table)
end

function _checkpoint_files_valid(path)
    isfile(path) || return false
    try
        table = CSV.read(path, DataFrame)
        nrow(table) > 0 || return false
        return all(isfile(joinpath(dirname(path), row.file)) &&
            _file_digest(joinpath(dirname(path), row.file)) == row.sha256 for row in eachrow(table))
    catch err
        err isa InterruptException && rethrow()
        return false
    end
end

function _policy_point_file(directory, profile, instrument, wedge)
    value = replace(string(Float64(wedge)), "-" => "minus_", "." => "_")
    return joinpath(directory, "$(profile)__$(instrument)__$(value).csv")
end

function _baseline_paths(directory, profile)
    base = joinpath(directory, String(profile))
    return (outcomes=base * ".csv", measures=base * ".metal.csv",
        variables=base * ".variables.csv", manifest=base * ".complete.csv")
end

function _write_variable_values(path, starts)
    names = sort!(collect(keys(starts)); by=String)
    _write_atomic_csv(path, DataFrame(variable=String.(names), value=[starts[name] for name in names]))
end

function _read_variable_values(path)
    table = CSV.read(path, DataFrame)
    nrow(table) > 0 && length(unique(table.variable)) == nrow(table) && all(isfinite, table.value) ||
        error("Incomplete saved variable values: $path")
    return Dict(Symbol(row.variable) => Float64(row.value) for row in eachrow(table))
end

function _capture_policy_baseline(profile, model, directory; tol=nothing)
    result = run_baseline(model; tol)
    _valid_policy_solution(result) || error("The zero-policy reference for $(profile.name) is not accepted.")
    reference = physical_flow_reference(result, model)
    outcomes = equilibrium_outcomes(result, model; physical_reference=reference)
    outcomes.sensitivity_profile = fill(profile.name, nrow(outcomes))
    measures = _metal_policy_measures(result, model)
    starts = solution_start_values(result)
    paths = _baseline_paths(directory, profile.name)
    mkpath(directory)
    _write_atomic_csv(paths.outcomes, outcomes)
    _write_atomic_csv(paths.measures, DataFrame([measures]))
    _write_variable_values(paths.variables, starts)
    _checkpoint_manifest(paths.manifest, [paths.outcomes, paths.measures, paths.variables])
    return (outcomes=outcomes, measures=measures, starts=starts, reference=reference)
end

function _load_policy_baseline(profile, model, directory)
    directory === nothing && return nothing
    paths = _baseline_paths(directory, profile.name)
    _checkpoint_files_valid(paths.manifest) || return nothing
    outcomes = CSV.read(paths.outcomes, DataFrame)
    all(String(value) == String(profile.name) for value in outcomes.sensitivity_profile) || return nothing
    nrow(outcomes) > 0 || return nothing
    _require_unique_outcome_keys(outcomes, "Saved baseline")
    starts = _read_variable_values(paths.variables)
    reference = SatelliteReference(:baseline,
        Dict(anchor.driver => starts[anchor.driver] for anchor in physical_flow_anchors(model)))
    measures_table = CSV.read(paths.measures, DataFrame)
    nrow(measures_table) == 1 || return nothing
    measures = (; (Symbol(name) => Float64(measures_table[1, name]) for name in names(measures_table))...)
    return (outcomes=outcomes, measures=measures, starts=starts, reference=reference)
end

function _policy_checkpoint_paths(checkpoint_dir, outcome_dir, profile, instrument, wedge)
    base = _policy_point_file(joinpath(checkpoint_dir, String(profile)), profile, instrument, wedge)
    return (summary=base, variables=base * ".variables.csv", manifest=base * ".complete.csv",
        outcomes=_policy_point_file(outcome_dir, profile, instrument, wedge))
end

function _save_policy_checkpoint(paths, checkpoint)
    mkpath(dirname(paths.summary))
    mkpath(dirname(paths.outcomes))
    _write_atomic_csv(paths.summary, checkpoint.summary)
    files = [paths.summary]
    if only(checkpoint.summary.solver_valid)
        _write_atomic_csv(paths.outcomes, checkpoint.outcomes)
        _write_variable_values(paths.variables, checkpoint.starts)
        append!(files, [paths.outcomes, paths.variables])
    else
        rm(paths.outcomes; force=true)
        rm(paths.variables; force=true)
    end
    _checkpoint_manifest(paths.manifest, files)
end

function _read_policy_checkpoint(paths, profile, model, baseline)
    _checkpoint_files_valid(paths.manifest) || return nothing
    summary = CSV.read(paths.summary, DataFrame)
    instrument = _active_policy_instrument(model)
    nrow(summary) == 1 && String(only(summary.sensitivity_profile)) == String(profile.name) &&
        String(only(summary.scenario)) == String(model.scenario.name) &&
        Symbol(only(summary.instrument)) === instrument && only(summary.wedge) == policy_wedge(model.scenario, instrument) ||
        return nothing
    if !only(summary.solver_valid)
        return (summary=summary, outcomes=DataFrame(), starts=Dict{Symbol,Float64}())
    end
    outcomes = CSV.read(paths.outcomes, DataFrame)
    outcome_keys = _require_unique_outcome_keys(outcomes, "Saved policy")
    reference = Dict(_outcome_key(row) => row.level for row in eachrow(baseline.outcomes))
    Set(outcome_keys) == Set(keys(reference)) || return nothing
    all(row.baseline_level == reference[_outcome_key(row)] &&
        String(row.sensitivity_profile) == String(profile.name) && Symbol(row.instrument) === instrument &&
        row.wedge == policy_wedge(model.scenario, instrument) && String(row.scenario) == String(model.scenario.name)
        for row in eachrow(outcomes)) || return nothing
    return (summary=summary, outcomes=outcomes, starts=_read_variable_values(paths.variables))
end

function _execute_checkpointed_policy(profile, model, baseline, starts, strength; tol=nothing, on_progress=nothing)
    record = only(_run_declared_policy_points([model]; tol, baseline_start_values=starts,
        initial_strength=strength, on_point=on_progress))
    if record.solver_valid
        summary = DataFrame([_policy_summary_row(baseline.measures, model, record.result)])
        summary.solver_valid = [true]
        summary.solver_message = [missing]
        summary.solver_elapsed_seconds = [record.solver_elapsed_seconds]
        summary.solver_attempts = [record.solver_attempts]
        policy = equilibrium_outcomes(record.result, model; physical_reference=baseline.reference)
        outcomes = _policy_outcome_tables(baseline.outcomes, policy, model)
        outcomes.sensitivity_profile = fill(profile.name, nrow(outcomes))
        saved_starts = solution_start_values(record.result)
    else
        summary = _sensitivity_rejected_policy_table(profile, [record])
        outcomes = DataFrame()
        saved_starts = Dict{Symbol,Float64}()
    end
    summary.sensitivity_profile = [profile.name]
    for (component, key) in SENSITIVITY_PARAMETER_KEYS
        summary[!, Symbol(key)] = [profile.values[(component, key)]]
    end
    return (summary=summary, outcomes=outcomes, starts=saved_starts)
end

function _profile_checkpoint_complete(profile, bundle, directory, outcome_dir, baseline_dir)
    path = joinpath(directory, "$(profile.name).csv")
    _checkpoint_files_valid(path * ".complete.csv") || return false
    model = multi_region_model(; bundle=sensitivity_bundle(profile; bundle))
    baseline = _load_policy_baseline(profile, model, baseline_dir)
    table = CSV.read(path, DataFrame)
    if baseline === nothing
        failed = joinpath(baseline_dir, "$(profile.name).failure.csv.complete.csv")
        _checkpoint_files_valid(failed) && all(.!coalesce.(table.solver_valid, false)) || return false
    end
    grid = policy_wedge_grid(bundle)
    nrow(table) == nrow(grid) || return false
    for row in eachrow(grid)
        scenario = eu_wide_policy_scenario(row.instrument, row.wedge; bundle=model.outline.bundle)
        paths = _policy_checkpoint_paths(directory, outcome_dir, profile.name, row.instrument, row.wedge)
        _checkpoint_files_valid(paths.manifest) || return false
        point = CSV.read(paths.summary, DataFrame)
        nrow(point) == 1 && String(only(point.sensitivity_profile)) == String(profile.name) &&
            Symbol(only(point.instrument)) === row.instrument && only(point.wedge) == row.wedge &&
            String(only(point.scenario)) == String(scenario.name) || return false
        subset = table[(String.(table.instrument) .== String(row.instrument)) .& (table.wedge .== row.wedge), :]
        nrow(subset) == 1 && only(subset.solver_valid) == only(point.solver_valid) || return false
    end
    return true
end
