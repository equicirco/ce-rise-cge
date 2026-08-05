#!/usr/bin/env julia

"""
Construct and balance the recycled-metal allocation in the symmetric IO table.

The 2016 IO accounts identify one recycling and recovery industry (`REC_EE`)
but not the purchasers of its recovered-metal output.  Positive, non-inventory
uses of `REC_EE` in each European destination region are therefore
reclassified as recycled-metal inputs.  They are allocated in proportion to
the region's observed intermediate purchases of `BASIC_METALS`.  The
corresponding BASIC_METALS inputs are reduced by the same amount.

That reclassification leaves some activity and product identities unbalanced.
The final table is the non-negative, weighted quadratic minimum-distance
adjustment of the reclassified table subject to the original EU industry
output and input totals.  Constructed recycled-metal allocations and their
corresponding primary-metal reductions are held fixed.  The diagnostics retain
both the direct reclassification and the balancing adjustment.
"""

using LinearAlgebra
using SparseArrays

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SOURCE_DIR = joinpath(ROOT_DIR, "data", "artifacts", "04b_symmetric_io")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "04c_recycled_metal_io")
const MAPPING_FILE = joinpath(ROOT_DIR, "data", "mappings", "recycled_metal_allocation.tsv")

const IN_INTERMEDIATE = joinpath(SOURCE_DIR, "industry_by_industry_intermediate.tsv")
const IN_FINAL = joinpath(SOURCE_DIR, "industry_by_final_demand.tsv")
const IN_VALUE_ADDED = joinpath(SOURCE_DIR, "value_added_by_industry.tsv")
const IN_OUTPUT = joinpath(SOURCE_DIR, "industry_output.tsv")
const IN_PRODUCT_OUTPUT = joinpath(SOURCE_DIR, "product_output.tsv")
const IN_SALES = joinpath(SOURCE_DIR, "product_sales_structure.tsv")

const OUT_INTERMEDIATE = joinpath(OUTDIR, "industry_by_industry_intermediate.tsv")
const OUT_FINAL = joinpath(OUTDIR, "industry_by_final_demand.tsv")
const OUT_VALUE_ADDED = joinpath(OUTDIR, "value_added_by_industry.tsv")
const OUT_OUTPUT = joinpath(OUTDIR, "industry_output.tsv")
const OUT_PRODUCT_OUTPUT = joinpath(OUTDIR, "product_output.tsv")
const OUT_SALES = joinpath(OUTDIR, "product_sales_structure.tsv")
const OUT_TECHNICAL = joinpath(OUTDIR, "industry_by_industry_technical_coefficients.tsv")
const OUT_ALLOCATION = joinpath(OUTDIR, "recycled_metal_allocation.tsv")
const OUT_DIAGNOSTICS = joinpath(OUTDIR, "recycled_metal_balancing_diagnostics.tsv")
const OUT_SUMMARY = joinpath(OUTDIR, "recycled_metal_balance_summary.tsv")
const OUT_VALIDATION = joinpath(OUTDIR, "symmetric_io_validation.tsv")

const EU_REGIONS = ["DE", "FR", "IT", "PL", "SK", "REU"]
const EU_REGION_SET = Set(EU_REGIONS)
const BASIC_METALS = "BASIC_METALS"
const RECYCLED_METAL = "REC_EE"
const INVENTORY_CODE = "P5M"
const TOL = 1.0e-8
const WEIGHT_FLOOR = 1.0e-4
const MAX_ACTIVE_SET_ITERATIONS = 100

struct IntermediateEntry
    origin_region::String
    origin_sector::String
    destination_region::String
    destination_sector::String
    value::Float64
end

struct FinalEntry
    origin_region::String
    origin_sector::String
    destination_region::String
    destination_code::String
    value::Float64
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

function copy_file(source::AbstractString, destination::AbstractString)
    cp(source, destination; force=true)
end

function load_intermediate(path::AbstractString)
    rows = read_tsv(path)
    return Dict(
        (row[1], row[2], row[3], row[4]) => parse(Float64, row[5])
        for row in rows[2:end]
    )
end

function load_final(path::AbstractString)
    rows = read_tsv(path)
    return Dict(
        (row[1], row[2], row[3], row[4]) => parse(Float64, row[5])
        for row in rows[2:end]
    )
