#!/usr/bin/env julia

"""
Diagnose unresolved diagonal-continuation endpoints with a temporary
minimum-slack feasibility problem. This script does not alter the economic
model: it replaces each enforced equality only within the diagnostic JuMP
instance with two non-negative scaled residual slacks and minimizes their sum.
"""

module EndpointFeasibilityRestoration

using CSV
using DataFrames
using Distributed
using JCGECore
using JCGERuntime
using JuMP
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_INPUT_FILE = joinpath(ROOT_DIR, "results", "multi_region",
    "parameter_bisection_tax_diagonal.csv")
const DEFAULT_OUTPUT_FILE = joinpath(ROOT_DIR, "results", "multi_region",
    "endpoint_feasibility_restoration.csv")
const DEFAULT_WORKERS = 6
const TAX_WEDGE = 0.02

function command_options(args)
    input_file = DEFAULT_INPUT_FILE
    output_file = DEFAULT_OUTPUT_FILE
    workers = DEFAULT_WORKERS
    dry_run = false
    index = 1
    while index <= length(args)
        if args[index] == "--input" && index < length(args)
            input_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--output" && index < length(args)
            output_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--workers" && index < length(args)
            workers = parse(Int, args[index + 1])
            workers > 0 || error("--workers must be positive.")
            index += 2
        elseif args[index] == "--dry-run"
            dry_run = true
            index += 1
        else
            error("Usage: julia --project=. scripts/analysis/run_endpoint_feasibility_restoration.jl " *
                "[--input PATH] [--output PATH] [--workers N] [--dry-run]")
        end
    end
    return (input_file = input_file, output_file = output_file,
        workers = workers, dry_run = dry_run)
end

checkpoint_dir(output_file::AbstractString) = joinpath(dirname(output_file),
    "$(splitext(basename(output_file))[1])_checkpoints")

function endpoint_is_accepted(rows::AbstractDataFrame)
    return any(coalesce.(rows.trial_fraction .== 1.0, false) .&
        coalesce.(rows.trial_accepted, false))
end

function feasibility_tasks(input_file::AbstractString, directory::AbstractString)
    isfile(input_file) || error("Diagonal-continuation results are missing: $(input_file)")
    table = CSV.read(input_file, DataFrame)
    required = Set([:target_profile, :source_profile, :continued_parameter,
        :trial_fraction, :trial_accepted, :armington_elasticity,
        :cet_transformation_elasticity, :service_elasticity,
        :eol_allocation_elasticity, :eol_productivity_elasticity,
        :material_substitution_elasticity])
    required ⊆ Set(Symbol.(names(table))) || error("Input has no recognised continuation columns.")
    traced = table[.!ismissing.(table.target_profile), :]
    tasks = NamedTuple[]
    for rows in groupby(traced, :target_profile)
        endpoint_is_accepted(rows) && continue
        accepted = coalesce.(rows.trial_accepted, false) .& .!ismissing.(rows.trial_fraction)
        fractions = sort!(unique(Float64.(rows.trial_fraction[accepted])))
        filter!(fraction -> fraction < 1.0, fractions)
        first_row = rows[1, :]
        push!(tasks, (
            target = Symbol(first_row.target_profile),
            source = Symbol(first_row.source_profile),
            parameter = String(first_row.continued_parameter),
            accepted_fractions = fractions,
            output_path = joinpath(directory, "$(first_row.target_profile).csv"),
        ))
    end
    sort!(tasks; by = task -> String(task.target))
    return tasks
end

function parameter_key(label::AbstractString)
    pieces = split(label, ".")
    length(pieces) == 2 || error("Continuation parameter label $(label) is invalid.")
    return (String(pieces[1]), String(pieces[2]))
end

function intermediate_profile(source::CERiseCGE.SensitivityProfile,
    target::CERiseCGE.SensitivityProfile, key::Tuple{String,String}, fraction::Real)
    values = copy(source.values)
    values[key] = source.values[key] + fraction * (target.values[key] - source.values[key])
    return CERiseCGE.SensitivityProfile(
        Symbol("restoration_", target.name),
        "Temporary diagonal-continuation point for feasibility restoration.",
        values,
    )
end

function policy_model(profile::CERiseCGE.SensitivityProfile, bundle, wedge::Real)
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle = bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    scenario = CERiseCGE.eu_wide_policy_scenario(:virgin_metal_tax, wedge;
        bundle = profile_bundle)
    return CERiseCGE.multi_region_model(; bundle = profile_bundle,
        calibration = calibration, scenario = scenario)
end

function source_baseline(profile::CERiseCGE.SensitivityProfile, bundle)
    profile_bundle = CERiseCGE.sensitivity_bundle(profile; bundle = bundle)
    calibration = CERiseCGE.multi_region_calibration(profile_bundle)
    model = CERiseCGE.multi_region_model(; bundle = profile_bundle,
        calibration = calibration)
    return CERiseCGE.run_baseline(model)
end

