"""RunSpec assembly for the intended six-region CE-RISE CGE model."""

struct MultiRegionModelSpec
    label::String
    outline::MultiRegionOutline
    calibration::MultiRegionCalibration
    scenario::PolicyScenario
    coefficient_template::DataFrame
    quantity_template::DataFrame
end

function multi_region_model(; label::AbstractString = "eu-2016-six-region",
    bundle::CalibrationBundle = default_calibration_bundle(),
    calibration::MultiRegionCalibration = multi_region_calibration(bundle),
    scenario::PolicyScenario = baseline_scenario())
    return MultiRegionModelSpec(
        String(label),
        multi_region_outline(; bundle = bundle),
        calibration,
        scenario,
        copy(bundle.physical_coefficients),
        copy(bundle.physical_quantities),
    )
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
    0.0 < push_share < 1.0 ||
        error("solver.ipopt_bound_push_share must lie strictly between zero and one.")
    equation_scaling_floor > 0.0 ||
        error("solver.equation_scaling_floor must be strictly positive.")
    mu_init > 0.0 || error("solver.ipopt_mu_init must be strictly positive.")
    tolerance > 0.0 || error("solver.ipopt_tolerance must be strictly positive.")
    acceptable_tolerance > 0.0 ||
        error("solver.ipopt_acceptable_tolerance must be strictly positive.")
    starts = _initial_value_parameters(model.outline, model.calibration).start
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
    )
end

function run_spec(model::MultiRegionModelSpec = multi_region_model())
    blocks = multi_region_blocks(model.outline, model.calibration, model.scenario)
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
            vcat(blocks.production, Any[blocks.physical_quantity_links])),
        JCGECore.section(:factors, Any[blocks.factor_availability]),
        JCGECore.section(:government, Any[blocks.government_demand]),
        JCGECore.section(:savings, Any[blocks.private_saving, blocks.fixed_investment, blocks.investment_pool]),
        JCGECore.section(:households, Any[blocks.household_demand]),
        JCGECore.section(:prices, Any[blocks.price_index]),
        JCGECore.section(:external, Any[blocks.external_account]),
        JCGECore.section(:trade, Any[blocks.trade]),
        JCGECore.section(:markets, Any[blocks.market_clearing]),
        JCGECore.section(:objective, Any[blocks.utility]),
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

"""
    run_baseline(model=multi_region_model(); tol=1e-6)

Compile and solve the zero-policy six-region calibration replication. Equation
scales and Ipopt settings are read from the calibration bundle so that
small-account rounding differences do not destabilize the feasibility solve.
"""
function run_baseline(model::MultiRegionModelSpec = multi_region_model(); tol::Real=1.0e-6)
    model.scenario.name === :baseline ||
        error("run_baseline requires the zero-policy baseline scenario.")
    spec = run_spec(model)
    ctx = JCGERuntime.KernelContext(model=JuMP.Model())
    for block in spec.model.blocks
        JCGECore.build!(block, ctx, spec)
    end
    configuration = solver_configuration(model)
    scaling = JCGERuntime.calibrated_equation_scaling(
        ctx;
        floor=configuration.equation_scaling_floor,
    )
    JCGERuntime.compile_equations!(
        ctx;
        closure=spec.closure,
        compile_objective=false,
        equation_scaling=scaling,
    )
    JCGERuntime.solve!(ctx; optimizer=default_optimizer(model))
    JCGERuntime.evaluate_residuals!(ctx)
    summary = JCGERuntime.summarize_residuals(ctx; tol=tol)
    signals = JCGERuntime.to_dualsignals(ctx; dataset_id="ce-rise-cge-baseline", tol=tol)
    return (context=ctx, summary=summary, signals=signals)
end