end

function load_output(path::AbstractString)
    rows = read_tsv(path)
    labels = Dict{Tuple{String,String},String}()
    output = Dict{Tuple{String,String},Float64}()
    for row in rows[2:end]
        key = (row[1], row[2])
        labels[key] = row[3]
        output[key] = parse(Float64, row[4])
    end
    return output, labels
end

function load_value_added(path::AbstractString)
    rows = read_tsv(path)
    values = Dict{Tuple{String,String},Float64}()
    for row in rows[2:end]
        destination = (row[3], row[4])
        values[destination] = get(values, destination, 0.0) + parse(Float64, row[5])
    end
    return values
end

function require_allocation_configuration()
    rows = read_tsv(MAPPING_FILE)
    header = rows[1]
    header == ["key", "value", "description"] ||
        error("Unexpected recycled-metal allocation mapping header.")
    values = Dict(row[1] => row[2] for row in rows[2:end])
    expected = Dict(
        "allocation_scope" => "eu_destination_region",
        "eligible_use" => "basic_metals_intermediate_use",
        "weighting" => "proportional_to_basic_metals_use",
        "reclassification" => "all_positive_noninventory_rec_ee_uses",
        "balancing" => "quadratic_minimum_distance",
    )
    values == expected || error("Recycled-metal allocation mapping does not match the implemented construction.")
    return values
end

function positive_recycled_uses(intermediate, final, destination::String)
    rows = NamedTuple[]
    for (key, value) in intermediate
        origin, sector, target_region, target = key
        sector == RECYCLED_METAL && target_region == destination && value > TOL || continue
        push!(rows, (kind = :intermediate, key = key, origin = origin, value = value,
            source_target = target, source_code = target))
    end
    for (key, value) in final
        origin, sector, target_region, code = key
        sector == RECYCLED_METAL && target_region == destination &&
            code != INVENTORY_CODE && value > TOL || continue
        push!(rows, (kind = :final, key = key, origin = origin, value = value,
            source_target = code, source_code = code))
    end
    return sort!(rows, by=row -> (String(row.kind), row.origin, row.source_target))
end

function basic_metal_targets(intermediate, destination::String)
    targets = NamedTuple[]
    for (key, value) in intermediate
        origin, sector, target_region, target = key
        sector == BASIC_METALS && target_region == destination && value > TOL || continue
        push!(targets, (key = key, origin = origin, activity = target, value = value))
    end
    sort!(targets, by=row -> (row.origin, row.activity))
    return targets
end

function set_value!(dict, key, value)
    abs(value) <= TOL ? delete!(dict, key) : (dict[key] = value)
    return nothing
end

function construct_reclassification(intermediate, final)
    direct_intermediate = copy(intermediate)
    direct_final = copy(final)
    fixed_intermediate = Set{NTuple{4,String}}()
    allocation_rows = NamedTuple[]

    for destination in EU_REGIONS
        recycled_uses = positive_recycled_uses(intermediate, final, destination)
        isempty(recycled_uses) && continue
        targets = basic_metal_targets(intermediate, destination)
        isempty(targets) && error("$(destination) has recycled-metal availability but no positive BASIC_METALS intermediate uses.")
        total_recycled = sum(row.value for row in recycled_uses)
        total_primary = sum(row.value for row in targets)
        total_recycled < total_primary - TOL ||
            error("$(destination) recycled-metal allocation $(total_recycled) exceeds available BASIC_METALS intermediate use $(total_primary).")

        for row in recycled_uses
            row.kind === :intermediate ? delete!(direct_intermediate, row.key) : delete!(direct_final, row.key)
        end
        for target in targets
            reduction = total_recycled * target.value / total_primary
            replacement = target.value - reduction
            replacement >= -TOL || error("Negative BASIC_METALS use in $(destination), $(target.activity).")
            set_value!(direct_intermediate, target.key, max(0.0, replacement))
            push!(fixed_intermediate, target.key)
        end
        for source in recycled_uses
            for target in targets
                value = source.value * target.value / total_primary
                value <= TOL && continue
                key = (source.origin, RECYCLED_METAL, destination, target.activity)
                direct_intermediate[key] = get(direct_intermediate, key, 0.0) + value
                push!(fixed_intermediate, key)
                push!(allocation_rows, (
                    recycled_origin = source.origin,
                    destination_region = destination,
                    destination_activity = target.activity,
                    source_use_kind = source.kind,
                    source_use_target = source.source_target,
                    allocated_value_meur = value,
                    primary_metal_reduction_meur = value,
                    allocation_weight = target.value / total_primary,
                ))
            end
        end
    end
    return direct_intermediate, direct_final, fixed_intermediate, allocation_rows
