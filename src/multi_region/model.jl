"""RunSpec assembly for the intended six-region CE-RISE CGE model."""

struct MultiRegionModelSpec
    label::String
    outline::MultiRegionOutline
    calibration::MultiRegionCalibration
    scenario::PolicyScenario
    coefficient_template::DataFrame
    quantity_template::DataFrame
    circular_routes::CircularRouteCalibration
    circular_metal::Union{Nothing,CircularMetalProfile}
end

function multi_region_model(; label::AbstractString = "eu-2016-six-region",
    bundle::CalibrationBundle = default_calibration_bundle(),
    calibration::MultiRegionCalibration = multi_region_calibration(bundle),
    scenario::PolicyScenario = baseline_scenario(),
    circular_metal::Union{Nothing,CircularMetalProfile} = nothing,
    include_circular_metal::Bool = true)
    outline = multi_region_outline(; bundle = bundle)
    routes = circular_route_calibration(outline, calibration)
    draft = MultiRegionModelSpec(
        String(label),
        outline,
        calibration,
        scenario,
        copy(bundle.physical_coefficients),
        copy(bundle.physical_quantities),
        routes,
        nothing,
    )
    include_circular_metal || circular_metal === nothing ||
        error("A circular-metal profile cannot be supplied when include_circular_metal is false.")
    profile = include_circular_metal ?
        (circular_metal === nothing ? circular_metal_baseline_profile(draft) : circular_metal) : nothing
    return MultiRegionModelSpec(
        String(label), outline, calibration, scenario,
        copy(bundle.physical_coefficients), copy(bundle.physical_quantities), routes, profile)
end

"""
    solver_configuration(model)

Return the Ipopt initialization settings derived from the model's calibrated
starting values and its `model_configuration.tsv` entries.
"""
function solver_configuration(model::MultiRegionModelSpec = multi_region_model())
    bundle = model.outline.bundle
    push_share = calibration_option_number(bundle, "solver", "ipopt_bound_push_share")
    equation_scaling_floor = calibration_option_number(bundle, "solver", "equation_scaling_floor")
    mu_init = calibration_option_number(bundle, "solver", "ipopt_mu_init")
    tolerance = calibration_option_number(bundle, "solver", "ipopt_tolerance")
    acceptable_tolerance = calibration_option_number(bundle, "solver", "ipopt_acceptable_tolerance")
    acceptable_dual_infeasibility_tolerance = calibration_option_number(bundle,
        "solver", "ipopt_acceptable_dual_infeasibility_tolerance")
    acceptable_constraint_violation_tolerance = calibration_option_number(bundle,
        "solver", "ipopt_acceptable_constraint_violation_tolerance")
    acceptable_complementarity_tolerance = calibration_option_number(bundle,
        "solver", "ipopt_acceptable_complementarity_tolerance")
    acceptable_iterations = calibration_option_number(bundle,
        "solver", "ipopt_acceptable_iterations")
    baseline_residual_tolerance = calibration_option_number(bundle, "diagnostics", "baseline_absolute_residual_tolerance")
    scaled_residual_tolerance = calibration_option_number(bundle,
        "diagnostics", "scaled_equation_residual_tolerance")
    bound_violation_tolerance = calibration_option_number(bundle,
        "diagnostics", "bound_violation_tolerance")
    0.0 < push_share < 1.0 ||
        error("solver.ipopt_bound_push_share must lie strictly between zero and one.")
    equation_scaling_floor > 0.0 ||
        error("solver.equation_scaling_floor must be strictly positive.")
    mu_init > 0.0 || error("solver.ipopt_mu_init must be strictly positive.")
    tolerance > 0.0 || error("solver.ipopt_tolerance must be strictly positive.")
    acceptable_tolerance > 0.0 ||
        error("solver.ipopt_acceptable_tolerance must be strictly positive.")
    acceptable_dual_infeasibility_tolerance > 0.0 || error(
        "solver.ipopt_acceptable_dual_infeasibility_tolerance must be strictly positive.")
    acceptable_constraint_violation_tolerance > 0.0 || error(
        "solver.ipopt_acceptable_constraint_violation_tolerance must be strictly positive.")
    acceptable_complementarity_tolerance > 0.0 || error(
        "solver.ipopt_acceptable_complementarity_tolerance must be strictly positive.")
    acceptable_iterations >= 1.0 && isinteger(acceptable_iterations) || error(
        "solver.ipopt_acceptable_iterations must be a positive integer.")
    baseline_residual_tolerance > 0.0 ||
        error("diagnostics.baseline_absolute_residual_tolerance must be strictly positive.")
    scaled_residual_tolerance > 0.0 || error(
        "diagnostics.scaled_equation_residual_tolerance must be strictly positive.")
    bound_violation_tolerance > 0.0 || error(
        "diagnostics.bound_violation_tolerance must be strictly positive.")
    starts = _initial_value_parameters(model.outline, model.calibration,
        model.circular_routes, model.scenario, model.circular_metal).start
    positive = [value for value in values(starts) if value > 0.0]
    isempty(positive) && error("The calibrated model has no positive starting value for solver initialization.")
    return (
        ipopt_bound_push = minimum(positive) * push_share,
        ipopt_bound_push_share = push_share,
        equation_scaling_floor = equation_scaling_floor,
        ipopt_hessian_approximation = calibration_option(bundle, "solver", "ipopt_hessian_approximation"),
        ipopt_bound_mult_init_method = calibration_option(bundle, "solver", "ipopt_bound_mult_init_method"),
        ipopt_mu_init = mu_init,
        ipopt_tolerance = tolerance,
        ipopt_acceptable_tolerance = acceptable_tolerance,
        ipopt_acceptable_dual_infeasibility_tolerance = acceptable_dual_infeasibility_tolerance,
        ipopt_acceptable_constraint_violation_tolerance = acceptable_constraint_violation_tolerance,
        ipopt_acceptable_complementarity_tolerance = acceptable_complementarity_tolerance,
        ipopt_acceptable_iterations = Int(acceptable_iterations),
        baseline_residual_tolerance = baseline_residual_tolerance,
        scaled_residual_tolerance = scaled_residual_tolerance,
        bound_violation_tolerance = bound_violation_tolerance,
    )
