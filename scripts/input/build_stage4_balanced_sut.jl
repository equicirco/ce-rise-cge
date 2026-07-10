#!/usr/bin/env julia

"""
Build the stage-4 balanced SUT artifact set.

Stage 4 turns the explicit final-preparation SUT into a balanced target SUT
using quadratic minimization around the stage-3 tables.

Adopted rule:
- keep SAM-like non-commodity rows unchanged;
- preserve zero support by optimizing only over existing nonzero commodity cells;
- keep industry output columns anchored to the stage-3 supply table;
- keep final-demand columns anchored to the stage-3 use table;
- solve the cell-level balancing problem as the nearest table under exact
  commodity row balance and exact industry-column consistency.
"""

using LinearAlgebra
using SparseArrays

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const ARTIFACT3_DIR = joinpath(ROOT_DIR, "data", "artifacts", "03_final_preparation")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "04_balanced_sut")

const IN_SUPPLY = joinpath(ARTIFACT3_DIR, "final_supply_explicit.tsv")
const IN_USE = joinpath(ARTIFACT3_DIR, "final_use_explicit.tsv")
const IN_SECTOR_REGISTRY = joinpath(ARTIFACT3_DIR, "explicit_final_sector_registry.tsv")

const OUT_SUPPLY = joinpath(OUTDIR, "balanced_supply.tsv")
const OUT_USE = joinpath(OUTDIR, "balanced_use.tsv")
const OUT_SUPPLY_DIAG = joinpath(OUTDIR, "supply_cell_diagnostics.tsv")
const OUT_USE_DIAG = joinpath(OUTDIR, "use_cell_diagnostics.tsv")
const OUT_ROW_SUMMARY = joinpath(OUTDIR, "commodity_row_summary.tsv")
const OUT_SUPPLY_COL_SUMMARY = joinpath(OUTDIR, "supply_column_summary.tsv")
const OUT_USE_COL_SUMMARY = joinpath(OUTDIR, "use_column_summary.tsv")
const OUT_CONFIG = joinpath(OUTDIR, "balancing_configuration.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "balancing_validation.tsv")

const SPECIAL_PRODUCT_ROWS = Set(["B2A3G", "D1", "D21X31", "D29X39", "OP_NRES", "OP_RES"])

const TARGET_FLOOR = 1.0e-9
const NEGATIVE_TOL = 1.0e-9
const BALANCE_TOL = 1.0e-7
const MAX_ACTIVE_SET_ITERS = 25

struct FlowEntry
    product_region::String
    product_sector::String
    column_region::String
    column_code::String
    value::Float64
end

struct SolveResult
    supply_values::Vector{Float64}
    use_values::Vector{Float64}
    iterations::Int
    objective_value::Float64
    max_constraint_residual::Float64
end

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
end

function read_tsv(path::AbstractString)
    rows = Vector{Vector{String}}()
    open(path, "r") do io
        for line in eachline(io)
            isempty(line) && continue
            push!(rows, split(line, '\t'))
        end
    end
    return rows
end

function write_tsv(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(header, '\t'))
        for row in rows
            println(io, join(row, '\t'))
        end
    end
end

function load_sector_ids(path::AbstractString)
    rows = read_tsv(path)
    return Set(row[1] for row in rows[2:end])
end

row_key(entry::FlowEntry) = (entry.product_region, entry.product_sector)
col_key(entry::FlowEntry) = (entry.column_region, entry.column_code)
is_commodity(entry::FlowEntry) = !(entry.product_sector in SPECIAL_PRODUCT_ROWS)

function parse_flow_entries(path::AbstractString)
    rows = read_tsv(path)
    return [
        FlowEntry(row[1], row[2], row[3], row[4], parse(Float64, row[5]))
        for row in rows[2:end]
    ]
end

function partition_entries(entries::Vector{FlowEntry})
    commodity = FlowEntry[]
    fixed = FlowEntry[]
    for entry in entries
        if is_commodity(entry)
            push!(commodity, entry)
        else
            push!(fixed, entry)
        end
    end
    return commodity, fixed
end

function accumulate_totals(entries::Vector{FlowEntry}; by::Symbol)
    totals = Dict{Tuple{String,String},Float64}()
    for entry in entries
        key = by === :row ? row_key(entry) : col_key(entry)
        totals[key] = get(totals, key, 0.0) + entry.value
    end
    return totals
end

function sorted_keys(dict::Dict{Tuple{String,String},Float64})
    return sort!(collect(keys(dict)))
end

function split_use_column_totals(
    use_entries::Vector{FlowEntry},
    sector_ids::Set{String},
)
    activity_totals = Dict{Tuple{String,String},Float64}()
    final_demand_totals = Dict{Tuple{String,String},Float64}()
    for entry in use_entries
        key = col_key(entry)
        if entry.column_code in sector_ids
            activity_totals[key] = get(activity_totals, key, 0.0) + entry.value
        else
            final_demand_totals[key] = get(final_demand_totals, key, 0.0) + entry.value
        end
    end
    return activity_totals, final_demand_totals
end

function fixed_activity_value_added(
    fixed_use_entries::Vector{FlowEntry},
    sector_ids::Set{String},
)
    totals = Dict{Tuple{String,String},Float64}()
    for entry in fixed_use_entries
        if entry.column_code in sector_ids
            key = col_key(entry)
            totals[key] = get(totals, key, 0.0) + entry.value
        end
    end
    return totals
end

function reconcile_final_demand_targets(
    final_demand_targets::Dict{Tuple{String,String},Float64},
    activity_value_added_targets::Dict{Tuple{String,String},Float64},
)
    final_demand_total = sum(values(final_demand_targets))
    value_added_total = sum(values(activity_value_added_targets))
    gap = final_demand_total - value_added_total
    weights = Dict(key => max(value, TARGET_FLOOR) for (key, value) in final_demand_targets)
    λ = isempty(weights) ? 0.0 : gap / sum(values(weights))
    adjusted = Dict{Tuple{String,String},Float64}()
    for (key, value) in final_demand_targets
        adjusted[key] = value - λ * weights[key]
    end
    return adjusted, gap, λ
end

function build_constraint_system(
    supply_entries::Vector{FlowEntry},
    use_entries::Vector{FlowEntry},
    free_supply::Vector{Int},
    free_use::Vector{Int},
    supply_targets::Dict{Tuple{String,String},Float64},
    final_demand_targets::Dict{Tuple{String,String},Float64},
    activity_value_added_targets::Dict{Tuple{String,String},Float64},
)
    supply_cols = sort!(collect(keys(supply_targets)))
    final_demand_cols = sort!(collect(keys(final_demand_targets)))
    activity_cols = sort!(collect(keys(activity_value_added_targets)))

    all_rows = Set{Tuple{String,String}}()
    for idx in free_supply
        push!(all_rows, row_key(supply_entries[idx]))
    end
    for idx in free_use
        push!(all_rows, row_key(use_entries[idx]))
    end
    commodity_rows = sort!(collect(all_rows))

    m_supply = length(supply_cols)
    m_final = length(final_demand_cols)
    m_rows = length(commodity_rows)
    m_activity = length(activity_cols)
    n_supply = length(free_supply)
    n_use = length(free_use)
    n = n_supply + n_use
    m = m_supply + m_final + m_rows + m_activity

    supply_col_pos = Dict{Tuple{String,String},Int}()
    for pair in enumerate(supply_cols)
        i = pair[1]
        key = pair[2]
        supply_col_pos[key] = i
    end
    final_demand_col_pos = Dict{Tuple{String,String},Int}()
    for pair in enumerate(final_demand_cols)
        i = pair[1]
        key = pair[2]
        final_demand_col_pos[key] = i
    end
    activity_col_pos = Dict{Tuple{String,String},Int}()
    for pair in enumerate(activity_cols)
        i = pair[1]
        key = pair[2]
        activity_col_pos[key] = i
    end
    row_pos = Dict{Tuple{String,String},Int}()
    for pair in enumerate(commodity_rows)
        i = pair[1]
        key = pair[2]
        row_pos[key] = i
    end

    rowinds = Int[]
    colinds = Int[]
    vals = Float64[]
    b = zeros(Float64, m)
    a = zeros(Float64, n)
    weights = ones(Float64, n)

    supply_local_to_global = Dict{Int,Int}()
    use_local_to_global = Dict{Int,Int}()

    for pair in enumerate(supply_cols)
        j = pair[1]
        key = pair[2]
        b[j] = supply_targets[key]
    end
    for pair in enumerate(final_demand_cols)
        j = pair[1]
        key = pair[2]
        b[m_supply + j] = final_demand_targets[key]
    end
    for pair in enumerate(activity_cols)
        j = pair[1]
        key = pair[2]
        b[m_supply + m_final + m_rows + j] = activity_value_added_targets[key]
    end

    for pair in enumerate(free_supply)
        local_idx = pair[1]
        global_idx = pair[2]
        entry = supply_entries[global_idx]
        a[local_idx] = entry.value
        supply_local_to_global[local_idx] = global_idx

        push!(rowinds, supply_col_pos[col_key(entry)])
        push!(colinds, local_idx)
        push!(vals, 1.0)

        push!(rowinds, m_supply + m_final + row_pos[row_key(entry)])
        push!(colinds, local_idx)
        push!(vals, 1.0)

        push!(rowinds, m_supply + m_final + m_rows + activity_col_pos[col_key(entry)])
        push!(colinds, local_idx)
        push!(vals, 1.0)
    end

    for pair in enumerate(free_use)
        local0_idx = pair[1]
        global_idx = pair[2]
        local_idx = n_supply + local0_idx
        entry = use_entries[global_idx]
        a[local_idx] = entry.value
        use_local_to_global[local0_idx] = global_idx

        if haskey(final_demand_col_pos, col_key(entry))
            push!(rowinds, m_supply + final_demand_col_pos[col_key(entry)])
            push!(colinds, local_idx)
            push!(vals, 1.0)
        else
            push!(rowinds, m_supply + m_final + m_rows + activity_col_pos[col_key(entry)])
            push!(colinds, local_idx)
            push!(vals, -1.0)
        end

        push!(rowinds, m_supply + m_final + row_pos[row_key(entry)])
        push!(colinds, local_idx)
        push!(vals, -1.0)
    end

    A = sparse(rowinds, colinds, vals, m, n)

    for i in 1:m
        if count(!iszero, A[i, :]) == 0 && abs(b[i]) > BALANCE_TOL
            error("Constraint $(i) has no supporting cells but nonzero target $(b[i])")
        end
    end

    return (
        A = A,
        b = b,
        a = a,
        weights = weights,
        supply_cols = supply_cols,
        final_demand_cols = final_demand_cols,
        activity_cols = activity_cols,
        commodity_rows = commodity_rows,
        supply_local_to_global = supply_local_to_global,
        use_local_to_global = use_local_to_global,
        n_supply = n_supply,
    )
end

function solve_equality_qp(A::SparseMatrixCSC{Float64,Int}, b::Vector{Float64}, a::Vector{Float64}, weights::Vector{Float64})
    inv_weights = 1.0 ./ weights
    Dinv = spdiagm(0 => inv_weights)
    M = Matrix(A * Dinv * transpose(A))
    rhs = Vector(A * a - b)
    λ = pinv(M) * rhs
    adjustment = inv_weights .* Vector(transpose(A) * λ)
    z = a - adjustment
    residual = Vector(A * z - b)
    max_residual = maximum(abs.(residual))
    objective_value = 0.5 * sum(weights .* (z .- a) .^ 2)
    return z, objective_value, max_residual
end

function lower_bound(entry::FlowEntry, side::Symbol)
    if side === :supply
        return 0.0
    end
    return entry.value >= 0.0 ? 0.0 : -Inf
end

function upper_bound(entry::FlowEntry, side::Symbol)
    if side === :supply
        return Inf
    end
    return entry.value >= 0.0 ? Inf : 0.0
end

function solve_with_active_set(
    supply_entries::Vector{FlowEntry},
    use_entries::Vector{FlowEntry},
    supply_targets::Dict{Tuple{String,String},Float64},
    final_demand_targets::Dict{Tuple{String,String},Float64},
    activity_value_added_targets::Dict{Tuple{String,String},Float64},
)
    active_supply = trues(length(supply_entries))
    active_use = trues(length(use_entries))

    final_supply = zeros(Float64, length(supply_entries))
    final_use = zeros(Float64, length(use_entries))
    final_objective = 0.0
    final_residual = 0.0

    for iteration in 1:MAX_ACTIVE_SET_ITERS
        free_supply = findall(active_supply)
        free_use = findall(active_use)
        system = build_constraint_system(
            supply_entries,
            use_entries,
            free_supply,
            free_use,
            supply_targets,
            final_demand_targets,
            activity_value_added_targets,
        )

        z, objective_value, max_residual = solve_equality_qp(system.A, system.b, system.a, system.weights)

        fill!(final_supply, 0.0)
        fill!(final_use, 0.0)
        for local_idx in 1:system.n_supply
            final_supply[system.supply_local_to_global[local_idx]] = z[local_idx]
        end
        for local0_idx in 1:length(free_use)
            final_use[system.use_local_to_global[local0_idx]] = z[system.n_supply + local0_idx]
        end

        violating_supply = [
            i for i in free_supply
            if final_supply[i] < lower_bound(supply_entries[i], :supply) - NEGATIVE_TOL ||
               final_supply[i] > upper_bound(supply_entries[i], :supply) + NEGATIVE_TOL
        ]
        violating_use = [
            i for i in free_use
            if final_use[i] < lower_bound(use_entries[i], :use) - NEGATIVE_TOL ||
               final_use[i] > upper_bound(use_entries[i], :use) + NEGATIVE_TOL
        ]

        if isempty(violating_supply) && isempty(violating_use)
            for i in eachindex(final_supply)
                if isfinite(lower_bound(supply_entries[i], :supply))
                    final_supply[i] = max(final_supply[i], lower_bound(supply_entries[i], :supply))
                end
            end
            for i in eachindex(final_use)
                lb = lower_bound(use_entries[i], :use)
                ub = upper_bound(use_entries[i], :use)
                isfinite(lb) && (final_use[i] = max(final_use[i], lb))
                isfinite(ub) && (final_use[i] = min(final_use[i], ub))
            end
            final_objective = objective_value
            final_residual = max_residual
            return SolveResult(final_supply, final_use, iteration, final_objective, final_residual)
        end

        for idx in violating_supply
            active_supply[idx] = false
        end
        for idx in violating_use
            active_use[idx] = false
        end
    end

    error("Active-set balancing did not converge within $(MAX_ACTIVE_SET_ITERS) iterations")
end

function write_balanced_table(
    path::AbstractString,
    entries::Vector{FlowEntry},
    values::Vector{Float64},
    third_col::String,
    fourth_col::String,
    allow_negative::Bool,
)
    rows = Vector{Vector{String}}()
    for pair in zip(entries, values)
        entry = pair[1]
        value = pair[2]
        !allow_negative && value < -BALANCE_TOL && error("Negative value persisted in balanced table at $(entry)")
        abs(value) <= 1.0e-12 && continue
        push!(rows, [
            entry.product_region,
            entry.product_sector,
            entry.column_region,
            entry.column_code,
            string(value),
        ])
    end
    sort!(rows, by = row -> join(row, '\t'))
    write_tsv(path, ["product_region", "product_sector", third_col, fourth_col, "value_meur"], rows)
end

function write_cell_diagnostics(
    path::AbstractString,
    entries::Vector{FlowEntry},
    balanced_values::Vector{Float64},
    third_col::String,
    fourth_col::String,
)
    rows = Vector{Vector{String}}()
    for pair in zip(entries, balanced_values)
        entry = pair[1]
        balanced = pair[2]
        delta = balanced - entry.value
        abs_delta = abs(delta)
        pct_delta = abs(entry.value) > 0.0 ? 100.0 * delta / entry.value : 0.0
        objective_contribution = 0.5 * delta^2
        push!(rows, [
            entry.product_region,
            entry.product_sector,
            entry.column_region,
            entry.column_code,
            string(entry.value),
            string(balanced),
            string(delta),
            string(abs_delta),
            string(pct_delta),
            string(objective_contribution),
        ])
    end
    sort!(rows, by = row -> (-parse(Float64, row[8]), row[1], row[2], row[3], row[4]))
    write_tsv(
        path,
        [
            "product_region",
            "product_sector",
            third_col,
            fourth_col,
            "original_value_meur",
            "balanced_value_meur",
            "delta_meur",
            "abs_delta_meur",
            "pct_delta",
            "objective_contribution",
        ],
        rows,
    )
end

function row_summary_rows(
    supply_entries::Vector{FlowEntry},
    supply_values::Vector{Float64},
    use_entries::Vector{FlowEntry},
    use_values::Vector{Float64},
)
    orig_supply = accumulate_totals(supply_entries; by = :row)
    orig_use = accumulate_totals(use_entries; by = :row)

    bal_supply = Dict{Tuple{String,String},Float64}()
    for pair in zip(supply_entries, supply_values)
        entry = pair[1]
        value = pair[2]
        key = row_key(entry)
        bal_supply[key] = get(bal_supply, key, 0.0) + value
    end
    bal_use = Dict{Tuple{String,String},Float64}()
    for pair in zip(use_entries, use_values)
        entry = pair[1]
        value = pair[2]
        key = row_key(entry)
        bal_use[key] = get(bal_use, key, 0.0) + value
    end

    all_rows = sort!(collect(union(keys(orig_supply), keys(orig_use))))
    rows = Vector{Vector{String}}()
    for key in all_rows
        push!(rows, [
            key[1],
            key[2],
            string(get(orig_supply, key, 0.0)),
            string(get(orig_use, key, 0.0)),
            string(get(orig_supply, key, 0.0) - get(orig_use, key, 0.0)),
            string(get(bal_supply, key, 0.0)),
            string(get(bal_use, key, 0.0)),
            string(get(bal_supply, key, 0.0) - get(bal_use, key, 0.0)),
        ])
    end
    return rows
end

function column_summary_rows(
    entries::Vector{FlowEntry},
    balanced_values::Vector{Float64},
    reconciled_targets::Dict{Tuple{String,String},Float64},
)
    original = accumulate_totals(entries; by = :col)
    balanced = Dict{Tuple{String,String},Float64}()
    abs_adjustment = Dict{Tuple{String,String},Float64}()
    for pair in zip(entries, balanced_values)
        entry = pair[1]
        value = pair[2]
        key = col_key(entry)
        balanced[key] = get(balanced, key, 0.0) + value
        abs_adjustment[key] = get(abs_adjustment, key, 0.0) + abs(value - entry.value)
    end

    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(reconciled_targets)))
        push!(rows, [
            key[1],
            key[2],
            string(get(original, key, 0.0)),
            string(get(reconciled_targets, key, 0.0)),
            string(get(balanced, key, 0.0)),
            string(get(balanced, key, 0.0) - get(original, key, 0.0)),
            string(get(balanced, key, 0.0) - get(reconciled_targets, key, 0.0)),
            string(get(abs_adjustment, key, 0.0)),
        ])
    end
    return rows