end

function variable_entries(intermediate, final, fixed_intermediate)
    free = NamedTuple[]
    fixed = NamedTuple[]
    for (key, value) in intermediate
        entry = (kind = :intermediate, key = key, value = value)
        value > TOL && !(key in fixed_intermediate) ? push!(free, entry) : push!(fixed, entry)
    end
    for (key, value) in final
        entry = (kind = :final, key = key, value = value)
        value > TOL ? push!(free, entry) : push!(fixed, entry)
    end
    return free, fixed
end

function constraint_targets(output, value_added)
    rows = [(region, sector) for (region, sector) in keys(output) if region in EU_REGION_SET]
    sort!(rows)
    columns = copy(rows)
    targets = Dict{Tuple{Symbol,String,String},Float64}()
    for (region, sector) in rows
        targets[(:row, region, sector)] = output[(region, sector)]
        input_total = output[(region, sector)] - get(value_added, (region, sector), 0.0)
        input_total >= -TOL || error("Negative calibrated intermediate total for $(region), $(sector).")
        targets[(:column, region, sector)] = max(0.0, input_total)
    end
    return targets
end

function entry_constraints(entry)
    kind, key = entry.kind, entry.key
    origin, sector, destination, target = key
    constraints = Tuple{Symbol,String,String}[]
    origin in EU_REGION_SET && push!(constraints, (:row, origin, sector))
    kind === :intermediate && destination in EU_REGION_SET &&
        push!(constraints, (:column, destination, target))
    return constraints
end

function contribution_vector(entries, constraint_index, nconstraints)
    contribution = zeros(Float64, nconstraints)
    for entry in entries
        for condition in entry_constraints(entry)
            index = get(constraint_index, condition, nothing)
            index === nothing || (contribution[index] += entry.value)
        end
    end
    return contribution
end

function constrained_quadratic_balance(free, fixed, targets)
    conditions = sort!(collect(keys(targets)))
    condition_index = Dict(condition => index for (index, condition) in enumerate(conditions))
    nconditions = length(conditions)
    nfree = length(free)
    nfree > 0 || error("No free IO flows are available for quadratic balancing.")

    row_index = Int[]
    column_index = Int[]
    values = Float64[]
    for (column, entry) in enumerate(free)
        for condition in entry_constraints(entry)
            index = get(condition_index, condition, nothing)
            index === nothing && continue
            push!(row_index, index)
            push!(column_index, column)
            push!(values, 1.0)
        end
    end
    A = sparse(row_index, column_index, values, nconditions, nfree)
    a = Float64[entry.value for entry in free]
    b = Float64[targets[condition] for condition in conditions] -
        contribution_vector(fixed, condition_index, nconditions)
    scales = max.(abs.(a), WEIGHT_FLOOR)
    inverse_weight = scales .^ 2
    active = trues(nfree)
    solution = copy(a)

    for iteration in 1:MAX_ACTIVE_SET_ITERATIONS
        active_index = findall(active)
        isempty(active_index) && error("Quadratic balancing exhausted all adjustable IO flows.")
        Aactive = A[:, active_index]
        aactive = a[active_index]
        winverse = Diagonal(inverse_weight[active_index])
        residual = b - Aactive * aactive
        normal = Matrix(Aactive * winverse * transpose(Aactive))
        λ = try
            normal \ residual
        catch
            pinv(normal) * residual
        end
        values_active = aactive + winverse * transpose(Aactive) * λ
        solution .= 0.0
        solution[active_index] .= values_active
        negative = [index for index in active_index if solution[index] < -TOL]
        isempty(negative) && begin
            solution .= max.(solution, 0.0)
            final_residual = A * solution - b
            maximum(abs, final_residual) <= 1.0e-6 ||
                error("Quadratic IO balancing did not satisfy the constrained identities.")
            return solution, length(active_index), iteration, maximum(abs, final_residual)
        end
        worst = negative[argmin(solution[negative])]
        active[worst] = false
    end
    error("Quadratic IO balancing exceeded $(MAX_ACTIVE_SET_ITERATIONS) active-set iterations.")
