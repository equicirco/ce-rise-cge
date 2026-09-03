#!/usr/bin/env julia

"""Summarize unresolved endpoint cases from a parameter-continuation trace."""

using CSV
using DataFrames

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))

function command_options(args)
    input_file = nothing
    output_file = nothing
    index = 1
    while index <= length(args)
        if args[index] == "--input" && index < length(args)
            input_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        elseif args[index] == "--output" && index < length(args)
            output_file = normpath(joinpath(ROOT_DIR, args[index + 1]))
            index += 2
        else
            error("Usage: julia --project=. scripts/analysis/summarize_parameter_bisection_failures.jl " *
                "--input PATH --output PATH")
        end
    end
    isnothing(input_file) && error("--input is required.")
    isnothing(output_file) && error("--output is required.")
    return (input_file = input_file, output_file = output_file)
end

function endpoint_failure_class(row)
    status = ismissing(row.termination_status) ? "missing" : String(row.termination_status)
    if status == "TIME_LIMIT"
        return "time_limit"
    elseif status == "LOCALLY_INFEASIBLE"
        return "locally_infeasible"
    elseif ismissing(row.max_scaled_residual)
        return "no_endpoint_result"
    end
    return "residual_or_bound_rejection"
end

function latest_endpoint_row(table::AbstractDataFrame)
    candidates = table[.!ismissing.(table.trial_fraction) .& (table.trial_fraction .== 1.0), :]
    isempty(candidates) && return nothing
    attempts = coalesce.(candidates.attempt, -1)
    return candidates[argmax(attempts), :]
end

function summary_table(input_file::AbstractString)
    table = CSV.read(input_file, DataFrame)
    required = Set([:target_profile, :trial_fraction, :trial_accepted, :attempt,
        :termination_status, :primal_status, :max_scaled_residual,
        :scaled_residuals_above_tolerance, :max_bound_violation,
        :bound_violations_above_tolerance, :worst_equation_block,
        :worst_equation_tag, :worst_equation_indices,
        :worst_equation_scaled_residual, :solver_message,
        :armington_elasticity, :cet_transformation_elasticity,
        :service_elasticity, :eol_allocation_elasticity,
        :eol_productivity_elasticity, :material_substitution_elasticity])
    required ⊆ Set(Symbol.(names(table))) || error("Input has no recognised continuation columns.")
    traced = table[.!ismissing.(table.target_profile), :]
    rows = NamedTuple[]
    for profile_rows in groupby(traced, :target_profile)
        endpoint = latest_endpoint_row(profile_rows)
        endpoint === nothing && continue
        accepted_endpoint = any(coalesce.(profile_rows.trial_fraction .== 1.0, false) .&
            coalesce.(profile_rows.trial_accepted, false))
        accepted_endpoint && continue
        accepted = coalesce.(profile_rows.trial_accepted, false) .&
            .!ismissing.(profile_rows.trial_fraction)
        furthest_fraction = any(accepted) ? maximum(profile_rows.trial_fraction[accepted]) : missing
        first_row = profile_rows[1, :]
        push!(rows, (
            sensitivity_profile = String(first_row.target_profile),
            failure_class = endpoint_failure_class(endpoint),
            furthest_accepted_fraction = furthest_fraction,
            endpoint_attempt = endpoint.attempt,
            endpoint_termination_status = endpoint.termination_status,
            endpoint_primal_status = endpoint.primal_status,
            endpoint_max_scaled_residual = endpoint.max_scaled_residual,
            endpoint_residuals_above_tolerance = endpoint.scaled_residuals_above_tolerance,
            endpoint_max_bound_violation = endpoint.max_bound_violation,
            endpoint_bound_violations_above_tolerance = endpoint.bound_violations_above_tolerance,
            endpoint_worst_equation_block = endpoint.worst_equation_block,
            endpoint_worst_equation_tag = endpoint.worst_equation_tag,
            endpoint_worst_equation_indices = endpoint.worst_equation_indices,
            endpoint_worst_equation_scaled_residual = endpoint.worst_equation_scaled_residual,
            endpoint_solver_message = endpoint.solver_message,
            armington_elasticity = first_row.armington_elasticity,
            cet_transformation_elasticity = first_row.cet_transformation_elasticity,
            service_elasticity = first_row.service_elasticity,
            eol_allocation_elasticity = first_row.eol_allocation_elasticity,
            eol_productivity_elasticity = first_row.eol_productivity_elasticity,
            material_substitution_elasticity = first_row.material_substitution_elasticity,
        ))
    end
    return DataFrame(rows)
end

function main()
    options = command_options(ARGS)
    summary = summary_table(options.input_file)
    mkpath(dirname(options.output_file))
    CSV.write(options.output_file, summary)
    println("Wrote ", nrow(summary), " unresolved endpoint classifications to ", options.output_file)
end

main()