function reconstruct_last_accepted(task, source, target, key, bundle)
    current = source_baseline(source, bundle)
    CERiseCGE._valid_policy_solution(current) ||
        error("The diagonal source baseline is not reproducibly valid.")
    current_fraction = 0.0
    for fraction in task.accepted_fractions
        fraction > current_fraction || continue
        profile = intermediate_profile(source, target, key, fraction)
        model = policy_model(profile, bundle, TAX_WEDGE * fraction)
        result = CERiseCGE.run_policy_scenario(model;
            start_values = CERiseCGE.solution_start_values(current))
        CERiseCGE._valid_policy_solution(result) ||
            error("Could not reconstruct accepted diagonal point $(fraction).")
        current = result
        current_fraction = fraction
    end
    return (result = current, fraction = current_fraction)
end

function install_feasibility_slacks!(ctx::JCGERuntime.KernelContext, scaling)
    slacks = NamedTuple[]
    for index in eachindex(ctx.equations)
        equation = ctx.equations[index]
        payload = equation.payload
        payload isa NamedTuple || continue
        expression = get(payload, :expr, nothing)
        constraint = get(payload, :constraint, nothing)
        expression isa JCGECore.EEq || continue
        constraint === nothing && continue
        JuMP.delete(ctx.model, constraint)
        indices = get(payload, :indices, ())
        index_names = get(payload, :index_names, nothing)
        environment = JCGERuntime._index_env(index_names, indices)
        parameters = get(payload, :params, nothing)
        lhs = JCGERuntime._compile_expr(expression.lhs, ctx, parameters, indices, environment)
        rhs = JCGERuntime._compile_expr(expression.rhs, ctx, parameters, indices, environment)
        scale = JCGERuntime._equation_scale(scaling, equation, payload)
        positive = JuMP.@variable(ctx.model, lower_bound = 0.0)
        negative = JuMP.@variable(ctx.model, lower_bound = 0.0)
        relaxed = JuMP.@constraint(ctx.model, (lhs - rhs) / scale == positive - negative)
        ctx.equations[index] = (
            tag = equation.tag,
            block = equation.block,
            payload = merge(payload, (constraint = relaxed,)),
        )
        push!(slacks, (
            block = equation.block,
            tag = equation.tag,
            indices = get(payload, :indices, ()),
            positive = positive,
            negative = negative,
        ))
    end
    isempty(slacks) && error("The feasibility model has no enforced equality constraints to relax.")
    JuMP.@objective(ctx.model, Min, sum(item.positive + item.negative for item in slacks))
    return slacks
end

function feasibility_restoration(model::CERiseCGE.MultiRegionModelSpec, starts)
    configuration = CERiseCGE.solver_configuration(model)
    spec = CERiseCGE.run_spec(model)
    ctx = JCGERuntime.KernelContext(model = JuMP.Model())
    for block in spec.model.blocks
        JCGECore.build!(block, ctx, spec)
    end
    scaling = JCGERuntime.calibrated_equation_scaling(ctx;
        floor = configuration.equation_scaling_floor)
    merge!(scaling, CERiseCGE._accounting_check_scales(model, spec))
    JCGERuntime.compile_equations!(ctx;
        closure = spec.closure,
        compile_objective = false,
        equation_scaling = scaling)
    CERiseCGE._apply_solution_start_values!(ctx, starts)
    slacks = install_feasibility_slacks!(ctx, scaling)
    JCGERuntime.solve!(ctx; optimizer = CERiseCGE.default_optimizer(model))
    has_values = JuMP.has_values(ctx.model)
    values = NamedTuple[]
    if has_values
        for item in slacks
            magnitude = JuMP.value(item.positive) + JuMP.value(item.negative)
            push!(values, (
                block = item.block,
                tag = item.tag,
                indices = join(string.(item.indices), "|"),
                scaled_slack = magnitude,
            ))
        end
    end
    sort!(values; by = item -> item.scaled_slack, rev = true)
    return (
        termination_status = JuMP.termination_status(ctx.model),
        primal_status = JuMP.primal_status(ctx.model),
        has_values = has_values,
        total_scaled_slack = has_values ? JuMP.objective_value(ctx.model) : missing,
        positive_slack_count = has_values ? count(item -> item.scaled_slack > 1.0e-8, values) : missing,
        largest_slacks = values[1:min(end, 5)],
    )
end