end

function default_optimizer(model::MultiRegionModelSpec = multi_region_model())
    configuration = solver_configuration(model)
    return JuMP.optimizer_with_attributes(
        Ipopt.Optimizer,
        "print_level" => 0,
        "sb" => "yes",
        "bound_push" => configuration.ipopt_bound_push,
        "hessian_approximation" => configuration.ipopt_hessian_approximation,
        "bound_mult_init_method" => configuration.ipopt_bound_mult_init_method,
        "mu_init" => configuration.ipopt_mu_init,
        "tol" => configuration.ipopt_tolerance,
        "acceptable_tol" => configuration.ipopt_acceptable_tolerance,
        "acceptable_dual_inf_tol" => configuration.ipopt_acceptable_dual_infeasibility_tolerance,
        "acceptable_constr_viol_tol" => configuration.ipopt_acceptable_constraint_violation_tolerance,
        "acceptable_compl_inf_tol" => configuration.ipopt_acceptable_complementarity_tolerance,
        "acceptable_iter" => configuration.ipopt_acceptable_iterations,
    )
end

function run_spec(model::MultiRegionModelSpec = multi_region_model())
    blocks = multi_region_blocks(model.outline, model.calibration, model.scenario;
        circular_routes = model.circular_routes,
        circular_metal = model.circular_metal)
    targets = closure_accounting_targets(model.outline.bundle)
    length(model.outline.investment_pools) == 1 && only(model.outline.investment_pools) == targets.investment_pool ||
        error("The calibration-defined accounting investment pool must be the model's sole investment pool.")
    closure = JCGECore.ClosureSpec(
        model.outline.closure.numeraire;
        kind = model.outline.closure.kind,
        condition_roles = Dict(
            JCGEBlocks.closure_condition(
                blocks.investment_pool,
                :investment_pool_clearing,
            ) => :accounting_check,
            JCGEBlocks.closure_condition(
                blocks.market_clearing,
                :regional_composite_market,
                targets.market_good,
                targets.market_region,
            ) => :accounting_check,
        ),
    )
    sections = [
        JCGECore.section(:production,
            vcat(Any[blocks.circular_routes.eol_allocation], blocks.production,
                Any[blocks.physical_quantity_links], blocks.circular_metal_physical)),
        JCGECore.section(:factors, Any[blocks.factor_availability]),
        JCGECore.section(:government,
            blocks.circular_policy === nothing ?
            Any[blocks.government_demand] :
            Any[blocks.government_demand, blocks.circular_policy.fiscal]),
        JCGECore.section(:savings, Any[blocks.private_saving, blocks.fixed_investment, blocks.investment_pool]),
        JCGECore.section(:households,
            Any[blocks.household_demand, blocks.circular_routes.service_demand]),
        JCGECore.section(:prices, Any[blocks.circular_routes.price_index]),
        JCGECore.section(:external, Any[blocks.external_account]),
        JCGECore.section(:trade, Any[blocks.trade]),
        JCGECore.section(:markets, vcat(Any[blocks.market_clearing], blocks.circular_metal_market)),
        JCGECore.section(:objective, Any[blocks.circular_routes.utility]),
        JCGECore.section(:init, Any[blocks.initial_values]),
        JCGECore.section(:closure, Any[blocks.numeraire]),
    ]
    scenario = JCGECore.ScenarioSpec(model.scenario.name, copy(model.scenario.shocks))
    return JCGECore.build_spec(
        "$(model.label):$(model.scenario.name)",
        model.outline.sets,
        model.outline.mappings,
        sections;
        closure = closure,
        scenario = scenario,
        required_sections = JCGECore.allowed_sections(),
        allowed_sections = JCGECore.allowed_sections(),
        required_nonempty = [:production, :factors, :households, :markets, :closure],
    )