end

function balanced_tables(free, fixed, solution)
    intermediate = Dict{NTuple{4,String},Float64}()
    final = Dict{NTuple{4,String},Float64}()
    for entry in fixed
        entry.kind === :intermediate ? (intermediate[entry.key] = entry.value) : (final[entry.key] = entry.value)
    end
    for (entry, value) in zip(free, solution)
        value <= TOL && continue
        target = entry.kind === :intermediate ? intermediate : final
        target[entry.key] = value
    end
    return intermediate, final
end

function io_residuals(intermediate, final, output, value_added)
    row = Dict{Tuple{String,String},Float64}()
    column = Dict{Tuple{String,String},Float64}()
    for (key, value) in intermediate
        add = (key[1], key[2])
        row[add] = get(row, add, 0.0) + value
        use = (key[3], key[4])
        column[use] = get(column, use, 0.0) + value
    end
    for (key, value) in final
        add = (key[1], key[2])
        row[add] = get(row, add, 0.0) + value
    end
    row_residual = Dict{Tuple{String,String},Float64}()
    column_residual = Dict{Tuple{String,String},Float64}()
    for (industry, value) in output
        industry[1] in EU_REGION_SET || continue
        row_residual[industry] = get(row, industry, 0.0) - value
        column_residual[industry] = get(column, industry, 0.0) + get(value_added, industry, 0.0) - value
    end
    return row_residual, column_residual
end

function technical_rows(intermediate, output)
    rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(intermediate)))
        value = intermediate[key]
        denominator = get(output, (key[3], key[4]), 0.0)
        coefficient = denominator > TOL ? value / denominator : NaN
        push!(rows, [key[1], key[2], key[3], key[4], string(value), string(coefficient)])
    end
    return rows
end

function diagnostics_rows(original_intermediate, original_final,
    direct_intermediate, direct_final, balanced_intermediate, balanced_final)
    rows = Vector{Vector{String}}()
    for kind in (:intermediate, :final)
        original = kind === :intermediate ? original_intermediate : original_final
        direct = kind === :intermediate ? direct_intermediate : direct_final
        balanced = kind === :intermediate ? balanced_intermediate : balanced_final
        keys_union = union(keys(original), keys(direct), keys(balanced))
        for key in sort!(collect(keys_union))
            before = get(original, key, 0.0)
            constructed = get(direct, key, 0.0)
            final_value = get(balanced, key, 0.0)
            abs(final_value - before) <= TOL && abs(constructed - before) <= TOL && continue
            push!(rows, [
                String(kind), key[1], key[2], key[3], key[4],
                string(before), string(constructed), string(final_value),
                string(final_value - before), string(final_value - constructed),
            ])
        end
    end
    return rows
end