end

function validation_rows(
    supply_entries::Vector{FlowEntry},
    supply_values::Vector{Float64},
    use_entries::Vector{FlowEntry},
    use_values::Vector{Float64},
    supply_targets::Dict{Tuple{String,String},Float64},
    final_demand_targets::Dict{Tuple{String,String},Float64},
    activity_value_added_targets::Dict{Tuple{String,String},Float64},
    sector_ids::Set{String},
    commodity_gap_before::Float64,
    final_demand_macro_gap::Float64,
    λ::Float64,
    solve_result::SolveResult,
)
    supply_rows = row_summary_rows(supply_entries, supply_values, use_entries, use_values)
    max_row_gap = maximum(abs(parse(Float64, row[8])) for row in supply_rows)

    supply_cols = column_summary_rows(supply_entries, supply_values, supply_targets)
    use_cols = column_summary_rows(use_entries, use_values, final_demand_targets)
    max_supply_target_residual = maximum(abs(parse(Float64, row[7])) for row in supply_cols)
    max_use_target_residual = isempty(use_cols) ? 0.0 : maximum(abs(parse(Float64, row[7])) for row in use_cols)

    balanced_supply_cols = Dict{Tuple{String,String},Float64}()
    balanced_use_activity_cols = Dict{Tuple{String,String},Float64}()
    for pair in zip(supply_entries, supply_values)
        entry = pair[1]
        value = pair[2]
        key = col_key(entry)
        balanced_supply_cols[key] = get(balanced_supply_cols, key, 0.0) + value
    end
    for pair in zip(use_entries, use_values)
        entry = pair[1]
        value = pair[2]
        if entry.column_code in sector_ids
            key = col_key(entry)
            balanced_use_activity_cols[key] = get(balanced_use_activity_cols, key, 0.0) + value
        end
    end
    max_activity_gap = 0.0
    for key in keys(activity_value_added_targets)
        gap = get(balanced_supply_cols, key, 0.0) -
              get(balanced_use_activity_cols, key, 0.0) -
              activity_value_added_targets[key]
        max_activity_gap = max(max_activity_gap, abs(gap))
    end

    rows = [
        ["special_product_rows_fixed", join(sort!(collect(SPECIAL_PRODUCT_ROWS)), ";")],
        ["commodity_supply_total_before", string(sum(entry.value for entry in supply_entries))],
        ["commodity_use_total_before", string(sum(entry.value for entry in use_entries))],
        ["commodity_grand_total_gap_before", string(commodity_gap_before)],
        ["final_demand_macro_gap_before", string(final_demand_macro_gap)],
        ["column_target_reconciliation_lambda", string(λ)],
        ["commodity_supply_total_after", string(sum(supply_values))],
        ["commodity_use_total_after", string(sum(use_values))],
        ["commodity_grand_total_gap_after", string(sum(supply_values) - sum(use_values))],
        ["max_abs_row_gap_after", string(max_row_gap)],
        ["max_abs_activity_column_gap_after", string(max_activity_gap)],
        ["max_abs_supply_column_target_residual", string(max_supply_target_residual)],
        ["max_abs_use_column_target_residual", string(max_use_target_residual)],
        ["negative_supply_entries_after", string(count(<(-BALANCE_TOL), supply_values))],
        ["use_positive_support_negative_after", string(count(i -> use_entries[i].value >= 0.0 && use_values[i] < -BALANCE_TOL, eachindex(use_values)))],
        ["use_negative_support_positive_after", string(count(i -> use_entries[i].value < 0.0 && use_values[i] > BALANCE_TOL, eachindex(use_values)))],
        ["active_set_iterations", string(solve_result.iterations)],
        ["objective_value", string(solve_result.objective_value)],
        ["max_constraint_residual_internal", string(solve_result.max_constraint_residual)],
    ]
    return rows