end

baseline(model::MultiRegionModelSpec = multi_region_model()) = run_spec(model)

"""Return economically scaled reference magnitudes for post-solution accounting checks."""
function _accounting_check_scales(model::MultiRegionModelSpec,
    spec::JCGECore.RunSpec)
    calibration = model.calibration
    scales = Dict{Tuple{Symbol,Symbol,Tuple},Float64}()
    for condition in JCGECore.accounting_checks(spec.closure)
        key = (condition.block, condition.tag, condition.indices)
        if condition.block === :regional_investment_pool &&
           condition.tag === :investment_pool_clearing
            scales[key] = sum(calibration.investment_spending[region]
                for region in model.outline.regions)
        elseif condition.block === :regional_composite_market &&
               condition.tag === :regional_composite_market &&
               length(condition.indices) == 2
            good = first(condition.indices)
            scales[key] = calibration.marketed_output[good]
        end
    end
    all(value > 0.0 for value in values(scales)) ||
        error("Accounting-check scales must be strictly positive.")
    return scales
end

function _scaled_residual_summary(ctx::JCGERuntime.KernelContext,
    scaling::AbstractDict; tol::Real)
    tol > 0.0 || error("Scaled residual tolerance must be strictly positive.")
    rows = NamedTuple[]
    for equation in ctx.equations
        payload = equation.payload
        payload isa NamedTuple || continue
        haskey(payload, :residual) || continue
        indices = get(payload, :indices, ())
        values = indices isa Tuple ? indices :
            (indices isa AbstractVector ? Tuple(indices) : ())
        key = (equation.block, equation.tag, Tuple(Symbol(value) for value in values))
        scale = Float64(get(scaling, key, 1.0))
        scale > 0.0 || error("Equation scale must be strictly positive.")
        residual = Float64(payload.residual)
        push!(rows, (
            tag = equation.tag,
            block = equation.block,
            indices = values,
            residual = residual,
            scale = scale,
            scaled_residual = abs(residual) / scale,
        ))
    end
    isempty(rows) && return (count=0, max_scaled_abs=0.0, worst=nothing, above_tol=0)
    worst = argmax(row -> row.scaled_residual, rows)
    return (
        count = length(rows),
        max_scaled_abs = worst.scaled_residual,
        worst = worst,
        above_tol = count(row -> row.scaled_residual > tol, rows),
    )
end