function main()
    require_allocation_configuration()
    ensure_dir(OUTDIR)
    original_intermediate = load_intermediate(IN_INTERMEDIATE)
    original_final = load_final(IN_FINAL)
    output, _ = load_output(IN_OUTPUT)
    value_added = load_value_added(IN_VALUE_ADDED)

    direct_intermediate, direct_final, fixed_intermediate, allocation =
        construct_reclassification(original_intermediate, original_final)
    free, fixed = variable_entries(direct_intermediate, direct_final, fixed_intermediate)
    targets = constraint_targets(output, value_added)
    solution, active_count, iterations, max_constraint_residual =
        constrained_quadratic_balance(free, fixed, targets)
    balanced_intermediate, balanced_final = balanced_tables(free, fixed, solution)
    row_residual, column_residual = io_residuals(
        balanced_intermediate, balanced_final, output, value_added)
    max_row_residual = maximum(abs, values(row_residual))
    max_column_residual = maximum(abs, values(column_residual))
    max(max_row_residual, max_column_residual) <= 1.0e-6 ||
        error("Balanced recycled-metal IO table does not satisfy industry identities.")

    allocation_rows = Vector{Vector{String}}()
    for row in allocation
        push!(allocation_rows, [
            row.recycled_origin, row.destination_region, row.destination_activity,
            String(row.source_use_kind), row.source_use_target,
            string(row.allocated_value_meur), string(row.primary_metal_reduction_meur),
            string(row.allocation_weight),
        ])
    end
    diagnostics = diagnostics_rows(original_intermediate, original_final,
        direct_intermediate, direct_final, balanced_intermediate, balanced_final)
    direct_reclassification = sum(abs(get(direct_intermediate, key, 0.0) - value)
        for (key, value) in original_intermediate) +
        sum(abs(get(direct_final, key, 0.0) - value) for (key, value) in original_final)
    balance_adjustment = sum(abs(get(balanced_intermediate, key, 0.0) -
        get(direct_intermediate, key, 0.0)) for key in union(keys(balanced_intermediate), keys(direct_intermediate))) +
        sum(abs(get(balanced_final, key, 0.0) -
        get(direct_final, key, 0.0)) for key in union(keys(balanced_final), keys(direct_final)))
    total_allocated = sum(row.allocated_value_meur for row in allocation)

    write_tsv(OUT_INTERMEDIATE,
        ["row_region", "row_sector", "column_region", "column_sector", "value_meur"],
        [[key[1], key[2], key[3], key[4], string(balanced_intermediate[key])]
            for key in sort!(collect(keys(balanced_intermediate)))] )
    write_tsv(OUT_FINAL,
        ["row_region", "row_sector", "final_demand_region", "final_demand_code", "value_meur"],
        [[key[1], key[2], key[3], key[4], string(balanced_final[key])]
            for key in sort!(collect(keys(balanced_final)))] )
    copy_file(IN_VALUE_ADDED, OUT_VALUE_ADDED)
    copy_file(IN_OUTPUT, OUT_OUTPUT)
    copy_file(IN_PRODUCT_OUTPUT, OUT_PRODUCT_OUTPUT)
    copy_file(IN_SALES, OUT_SALES)
    write_tsv(OUT_TECHNICAL,
        ["row_region", "row_sector", "column_region", "column_sector", "value_meur", "technical_coefficient"],
        technical_rows(balanced_intermediate, output))
    write_tsv(OUT_ALLOCATION,
        ["recycled_origin", "destination_region", "destination_activity", "source_use_kind", "source_use_target", "allocated_value_meur", "primary_metal_reduction_meur", "allocation_weight"],
        allocation_rows)
    write_tsv(OUT_DIAGNOSTICS,
        ["table", "row_region", "row_sector", "column_region", "column_code", "original_value_meur", "constructed_value_meur", "balanced_value_meur", "change_from_original_meur", "balancing_adjustment_meur"],
        diagnostics)
    write_tsv(OUT_SUMMARY, ["key", "value"], [
        ["allocation_scope", "destination_region_proportional_basic_metals_intermediate_use"],
        ["total_recycled_metal_allocation_meur", string(total_allocated)],
        ["total_primary_metal_reduction_meur", string(total_allocated)],
        ["fixed_constructed_intermediate_cells", string(length(fixed_intermediate))],
        ["free_balancing_cells", string(length(free))],
        ["active_balancing_cells", string(active_count)],
        ["active_set_iterations", string(iterations)],
        ["direct_reclassification_l1_meur", string(direct_reclassification)],
        ["balancing_adjustment_l1_meur", string(balance_adjustment)],
        ["max_constraint_residual", string(max_constraint_residual)],
        ["max_abs_row_gap", string(max_row_residual)],
        ["max_abs_column_gap", string(max_column_residual)],
    ])
    write_tsv(OUT_VALIDATION, ["key", "value"], [
        ["industry_count", string(length(output))],
        ["allocation_rule", "proportional_basic_metals_intermediate_use"],
        ["total_recycled_metal_allocation_meur", string(total_allocated)],
        ["max_abs_row_gap", string(max_row_residual)],
        ["max_abs_column_gap", string(max_column_residual)],
        ["max_constraint_residual", string(max_constraint_residual)],
    ])
    println("Wrote recycled-metal allocation and balanced IO artifacts to ", OUTDIR)
end

main()