end

function configuration_rows()
    return [
        ["approach", "quadratic_minimum_distance"],
        ["cell_objective", "unit_weight_squared_deviation_from_stage3_cells"],
        ["column_target_reconciliation", "final_demand_macro_reconciliation_only"],
        ["commodity_balance", "exact_supply_use_equality_by_product_region_and_product_sector"],
        ["supply_column_constraints", "stage3 industry output columns preserved exactly"],
        ["final_demand_column_constraints", "stage3 final-demand columns preserved exactly"],
        ["activity_identity_constraints", "supply columns equal intermediate-use columns plus fixed value-added"],
        ["support_rule", "existing_nonzero_commodity_cells_only"],
        ["noncommodity_rule", "special_rows_fixed_unchanged"],
        ["nonnegativity_rule", "active_set_with_zero_lower_bound"],
        ["special_product_rows", join(sort!(collect(SPECIAL_PRODUCT_ROWS)), ";")],
    ]
end

function main()
    ensure_dir(OUTDIR)

    raw_supply_entries = parse_flow_entries(IN_SUPPLY)
    raw_use_entries = parse_flow_entries(IN_USE)
    sector_ids = load_sector_ids(IN_SECTOR_REGISTRY)

    commodity_supply, fixed_supply = partition_entries(raw_supply_entries)
    commodity_use, fixed_use = partition_entries(raw_use_entries)

    supply_col_totals = accumulate_totals(commodity_supply; by = :col)
    _, raw_final_demand_targets = split_use_column_totals(commodity_use, sector_ids)
    activity_value_added_targets = fixed_activity_value_added(fixed_use, sector_ids)
    original_gap = sum(entry.value for entry in commodity_supply) - sum(entry.value for entry in commodity_use)
    final_demand_targets, final_demand_macro_gap, λ =
        reconcile_final_demand_targets(raw_final_demand_targets, activity_value_added_targets)

    solve_result = solve_with_active_set(
        commodity_supply,
        commodity_use,
        supply_col_totals,
        final_demand_targets,
        activity_value_added_targets,
    )

    final_supply_entries = vcat(commodity_supply, fixed_supply)
    final_supply_values = vcat(solve_result.supply_values, [entry.value for entry in fixed_supply])
    final_use_entries = vcat(commodity_use, fixed_use)
    final_use_values = vcat(solve_result.use_values, [entry.value for entry in fixed_use])

    write_balanced_table(OUT_SUPPLY, final_supply_entries, final_supply_values, "activity_region", "activity_sector", false)
    write_balanced_table(OUT_USE, final_use_entries, final_use_values, "use_region", "use_code", true)

    write_cell_diagnostics(OUT_SUPPLY_DIAG, commodity_supply, solve_result.supply_values, "activity_region", "activity_sector")
    write_cell_diagnostics(OUT_USE_DIAG, commodity_use, solve_result.use_values, "use_region", "use_code")

    write_tsv(
        OUT_ROW_SUMMARY,
        [
            "product_region",
            "product_sector",
            "original_supply_total_meur",
            "original_use_total_meur",
            "original_gap_meur",
            "balanced_supply_total_meur",
            "balanced_use_total_meur",
            "balanced_gap_meur",
        ],
        row_summary_rows(commodity_supply, solve_result.supply_values, commodity_use, solve_result.use_values),
    )

    write_tsv(
        OUT_SUPPLY_COL_SUMMARY,
        [
            "activity_region",
            "activity_sector",
            "original_total_meur",
            "target_meur",
            "balanced_total_meur",
            "delta_from_original_meur",
            "target_residual_meur",
            "sum_abs_cell_adjustment_meur",
        ],
        column_summary_rows(commodity_supply, solve_result.supply_values, supply_col_totals),
    )

    write_tsv(
        OUT_USE_COL_SUMMARY,
        [
            "use_region",
            "use_code",
            "original_total_meur",
            "target_meur",
            "balanced_total_meur",
            "delta_from_original_meur",
            "target_residual_meur",
            "sum_abs_cell_adjustment_meur",
        ],
        column_summary_rows(commodity_use, solve_result.use_values, final_demand_targets),
    )

    write_tsv(OUT_CONFIG, ["key", "value"], configuration_rows())
    write_tsv(
        OUT_VALIDATION,
        ["key", "value"],
        validation_rows(
            commodity_supply,
            solve_result.supply_values,
            commodity_use,
            solve_result.use_values,
            supply_col_totals,
            final_demand_targets,
            activity_value_added_targets,
            sector_ids,
            original_gap,
            final_demand_macro_gap,
            λ,
            solve_result,
        ),
    )

    println("Wrote stage-4 artifacts to ", OUTDIR)
end

main()