"""Summarize post-solution variable-bound violations independently of solver status."""
function _bound_violation_summary(ctx::JCGERuntime.KernelContext; tol::Real)
    tol > 0.0 || error("Bound-violation tolerance must be strictly positive.")
    rows = NamedTuple[]
    for name in sort!(collect(keys(ctx.variables)))
        variable = ctx.variables[name]
        variable isa JuMP.VariableRef || continue
        value = JuMP.value(variable)
        lower_violation = JuMP.has_lower_bound(variable) ?
            max(0.0, JuMP.lower_bound(variable) - value) : 0.0
        upper_violation = JuMP.has_upper_bound(variable) ?
            max(0.0, value - JuMP.upper_bound(variable)) : 0.0
        violation = max(lower_violation, upper_violation)
        push!(rows, (
            variable = name,
            value = value,
            lower_violation = lower_violation,
            upper_violation = upper_violation,
            violation = violation,
        ))
    end
    isempty(rows) && return (count=0, max_abs=0.0, worst=nothing, above_tol=0)
    worst = argmax(row -> row.violation, rows)
    return (
        count = length(rows),
        max_abs = worst.violation,
        worst = worst,
        above_tol = count(row -> row.violation > tol, rows),
    )
end

"""Return finite variable values from a solved run for a compatible warm start."""
function solution_start_values(result)
    starts = Dict{Symbol,Float64}()
    for (name, variable) in result.context.variables
        variable isa JuMP.VariableRef || continue
        value = JuMP.value(variable)
        isfinite(value) || error("Cannot use a non-finite solution value as a warm start: $(name).")
        starts[name] = value
    end
    isempty(starts) && error("The solved run contains no variable values for a warm start.")
    return starts
end

"""Apply compatible solved values while retaining calibrated starts for newly introduced variables."""
function _apply_solution_start_values!(ctx::JCGERuntime.KernelContext,
    starts::AbstractDict{Symbol,<:Real})
    for (name, value) in starts
        haskey(ctx.variables, name) ||
            error("Warm-start variable $(name) is not present in the target model.")
        variable = ctx.variables[name]
        variable isa JuMP.VariableRef ||
            error("Warm-start target $(name) is not a JuMP variable.")
        start = Float64(value)
        isfinite(start) || error("Warm-start value for $(name) must be finite.")
        JuMP.set_start_value(variable, start)
    end
    return nothing
end

"""
    run_baseline(model=multi_region_model(); tol=nothing)

Compile and solve the zero-policy six-region calibration replication. Equation
scales, Ipopt settings, and the residual-reporting tolerance are read from the
calibration bundle so that small-account rounding differences do not
destabilize the feasibility solve.
"""
function _run_model(model::MultiRegionModelSpec;
    tol::Union{Nothing,Real}=nothing,
    start_values::Union{Nothing,AbstractDict{Symbol,<:Real}}=nothing)
    configuration = solver_configuration(model)
    scaled_reporting_tolerance = tol === nothing ?
        configuration.scaled_residual_tolerance : Float64(tol)
    scaled_reporting_tolerance > 0.0 || error("Scaled residual tolerance must be strictly positive.")
    spec = run_spec(model)
    ctx = JCGERuntime.KernelContext(model=JuMP.Model())
    for block in spec.model.blocks
        JCGECore.build!(block, ctx, spec)
    end
    scaling = JCGERuntime.calibrated_equation_scaling(
        ctx;
        floor=configuration.equation_scaling_floor,
    )
    merge!(scaling, _accounting_check_scales(model, spec))
    JCGERuntime.compile_equations!(
        ctx;
        closure=spec.closure,
        compile_objective=false,
        equation_scaling=scaling,
    )
    start_values === nothing || _apply_solution_start_values!(ctx, start_values)
    JCGERuntime.solve!(ctx; optimizer=default_optimizer(model))
    JCGERuntime.evaluate_residuals!(ctx)
    summary = JCGERuntime.summarize_residuals(ctx;
        tol=configuration.baseline_residual_tolerance)
    scaled_summary = _scaled_residual_summary(ctx, scaling; tol=scaled_reporting_tolerance)
    bound_summary = _bound_violation_summary(ctx;
        tol=configuration.bound_violation_tolerance)
    signals = JCGERuntime.to_dualsignals(ctx; dataset_id="ce-rise-cge-baseline",
        tol=configuration.baseline_residual_tolerance)
    return (context=ctx, summary=summary, scaled_summary=scaled_summary,
        bound_summary=bound_summary, signals=signals)