function result_row(task, target, reconstructed, diagnostic)
    largest = diagnostic.largest_slacks
    top = index -> index <= length(largest) ? largest[index] : nothing
    first_slack = top(1)
    return (
        sensitivity_profile = target.name,
        source_profile = task.source,
        continued_parameter = task.parameter,
        closest_accepted_fraction = reconstructed.fraction,
        restoration_termination_status = diagnostic.termination_status,
        restoration_primal_status = diagnostic.primal_status,
        restoration_has_values = diagnostic.has_values,
        minimum_total_scaled_slack = diagnostic.total_scaled_slack,
        positive_slack_equations = diagnostic.positive_slack_count,
        largest_slack_block = isnothing(first_slack) ? missing : first_slack.block,
        largest_slack_tag = isnothing(first_slack) ? missing : first_slack.tag,
        largest_slack_indices = isnothing(first_slack) ? missing : first_slack.indices,
        largest_scaled_slack = isnothing(first_slack) ? missing : first_slack.scaled_slack,
        top_five_scaled_slacks = join([
            "$(item.block).$(item.tag)[$(item.indices)]=$(item.scaled_slack)"
            for item in largest
        ], "; "),
        armington_elasticity = target.values[("trade", "armington_elasticity")],
        cet_transformation_elasticity = target.values[("trade", "cet_transformation_elasticity")],
        service_elasticity = target.values[("circular_routes", "service_elasticity")],
        eol_allocation_elasticity = target.values[("circular_routes", "eol_allocation_elasticity")],
        eol_productivity_elasticity = target.values[("circular_routes", "eol_productivity_elasticity")],
        material_substitution_elasticity = target.values[("circular_metal", "material_substitution_elasticity")],
    )
end

function failure_row(task, target, err)
    return merge((
        sensitivity_profile = target.name,
        source_profile = task.source,
        continued_parameter = task.parameter,
        closest_accepted_fraction = missing,
        restoration_termination_status = missing,
        restoration_primal_status = missing,
        restoration_has_values = false,
        minimum_total_scaled_slack = missing,
        positive_slack_equations = missing,
        largest_slack_block = missing,
        largest_slack_tag = missing,
        largest_slack_indices = missing,
        largest_scaled_slack = missing,
        top_five_scaled_slacks = sprint(showerror, err),
    ), (
        armington_elasticity = target.values[("trade", "armington_elasticity")],
        cet_transformation_elasticity = target.values[("trade", "cet_transformation_elasticity")],
        service_elasticity = target.values[("circular_routes", "service_elasticity")],
        eol_allocation_elasticity = target.values[("circular_routes", "eol_allocation_elasticity")],
        eol_productivity_elasticity = target.values[("circular_routes", "eol_productivity_elasticity")],
        material_substitution_elasticity = target.values[("circular_metal", "material_substitution_elasticity")],
    ))
end

function run_task(task)
    isfile(task.output_path) && return (target = task.target, state = :skipped)
    bundle = CERiseCGE.default_calibration_bundle()
    profiles = Dict(profile.name => profile for profile in CERiseCGE.sensitivity_profiles(bundle))
    target = profiles[task.target]
    source = profiles[task.source]
    try
        key = parameter_key(task.parameter)
        reconstructed = reconstruct_last_accepted(task, source, target, key, bundle)
        endpoint = policy_model(target, bundle, TAX_WEDGE)
        diagnostic = feasibility_restoration(endpoint,
            CERiseCGE.solution_start_values(reconstructed.result))
        row = result_row(task, target, reconstructed, diagnostic)
        CERiseCGE._write_atomic_csv(task.output_path, DataFrame([row]))
        return (target = task.target, state = :completed)
    catch err
        row = failure_row(task, target, err)
        CERiseCGE._write_atomic_csv(task.output_path, DataFrame([row]))
        return (target = task.target, state = :error)
    end
end

function start_workers(worker_count::Integer)
    worker_count == 1 && return nothing
    project_file = Base.active_project()
    project_file === nothing && error("The diagnostic must be launched with --project=.")
    workers = addprocs(worker_count;
        exeflags = "--project=$(dirname(project_file))",
        env = Dict("CE_RISE_FEASIBILITY_RESTORATION_WORKER" => "true"))
    script_path = abspath(@__FILE__)
    for worker in workers
        remotecall_wait(Base.include, worker, Main, script_path)
    end
    return workers
end

function main()
    options = command_options(ARGS)
    directory = checkpoint_dir(options.output_file)
    tasks = feasibility_tasks(options.input_file, directory)
    pending = filter(task -> !isfile(task.output_path), tasks)
    println("Unresolved endpoint cases: ", length(tasks))
    println("Completed checkpoints: ", length(tasks) - length(pending))
    println("Pending cases: ", length(pending))
    println("Workers: ", options.workers)
    flush(stdout)
    if options.dry_run
        println("Dry run completed; no diagnostics were written.")
        return nothing
    end
    mkpath(directory)
    start_workers(options.workers)
    isempty(pending) || (options.workers == 1 ? map(run_task, pending) : pmap(run_task, pending))
    tables = DataFrame[CSV.read(task.output_path, DataFrame) for task in tasks]
    CERiseCGE._write_atomic_csv(options.output_file, vcat(tables...; cols = :union))
    println("Wrote ", length(tables), " feasibility-restoration rows to ", options.output_file)
end

end

if (abspath(PROGRAM_FILE) == @__FILE__) &&
   get(ENV, "CE_RISE_FEASIBILITY_RESTORATION_WORKER", "false") != "true"
    EndpointFeasibilityRestoration.main()
end