end

function run_baseline(model::MultiRegionModelSpec = multi_region_model();
    tol::Union{Nothing,Real}=nothing,
    start_values::Union{Nothing,AbstractDict{Symbol,<:Real}}=nothing)
    model.scenario.name === :baseline ||
        error("run_baseline requires the zero-policy baseline scenario.")
    return _run_model(model; tol=tol, start_values=start_values)
end

"""
    run_policy_scenario(model; tol=nothing, start_values=nothing)

Compile and solve one EU-wide, single-instrument circular-policy scenario.
`start_values` may be obtained from `solution_start_values` for a compatible
nearby scenario; variables absent from that starting point retain their
calibrated initial values.
"""
function run_policy_scenario(model::MultiRegionModelSpec;
    tol::Union{Nothing,Real}=nothing,
    start_values::Union{Nothing,AbstractDict{Symbol,<:Real}}=nothing)
    model.scenario.name !== :baseline ||
        error("run_policy_scenario requires a declared policy scenario.")
    return _run_model(model; tol=tol, start_values=start_values)
end

"""Return the one non-zero policy instrument declared by a policy scenario."""
function _active_policy_instrument(model::MultiRegionModelSpec)
    active = Symbol[
        instrument for instrument in CIRCULAR_POLICY_INSTRUMENTS
        if !iszero(policy_wedge(model.scenario, instrument))
    ]
    length(active) == 1 || error(
        "A continuation path requires exactly one non-zero policy instrument per scenario.")
    return only(active)
end

"""Validate a homogeneous policy path ordered from the weakest to the strongest wedge."""
function _validate_policy_path(models::AbstractVector{<:MultiRegionModelSpec})
    isempty(models) && error("A policy continuation path cannot be empty.")
    instrument = _active_policy_instrument(first(models))
    previous_strength = -Inf
    for model in models
        model.scenario.name !== :baseline ||
            error("A policy continuation path cannot include the baseline scenario.")
        _active_policy_instrument(model) === instrument || error(
            "A policy continuation path must contain one policy instrument only.")
        strength = abs(policy_wedge(model.scenario, instrument))
        strength > previous_strength || error(
            "Policy continuation wedges must be strictly ordered from weakest to strongest.")
        previous_strength = strength
    end
    return instrument
end

"""Return whether a solved policy point meets the model's numerical acceptance criteria."""
function _valid_policy_solution(result)
    status = JuMP.termination_status(result.context.model)
    status in (JuMP.MOI.OPTIMAL, JuMP.MOI.LOCALLY_SOLVED,
        JuMP.MOI.ALMOST_LOCALLY_SOLVED, JuMP.MOI.LOCALLY_INFEASIBLE) || return false
    return result.scaled_summary.above_tol == 0 && result.bound_summary.above_tol == 0
end

"""Return the policy wedges used internally to continue between reported points."""
function _policy_continuation_wedges(models::AbstractVector{<:MultiRegionModelSpec})
    instrument = _validate_policy_path(models)
    reported_wedges = Float64[policy_wedge(model.scenario, instrument) for model in models]
    strengths = abs.(reported_wedges)
    increment = minimum(diff(vcat(0.0, strengths)))
    increment > 0.0 || error("The policy continuation increment must be positive.")

    wedges = Float64[]
    previous_strength = 0.0
    for (target_wedge, target_strength) in zip(reported_wedges, strengths)
        sign_target = sign(target_wedge)
        next_strength = previous_strength + increment
        while next_strength < target_strength - eps(target_strength)
            push!(wedges, sign_target * next_strength)
            next_strength += increment
        end
        push!(wedges, target_wedge)
        previous_strength = target_strength
    end
    return wedges
end

"""Create one structurally identical model at an internal continuation wedge."""
function _policy_continuation_model(model::MultiRegionModelSpec,
    instrument::Symbol, wedge::Real)
    scenario = eu_wide_policy_scenario(instrument, wedge; bundle=model.outline.bundle)
    return multi_region_model(; label=model.label, bundle=model.outline.bundle,
        calibration=model.calibration, scenario=scenario,
        circular_metal=model.circular_metal)
end

"""
    run_policy_path(models; tol=nothing, start_values=nothing)

Solve a sequence of structurally compatible, single-instrument policy models
from the weakest to the strongest explicitly supplied wedge. Where the declared
ladder contains a larger jump, the smallest declared increment is used to solve
unreported intermediate points. Every solve is initialized from the preceding
accepted solution; only the explicitly supplied policy points are returned. The
function does not define policy rates, create results files, or combine instruments.
"""
function run_policy_path(models::AbstractVector{<:MultiRegionModelSpec};
    tol::Union{Nothing,Real}=nothing,
    start_values::Union{Nothing,AbstractDict{Symbol,<:Real}}=nothing)
    instrument = _validate_policy_path(models)
    continuation_wedges = _policy_continuation_wedges(models)
    runs = NamedTuple[]
    continuation_start = start_values
    target_models = Dict(
        policy_wedge(model.scenario, instrument) => model
        for model in models
    )
    for wedge in continuation_wedges
        model = get(target_models, wedge, nothing)
        model === nothing && (model = _policy_continuation_model(first(models), instrument, wedge))
        result = run_policy_scenario(model; tol=tol, start_values=continuation_start)
        _valid_policy_solution(result) || error(
            "Policy continuation failed at $(model.scenario.name): " *
            "status $(JuMP.termination_status(result.context.model)), " *
            "scaled residuals above tolerance $(result.scaled_summary.above_tol), " *
            "bound violations above tolerance $(result.bound_summary.above_tol).")
        haskey(target_models, wedge) && push!(runs, (model=model, result=result))
        continuation_start = solution_start_values(result)
    end
    return runs
end

"""Build the configured common wedge path for one policy instrument."""
function policy_sweep_models(instrument::Symbol;
    bundle::CalibrationBundle = default_calibration_bundle(),
    calibration::MultiRegionCalibration = multi_region_calibration(bundle),
    circular_metal::Union{Nothing,CircularMetalProfile} = nothing)
    scenarios = policy_sweep_scenarios(instrument; bundle=bundle)
    return MultiRegionModelSpec[
        multi_region_model(; bundle=bundle, calibration=calibration,
            scenario=scenario, circular_metal=circular_metal)
        for scenario in scenarios
    ]
end

"""
    run_configured_policy_sweep(instrument; bundle=default_calibration_bundle(), ...)

Solve the calibration-data wedge ladder for one policy instrument and return
the common baseline, ordered policy path, and comparable fiscal--physical
summary. Results remain in memory; persistence is intentionally left to the
subsequent analysis workflow.
"""
function run_configured_policy_sweep(instrument::Symbol;
    bundle::CalibrationBundle = default_calibration_bundle(),
    calibration::MultiRegionCalibration = multi_region_calibration(bundle),
    circular_metal::Union{Nothing,CircularMetalProfile} = nothing,
    tol::Union{Nothing,Real}=nothing)
    baseline_model = multi_region_model(; bundle=bundle, calibration=calibration,
        circular_metal=circular_metal)
    baseline_result = run_baseline(baseline_model; tol=tol)
    models = policy_sweep_models(instrument; bundle=bundle,
        calibration=calibration, circular_metal=circular_metal)
    policy_runs = run_policy_path(models; tol=tol,
        start_values=solution_start_values(baseline_result))
    summary = policy_sweep_summary(baseline_result, baseline_model, policy_runs)
    return (
        baseline_model = baseline_model,
        baseline_result = baseline_result,
        policy_runs = policy_runs,
        summary = summary,
    )
end

function _run_configured_sensitivity_profile(profile::SensitivityProfile,
    bundle::CalibrationBundle, requested_instruments::AbstractVector{Symbol};
    tol::Union{Nothing,Real} = nothing)
    profile_bundle = sensitivity_bundle(profile; bundle=bundle)
    calibration = multi_region_calibration(profile_bundle)
    baseline_model = multi_region_model(; bundle=profile_bundle, calibration=calibration)
    baseline_result = run_baseline(baseline_model; tol=tol)
    tables = DataFrame[]
    for instrument in requested_instruments
        policy_runs = try
            run_policy_path(policy_sweep_models(instrument;
                bundle=profile_bundle, calibration=calibration); tol=tol,
                start_values=solution_start_values(baseline_result))
        catch err
            error("Sensitivity profile $(profile.name) failed for $(instrument): " *
                sprint(showerror, err))
        end
        table = policy_sweep_summary(baseline_result, baseline_model, policy_runs)
        table.sensitivity_profile = fill(profile.name, nrow(table))
        for (component, key) in SENSITIVITY_PARAMETER_KEYS
            table[!, Symbol(key)] = fill(profile.values[(component, key)], nrow(table))
        end
        table.solver_valid = trues(nrow(table))
        table.solver_message = fill(missing, nrow(table))
        push!(tables, table)
    end
    return vcat(tables...; cols=:setequal)
end

"""Return declared grid rows for a sensitivity profile rejected by solver validity."""
function _sensitivity_failure_table(profile::SensitivityProfile,
    bundle::CalibrationBundle, requested_instruments::AbstractVector{Symbol}, err)
    message = sprint(showerror, err)
    rows = NamedTuple[]
    for instrument in requested_instruments
        for scenario in policy_sweep_scenarios(instrument; bundle=bundle)
            push!(rows, (
                scenario = scenario.name,
                instrument = instrument,
                wedge = policy_wedge(scenario, instrument),
                sensitivity_profile = profile.name,
                solver_valid = false,
                solver_message = message,
            ))
        end
    end
    table = DataFrame(rows)
    for (component, key) in SENSITIVITY_PARAMETER_KEYS
        table[!, Symbol(key)] = fill(profile.values[(component, key)], nrow(table))
    end
    return table
end

"""Combine valid and solver-rejected profile tables without discarding diagnostics."""
function _combine_policy_grid_tables(profile_tables::AbstractVector)
    isempty(profile_tables) && error("The policy sensitivity grid returned no profile tables.")
    return vcat(profile_tables...; cols=:union)
end

"""
    run_configured_policy_sensitivity_grid(; bundle=default_calibration_bundle(), ...)

Evaluate every configured single-instrument policy point at every Cartesian
combination of the declared behavioural sensitivity ladder. Each profile has
one common baseline, and all policy paths start from that profile's calibrated
zero-policy solution. Profiles are independent and can therefore use
JCGERuntime's process-based execution; wedges within one profile remain in
their ordered continuation path. Every declared grid point is retained in the
returned table: profiles that fail the numerical acceptance criteria are marked
`solver_valid = false` and carry the corresponding diagnostic message.
"""
function run_configured_policy_sensitivity_grid(;
    bundle::CalibrationBundle = default_calibration_bundle(),
    profiles::AbstractVector{<:SensitivityProfile} = sensitivity_profiles(bundle),
    instruments = CIRCULAR_POLICY_INSTRUMENTS,
    tol::Union{Nothing,Real} = nothing,
    execution::Symbol = :serial,
    workers = nothing)
    isempty(profiles) && error("The configured sensitivity grid cannot be empty.")
    requested_instruments = Symbol.(collect(instruments))
    all(instrument -> instrument in CIRCULAR_POLICY_INSTRUMENTS, requested_instruments) || error(
        "The sensitivity sweep contains an unknown circular-policy instrument.")
    isempty(requested_instruments) && error("The sensitivity sweep must contain at least one policy instrument.")
    profile_tables = RuntimeExperiments.run_grid(profiles;
        runner = profile -> _run_configured_sensitivity_profile(
            profile, bundle, requested_instruments; tol=tol),
        execution = execution,
        workers = workers,
        worker_modules = [:CERiseCGE],
        on_error = (profile, err) -> _sensitivity_failure_table(
            profile, bundle, requested_instruments, err),
    )
    return _combine_policy_grid_tables(profile_tables)
end
