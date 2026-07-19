#!/usr/bin/env julia

"""
Validate SUT value preservation against the FIGARO-based base tables.

Two validation modes are supported:

1. replace
   Use when parent sectors are replaced by split sectors.
   The candidate table is collapsed back to parent codes and compared with the
   full base table.

2. augment
   Use when parent sectors are kept and split sectors are added alongside them.
   The split-generated candidate rows are collapsed back to parent codes and
   compared only with the affected part of the base table.

In addition to those early SUT checks, this validator also follows the later
artifact chain through the balanced SUT, the core SAM bridge, and the final
closed SAM used as the benchmark calibration base.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")
const ARTIFACT_DIR = joinpath(ROOT_DIR, "data", "artifacts")

const BASE_SUPPLY = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const BASE_USE = joinpath(SUT_DIR, "sut_use_base_2016.tsv")
const MANUFACTURING_SUPPLY = joinpath(SUT_DIR, "sut_supply_disaggregated_unbalanced.tsv")
const MANUFACTURING_USE = joinpath(SUT_DIR, "sut_use_disaggregated_unbalanced.tsv")
const MANUFACTURING_MAP = joinpath(SUT_DIR, "sut_parent_child_figaro_map.tsv")
const INTERMEDIATE_SUPPLY = joinpath(SUT_DIR, "sut_supply_intermediate_augmented.tsv")
const INTERMEDIATE_USE = joinpath(SUT_DIR, "sut_use_intermediate_augmented.tsv")
const INTERMEDIATE_MAP = joinpath(SUT_DIR, "sut_intermediate_split_map.tsv")
const REPORT_FILE = joinpath(SUT_DIR, "sut_validation_report.tsv")
const ARTIFACT_REPORT_FILE = joinpath(ARTIFACT_DIR, "artifact_validation_report.tsv")
const ARTIFACT_SUMMARY_FILE = joinpath(ARTIFACT_DIR, "artifact_validation_summary.tsv")

const STAGE1_DIR = joinpath(ARTIFACT_DIR, "01_initial_data")
const STAGE2_DIR = joinpath(ARTIFACT_DIR, "02_integrated_sut")
const STAGE3_DIR = joinpath(ARTIFACT_DIR, "03_final_preparation")
const STAGE4_DIR = joinpath(ARTIFACT_DIR, "04_balanced_sut")
const STAGE4B_DIR = joinpath(ARTIFACT_DIR, "04b_symmetric_io")
const STAGE5_DIR = joinpath(ARTIFACT_DIR, "05_core_sam")
const STAGE6_DIR = joinpath(ARTIFACT_DIR, "06_closed_sam")
const STAGE7_DIR = joinpath(ARTIFACT_DIR, "07_model_scaffold")
const STAGE8_DIR = joinpath(ARTIFACT_DIR, "08_six_region_bundle")

const STAGE1_FILES = [
    "figaro_reference_supply.tsv",
    "figaro_reference_use.tsv",
    "bonsai_relevant_overlay_regions.tsv",
    "ce_rise_parent_to_figaro.tsv",
]
const STAGE2_VALIDATION = joinpath(STAGE2_DIR, "integrated_validation.tsv")
const STAGE3_VALIDATION = joinpath(STAGE3_DIR, "final_validation.tsv")
const STAGE4_VALIDATION = joinpath(STAGE4_DIR, "balancing_validation.tsv")
const STAGE4B_VALIDATION = joinpath(STAGE4B_DIR, "symmetric_io_validation.tsv")
const STAGE5_VALIDATION = joinpath(STAGE5_DIR, "core_sam_validation.tsv")
const STAGE6_VALIDATION = joinpath(STAGE6_DIR, "closed_sam_validation.tsv")
const STAGE6_ACCOUNTS = joinpath(STAGE6_DIR, "closed_sam_accounts.tsv")
const STAGE6_MATRIX = joinpath(STAGE6_DIR, "closed_sam_matrix.tsv")
const STAGE6_BALANCES = joinpath(STAGE6_DIR, "closed_sam_account_balances.tsv")
const STAGE6_MACRO_SUMMARY = joinpath(STAGE6_DIR, "closed_sam_macro_summary.tsv")
const STAGE7_VALIDATION = joinpath(STAGE7_DIR, "stage7_validation.tsv")
const STAGE8_VALIDATION = joinpath(STAGE8_DIR, "bundle_validation.tsv")
const STAGE8_MODEL_CONFIGURATION = joinpath(STAGE8_DIR, "model_configuration.tsv")

const TOL = 1.0e-8
const LATE_TOL = 1.0e-6

struct SplitMaps
    parent_product_by_split::Dict{String,String}
    parent_code2_by_split::Dict{String,String}
    split_products::Set{String}
    split_code2::Set{String}
    parent_products::Set{String}
    parent_code2::Set{String}
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

function read_simple_csv(path::AbstractString)
    rows = Vector{Vector{String}}()
    open(path, "r") do io
        for line in eachline(io)
            isempty(line) && continue
            push!(rows, split(line, ','))
        end
    end
    return rows
end

function read_key_value_file(path::AbstractString)
    rows = read_tsv(path)
    values = Dict{String,String}()
    for row in rows[2:end]
        length(row) >= 2 || continue
        values[row[1]] = row[2]
    end
    return values
end

function parse_float(dict::Dict{String,String}, key::String)
    haskey(dict, key) || error("Missing key $(key)")
    return parse(Float64, dict[key])
end

function parse_int(dict::Dict{String,String}, key::String)
    haskey(dict, key) || error("Missing key $(key)")
    return parse(Int, dict[key])
end

function canonical_code2(code::AbstractString)
    code == "E37-39" && return "E37-E39"
    return String(code)
end

function load_split_maps(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))

    product_parent_col =
        haskey(idx, "target_parent_product_code") ? "target_parent_product_code" :
        haskey(idx, "figaro_parent_product_code") ? "figaro_parent_product_code" :
        error("No parent product column found in $(path)")

    code2_parent_col =
        haskey(idx, "target_parent_activity_code") ? "target_parent_activity_code" :
        haskey(idx, "figaro_parent_activity_code") ? "figaro_parent_activity_code" :
        error("No parent activity column found in $(path)")

    split_product_col = "split_product_code"
    split_code2_col = "split_activity_code"

    parent_product_by_split = Dict{String,String}()
    parent_code2_by_split = Dict{String,String}()
    split_products = Set{String}()
    split_code2 = Set{String}()
    parent_products = Set{String}()
    parent_code2 = Set{String}()

    for row in rows[2:end]
        parent_product = row[idx[product_parent_col]]
        parent2 = row[idx[code2_parent_col]]
        split_product = row[idx[split_product_col]]
        split2 = row[idx[split_code2_col]]

        parent_product_by_split[split_product] = parent_product
        parent_code2_by_split[split2] = parent2
        push!(split_products, split_product)
        push!(split_code2, split2)
        push!(parent_products, parent_product)
        push!(parent_code2, parent2)
    end

    return SplitMaps(
        parent_product_by_split,
        parent_code2_by_split,
        split_products,
        split_code2,
        parent_products,
        parent_code2,
    )
end

function load_table(path::AbstractString)
    rows = read_tsv(path)
    header = rows[1]
    length(header) == 5 || error("Expected 5 columns in $(path)")
    data = Vector{Tuple{NTuple{4,String},Float64}}()
    for row in rows[2:end]
        key = (row[1], row[2], row[3], canonical_code2(row[4]))
        value = parse(Float64, row[5])
        push!(data, (key, value))
    end
    return data
end

function aggregate_rows(rows)
    totals = Dict{NTuple{4,String},Float64}()
    for (key, value) in rows
        totals[key] = get(totals, key, 0.0) + value
    end
    return totals
end

function collapse_key(key::NTuple{4,String}, maps::SplitMaps)
    r1, c1, r2, c2 = key
    collapsed_c1 = get(maps.parent_product_by_split, c1, c1)
    collapsed_c2 = get(maps.parent_code2_by_split, c2, c2)
    return (r1, collapsed_c1, r2, collapsed_c2)
end

function collapse_rows(rows, maps::SplitMaps)
    return [(collapse_key(key, maps), value) for (key, value) in rows]
end

function row_has_split(key::NTuple{4,String}, maps::SplitMaps)
    return key[2] in maps.split_products || key[4] in maps.split_code2
end

function row_is_affected_base(key::NTuple{4,String}, maps::SplitMaps)
    return key[2] in maps.parent_products || key[4] in maps.parent_code2
end

function compare_aggregates(left::Dict{NTuple{4,String},Float64}, right::Dict{NTuple{4,String},Float64}; tol::Float64 = TOL)
    keys_union = union(keys(left), keys(right))
    n_diff = 0
    max_abs_diff = 0.0
    sum_abs_diff = 0.0
    for key in keys_union
        diff = get(left, key, 0.0) - get(right, key, 0.0)
        absdiff = abs(diff)
        if absdiff > tol
            n_diff += 1
            max_abs_diff = max(max_abs_diff, absdiff)
            sum_abs_diff += absdiff
        end
    end
    return n_diff, max_abs_diff, sum_abs_diff, length(keys_union)
end

function total_value(rows)
    s = 0.0
    for (_, value) in rows
        s += value
    end
    return s
end

function validate_pair(label, mode, base_file, candidate_file, map_file)
    maps = load_split_maps(map_file)
    base_rows = load_table(base_file)
    candidate_rows = load_table(candidate_file)

    if mode == "replace"
        base_agg = aggregate_rows(base_rows)
        candidate_collapsed_agg = aggregate_rows(collapse_rows(candidate_rows, maps))
        n_diff, max_abs_diff, sum_abs_diff, n_keys = compare_aggregates(base_agg, candidate_collapsed_agg)
        return Dict(
            "label" => label,
            "mode" => mode,
            "base_file" => base_file,
            "candidate_file" => candidate_file,
            "base_total" => total_value(base_rows),
            "candidate_total" => total_value(candidate_rows),
            "comparison_total" => total_value(collapse_rows(candidate_rows, maps)),
            "n_diff" => n_diff,
            "max_abs_diff" => max_abs_diff,
            "sum_abs_diff" => sum_abs_diff,
            "n_keys" => n_keys,
            "status" => n_diff == 0 ? "PASS" : "FAIL",
        )
    elseif mode == "augment"
        affected_base_rows = [(key, value) for (key, value) in base_rows if row_is_affected_base(key, maps)]
        split_candidate_rows = [(key, value) for (key, value) in candidate_rows if row_has_split(key, maps)]
        affected_base_agg = aggregate_rows(affected_base_rows)
        collapsed_split_agg = aggregate_rows(collapse_rows(split_candidate_rows, maps))
        n_diff, max_abs_diff, sum_abs_diff, n_keys = compare_aggregates(affected_base_agg, collapsed_split_agg)
        return Dict(
            "label" => label,
            "mode" => mode,
            "base_file" => base_file,
            "candidate_file" => candidate_file,
            "base_total" => total_value(base_rows),
            "candidate_total" => total_value(candidate_rows),
            "comparison_total" => total_value(split_candidate_rows),
            "n_diff" => n_diff,
            "max_abs_diff" => max_abs_diff,
            "sum_abs_diff" => sum_abs_diff,
            "n_keys" => n_keys,
            "status" => n_diff == 0 ? "PASS" : "FAIL",
        )
    else
        error("Unsupported mode: $(mode)")
    end
end

function maybe_validate(validations, label, mode, base_file, candidate_file, map_file)
    if isfile(candidate_file) && isfile(map_file)
        push!(validations, validate_pair(label, mode, base_file, candidate_file, map_file))
    end
end

function report_rows(validations)
    rows = Vector{Vector{String}}()
    for v in validations
        push!(rows, [
            v["label"],
            v["mode"],
            v["status"],
            v["base_file"],
            v["candidate_file"],
            string(v["base_total"]),
            string(v["candidate_total"]),
            string(v["comparison_total"]),
            string(v["n_diff"]),
            string(v["max_abs_diff"]),
            string(v["sum_abs_diff"]),
            string(v["n_keys"]),
        ])
    end
    return rows
end

function print_summary(validations)
    for v in validations
        println(v["label"], " [", v["mode"], "] ", v["status"])
        println("  base total:       ", v["base_total"])
        println("  candidate total:  ", v["candidate_total"])
        println("  compared total:   ", v["comparison_total"])
        println("  differing keys:   ", v["n_diff"], " / ", v["n_keys"])
        println("  max abs diff:     ", v["max_abs_diff"])
        println("  sum abs diff:     ", v["sum_abs_diff"])
    end
end

function artifact_row(stage, check, status, source_file, observed, expected, notes)
    return [stage, check, status, source_file, observed, expected, notes]
end

function artifact_status(ok::Bool)
    return ok ? "PASS" : "FAIL"
end

function append_stage_table_status!(rows, stage::String, source_file::String, default_check::String)
    if !isfile(source_file)
        push!(rows, artifact_row(stage, default_check, "FAIL", source_file, "missing", "file exists", "Required validation file is missing."))
        return
    end

    data = read_tsv(source_file)
    header = data[1]
    status_idx = findfirst(==("status"), header)
    label_idx = findfirst(x -> x in ("table", "label"), header)

    if isnothing(status_idx) || isnothing(label_idx)
        push!(rows, artifact_row(stage, default_check, "FAIL", source_file, "unreadable", "status column present", "Validation table does not contain the expected columns."))
        return
    end

    for row in data[2:end]
        check = string(default_check, ":", row[label_idx])
        status = row[status_idx]
        push!(rows, artifact_row(stage, check, status, source_file, status, "PASS", "Stage-specific validation row reported by the builder."))
    end
end

function append_stage4_checks!(rows)
    if !isfile(STAGE4_VALIDATION)
        push!(rows, artifact_row("04_balanced_sut", "validation_file", "FAIL", STAGE4_VALIDATION, "missing", "file exists", "Stage-4 validation file is missing."))
        return
    end

    values = read_key_value_file(STAGE4_VALIDATION)
    checks = [
        ("commodity_gap_after", abs(parse_float(values, "commodity_grand_total_gap_after")) <= LATE_TOL, values["commodity_grand_total_gap_after"], "<= $(LATE_TOL)", "Balanced supply and use should agree at the aggregate commodity level."),
        ("max_row_gap_after", abs(parse_float(values, "max_abs_row_gap_after")) <= LATE_TOL, values["max_abs_row_gap_after"], "<= $(LATE_TOL)", "Commodity rows should be balanced after stage 4."),
        ("max_activity_column_gap_after", abs(parse_float(values, "max_abs_activity_column_gap_after")) <= LATE_TOL, values["max_abs_activity_column_gap_after"], "<= $(LATE_TOL)", "Industry columns should satisfy output equals intermediate inputs plus fixed value added."),
        ("supply_column_residual", abs(parse_float(values, "max_abs_supply_column_target_residual")) <= LATE_TOL, values["max_abs_supply_column_target_residual"], "<= $(LATE_TOL)", "Supply columns should stay close to their targets."),
        ("use_column_residual", abs(parse_float(values, "max_abs_use_column_target_residual")) <= LATE_TOL, values["max_abs_use_column_target_residual"], "<= $(LATE_TOL)", "Use columns should stay close to their targets."),
        ("negative_supply_entries", parse_int(values, "negative_supply_entries_after") == 0, values["negative_supply_entries_after"], "0", "Supply cells must remain nonnegative."),
        ("use_positive_support_negative", parse_int(values, "use_positive_support_negative_after") == 0, values["use_positive_support_negative_after"], "0", "A positive-use support set should not flip negative after balancing."),
        ("use_negative_support_positive", parse_int(values, "use_negative_support_positive_after") == 0, values["use_negative_support_positive_after"], "0", "A negative-use support set should not flip positive after balancing."),
    ]

    for (check, ok, observed, expected, notes) in checks
        push!(rows, artifact_row("04_balanced_sut", check, artifact_status(ok), STAGE4_VALIDATION, observed, expected, notes))
    end
end

function append_stage4b_checks!(rows)
    if !isfile(STAGE4B_VALIDATION)
        push!(rows, artifact_row("04b_symmetric_io", "validation_file", "FAIL", STAGE4B_VALIDATION, "missing", "file exists", "Stage-4b validation file is missing."))
        return
    end

    values = read_key_value_file(STAGE4B_VALIDATION)
    checks = [
        ("industry_count", parse_int(values, "industry_count") > 0, values["industry_count"], "> 0", "The symmetric IO should contain explicit industries."),
        ("product_count", parse_int(values, "product_count") > 0, values["product_count"], "> 0", "The symmetric IO should be derived from explicit product rows."),
        ("sales_share_gap", abs(parse_float(values, "max_abs_product_sales_share_gap")) <= LATE_TOL, values["max_abs_product_sales_share_gap"], "<= $(LATE_TOL)", "Product sales shares should sum to one up to numerical tolerance."),
        ("row_gap", abs(parse_float(values, "max_abs_row_gap")) <= LATE_TOL, values["max_abs_row_gap"], "<= $(LATE_TOL)", "Industry row totals should equal intermediate plus final uses."),
        ("column_gap", abs(parse_float(values, "max_abs_column_gap")) <= LATE_TOL, values["max_abs_column_gap"], "<= $(LATE_TOL)", "Industry column totals should equal intermediate inputs plus value added."),
        ("final_demand_gap", abs(parse_float(values, "max_abs_final_demand_gap")) <= LATE_TOL, values["max_abs_final_demand_gap"], "<= $(LATE_TOL)", "Final-demand totals should be preserved by the Model-D transformation."),
        ("row_gap_count", parse_int(values, "row_gap_count_gt_1e-6") == 0, values["row_gap_count_gt_1e-6"], "0", "No industry row should exceed the post-transformation balance tolerance."),
        ("column_gap_count", parse_int(values, "column_gap_count_gt_1e-6") == 0, values["column_gap_count_gt_1e-6"], "0", "No industry column should exceed the post-transformation balance tolerance."),
        ("final_demand_gap_count", parse_int(values, "final_demand_gap_count_gt_1e-6") == 0, values["final_demand_gap_count_gt_1e-6"], "0", "No final-demand column should exceed the preservation tolerance."),
    ]

    for (check, ok, observed, expected, notes) in checks
        push!(rows, artifact_row("04b_symmetric_io", check, artifact_status(ok), STAGE4B_VALIDATION, observed, expected, notes))
    end
end

function append_stage5_checks!(rows)
    if !isfile(STAGE5_VALIDATION)
        push!(rows, artifact_row("05_core_sam", "validation_file", "FAIL", STAGE5_VALIDATION, "missing", "file exists", "Stage-5 validation file is missing."))
        return
    end

    values = read_key_value_file(STAGE5_VALIDATION)
    checks = [
        ("account_structure", get(values, "account_structure", "") == "industry_by_industry", get(values, "account_structure", "missing"), "industry_by_industry", "Stage 5 should use one account for each industry and region."),
        ("industries_per_region", parse_int(values, "n_industries_per_region") == 25, values["n_industries_per_region"], "25", "The core SAM should retain the 25-industry sector structure."),
        ("account_count", parse_int(values, "n_accounts") == 187, values["n_accounts"], "187", "The six-region core account structure should include industries, factors, institutions, external accounts, and the investment pool."),
    ]

    for (check, ok, observed, expected, notes) in checks
        push!(rows, artifact_row("05_core_sam", check, artifact_status(ok), STAGE5_VALIDATION, observed, expected, notes))
    end
end

function closed_sam_calibration_ready()
    accounts = read_tsv(STAGE6_ACCOUNTS)
    matrix = read_tsv(STAGE6_MATRIX)
    balances = read_tsv(STAGE6_BALANCES)
    macro_rows_tsv = read_tsv(STAGE6_MACRO_SUMMARY)

    n_accounts = length(accounts) - 1
    matrix_square = length(matrix) == n_accounts + 1 && length(matrix[1]) == n_accounts + 1

    types = Set(row[2] for row in accounts[2:end])
    required_types = Set(["industry", "factor", "institution", "external", "investment_pool"])
    type_ok = required_types == types

    external_count = count(row -> row[2] == "external", accounts[2:end])
    industry_regions = Set(row[3] for row in accounts[2:end] if row[2] == "industry")
    external_regions = Set(row[3] for row in accounts[2:end] if row[2] == "external")
    macro_region_rows = length(macro_rows_tsv) - 1
    max_abs_balance = maximum(abs(parse(Float64, row[7])) for row in balances[2:end])
    type_list = join(sort!(collect(types)), ",")

    ok = matrix_square && type_ok && external_count == length(industry_regions) && external_regions == industry_regions && macro_region_rows == length(industry_regions) && max_abs_balance <= LATE_TOL
    observed = "square=$(matrix_square); types=$(type_list); external_count=$(external_count); external_regions=$(join(sort!(collect(external_regions)), ",")); macro_rows=$(macro_region_rows); max_abs_balance=$(max_abs_balance)"
    expected = "square=true; types=industry,external,factor,institution,investment_pool; external_count=$(length(industry_regions)); external_regions=$(join(sort!(collect(industry_regions)), ",")); macro_rows=$(length(industry_regions)); max_abs_balance<=$(LATE_TOL)"
    notes = "Closed SAM should be square, exactly balanced, and institutionally complete enough to serve as the benchmark calibration base."
    return ok, observed, expected, notes
end

function append_stage6_checks!(rows)
    required_files = [STAGE6_VALIDATION, STAGE6_ACCOUNTS, STAGE6_MATRIX, STAGE6_BALANCES, STAGE6_MACRO_SUMMARY]
    missing = [path for path in required_files if !isfile(path)]
    if !isempty(missing)
        push!(rows, artifact_row("06_closed_sam", "required_files", "FAIL", STAGE6_DIR, join(missing, ";"), "all required files present", "Closed-SAM artifact set is incomplete."))
        return
    end

    values = read_key_value_file(STAGE6_VALIDATION)
    checks = [
        ("max_abs_balance", abs(parse_float(values, "max_abs_balance")) <= LATE_TOL, values["max_abs_balance"], "<= $(LATE_TOL)", "The closed SAM should balance exactly up to numerical tolerance."),
        ("total_abs_balance", abs(parse_float(values, "total_abs_balance")) <= 1.0e-5, values["total_abs_balance"], "<= 1.0e-5", "Total balance error across all accounts should remain negligible."),
        ("household_npish_rule", get(values, "household_npish_rule", "") == "P3_S15 merged into households", get(values, "household_npish_rule", "missing"), "P3_S15 merged into households", "The intended household/NPISH closure rule should be recorded."),
        ("account_structure", get(values, "account_structure", "") == "industry_by_industry", get(values, "account_structure", "missing"), "industry_by_industry", "The closed SAM should retain one account for each industry and region."),
        ("industry_account_count", parse_int(values, "n_industry_accounts") == 150, values["n_industry_accounts"], "150", "The six-region SAM should contain 25 industry accounts in each region."),
    ]

    for (check, ok, observed, expected, notes) in checks
        push!(rows, artifact_row("06_closed_sam", check, artifact_status(ok), STAGE6_VALIDATION, observed, expected, notes))
    end

    calibration_ok, observed, expected, notes = closed_sam_calibration_ready()
    push!(rows, artifact_row("06_closed_sam", "calibration_ready", artifact_status(calibration_ok), STAGE6_DIR, observed, expected, notes))
end

function append_stage7_checks!(rows)
    if !isfile(STAGE7_VALIDATION)
        push!(rows, artifact_row("07_model_scaffold", "validation_file", "FAIL", STAGE7_VALIDATION, "missing", "file exists", "Stage-7 validation file is missing."))
        return
    end

    values = read_key_value_file(STAGE7_VALIDATION)
    checks = [
        ("model_scope", get(values, "model_scope", "missing") == "six_european_regions_with_regional_external_accounts", get(values, "model_scope", "missing"), "six_european_regions_with_regional_external_accounts", "The model templates must be usable independently in each of the six European regions."),
        ("required_sut_sectors_present", get(values, "missing_required_sut_sectors", "missing") == "none", get(values, "missing_required_sut_sectors", "missing"), "none", "All sectors required by the stylized-consistent circular route structure should be present in the SUT."),
        ("family_registry_rows", parse_int(values, "n_families") == 3, values["n_families"], "3", "The empirical model should cover the three CE-RISE product families."),
        ("route_registry_rows", parse_int(values, "n_route_rows") == 18, values["n_route_rows"], "18", "The route registry should contain six routes per family: NEW, REF, REP, REU, REC, and INC."),
        ("service_route_rows", parse_int(values, "n_service_routes") == 12, values["n_service_routes"], "12", "Each family should have four service-supplying routes: NEW, REF, REP, and REU."),
        ("eol_route_rows", parse_int(values, "n_eol_routes") == 6, values["n_eol_routes"], "6", "Each family should map end-of-life flows to REC and INC in addition to life-extension routes."),
        ("quantity_bridge_rows", parse_int(values, "n_quantity_rows") == 21, values["n_quantity_rows"], "21", "The physical quantity bridge should cover family service, route, and end-of-life anchors plus the single METAL commodity and disposal activity."),
        ("coefficient_rows", parse_int(values, "n_coefficient_rows") == 22, values["n_coefficient_rows"], "22", "The physical coefficient template should cover family-specific route coefficients plus the shared recycling yield for METAL output."),
        ("service_alignment", get(values, "service_alignment", "missing") == "TST uses NEW,REF,REP,REU by family", get(values, "service_alignment", "missing"), "TST uses NEW,REF,REP,REU by family", "Each regional service composite should mirror the stylized route nest."),
        ("physical_quantity_rule", get(values, "physical_quantity_rule", "missing") == "Q_t = Q0 * q_t; fallback uses value divided by benchmark unit value and relative price", get(values, "physical_quantity_rule", "missing"), "Q_t = Q0 * q_t; fallback uses value divided by benchmark unit value and relative price", "Physical reporting should follow model quantity indices and only fall back to value/price conversion when needed."),
    ]

    for (check, ok, observed, expected, notes) in checks
        push!(rows, artifact_row("07_model_scaffold", check, artifact_status(ok), STAGE7_VALIDATION, observed, expected, notes))
    end
end

function append_stage8_checks!(rows)
    required_files = [
        joinpath(STAGE8_DIR, "sam.csv"),
        joinpath(STAGE8_DIR, "sets.csv"),
        joinpath(STAGE8_DIR, "labels.csv"),
        joinpath(STAGE8_DIR, "subsets.csv"),
        joinpath(STAGE8_DIR, "mappings.csv"),
        STAGE8_MODEL_CONFIGURATION,
        STAGE8_VALIDATION,
    ]
    missing = [path for path in required_files if !isfile(path)]
    if !isempty(missing)
        push!(rows, artifact_row("08_six_region_bundle", "required_files", "FAIL", STAGE8_DIR, join(missing, ";"), "all canonical bundle files present", "Six-region canonical calibration bundle is incomplete."))
        return
    end

    values = read_key_value_file(STAGE8_VALIDATION)
    checks = [
        ("model_scope", get(values, "model_scope", "missing") == "six_european_regions_with_regional_external_accounts", get(values, "model_scope", "missing"), "six_european_regions_with_regional_external_accounts", "The bundle must retain the six European regions and their regional external accounts."),
        ("regional_industry_count", parse_int(values, "regional_industry_count") == 25, values["regional_industry_count"], "25", "Every region must contain the 25 retained industries."),
        ("bundle_industry_count", parse_int(values, "bundle_industry_count") == 150, values["bundle_industry_count"], "150", "Six regions with 25 industries must yield 150 industry accounts."),
        ("bundle_factor_count", parse_int(values, "bundle_factor_count") == 12, values["bundle_factor_count"], "12", "Six regions must retain labour and capital separately."),
        ("bundle_institution_count", parse_int(values, "bundle_institution_count") == 18, values["bundle_institution_count"], "18", "Six regions must retain household, government, and investment institutions."),
        ("bundle_external_count", parse_int(values, "bundle_external_count") == 6, values["bundle_external_count"], "6", "Each region must retain its own external account."),
        ("bundle_investment_pool_count", parse_int(values, "bundle_investment_pool_count") == 1, values["bundle_investment_pool_count"], "1", "The closed SAM must retain the global investment-pool account."),
        ("sam_square", get(values, "sam_square", "missing") == "true", get(values, "sam_square", "missing"), "true", "Canonical SAM must be square."),
        ("max_abs_balance", abs(parse_float(values, "max_abs_balance")) <= LATE_TOL, values["max_abs_balance"], "<= $(LATE_TOL)", "Canonical six-region SAM should balance exactly up to numerical tolerance."),
    ]

    for (check, ok, observed, expected, notes) in checks
        push!(rows, artifact_row("08_six_region_bundle", check, artifact_status(ok), STAGE8_VALIDATION, observed, expected, notes))
    end

    configuration_rows = read_tsv(STAGE8_MODEL_CONFIGURATION)
    configuration = Dict{Tuple{String,String},String}()
    if !isempty(configuration_rows) && configuration_rows[1] == ["component", "key", "value", "description"]
        for row in configuration_rows[2:end]
            length(row) == 4 || continue
            configuration[(row[1], row[2])] = row[3]
        end
    end
    closure_label = get(configuration, ("closure", "numeraire_label"), "missing")
    closure_kind = get(configuration, ("closure", "numeraire_kind"), "missing")
    closure_ok = closure_label == "P_HH_COMMON" && closure_kind == "price_index"
    push!(rows, artifact_row(
        "08_six_region_bundle",
        "numeraire_configuration",
        artifact_status(closure_ok),
        STAGE8_MODEL_CONFIGURATION,
        "label=$(closure_label); kind=$(closure_kind)",
        "label=P_HH_COMMON; kind=price_index",
        "The calibration bundle must declare the model-defined household-consumption price-index numeraire.",
    ))

    sets_rows = read_simple_csv(joinpath(STAGE8_DIR, "sets.csv"))
    mappings_rows = read_simple_csv(joinpath(STAGE8_DIR, "mappings.csv"))
    subsets_rows = read_simple_csv(joinpath(STAGE8_DIR, "subsets.csv"))

    set_items = Dict{String,Set{String}}()
    for row in sets_rows[2:end]
        set_name = row[1]
        item = row[2]
        if !haskey(set_items, set_name)
            set_items[set_name] = Set{String}()
        end
        push!(set_items[set_name], item)
    end

    mapping_specs = Dict(
        "industry_to_region" => ("industries", "regions"),
        "factor_to_region" => ("factors", "regions"),
        "institution_to_region" => ("institutions", "regions"),
        "external_to_region" => ("externals", "regions"),
        "industry_to_route" => ("industries", "routes"),
        "industry_to_family" => ("industries", "families"),
        "industry_to_regional_family" => ("industries", "regional_families"),
        "industry_to_service_target" => ("industries", "service_targets"),
        "industry_to_eol_target" => ("industries", "eol_targets"),
        "regional_family_to_service_target" => ("regional_families", "service_targets"),
        "regional_family_to_eol_target" => ("regional_families", "eol_targets"),
        "industry_to_material_target" => ("industries", "material_targets"),
    )

    bad_mapping_refs = 0
    unknown_mapping_types = 0
    for row in mappings_rows[2:end]
        map_name = row[1]
        from_item = row[2]
        to_item = row[3]
        if !haskey(mapping_specs, map_name)
            unknown_mapping_types += 1
            continue
        end
        from_set, to_set = mapping_specs[map_name]
        from_ok = haskey(set_items, from_set) && (from_item in set_items[from_set])
        to_ok = haskey(set_items, to_set) && (to_item in set_items[to_set])
        bad_mapping_refs += (!from_ok || !to_ok) ? 1 : 0
    end

    bad_subset_refs = 0
    unknown_subset_parents = 0
    for row in subsets_rows[2:end]
        parent_set = row[2]
        item = row[3]
        if !haskey(set_items, parent_set)
            unknown_subset_parents += 1
            continue
        end
        bad_subset_refs += (item in set_items[parent_set]) ? 0 : 1
    end

    push!(rows, artifact_row(
        "08_six_region_bundle",
        "mapping_reference_integrity",
        artifact_status(bad_mapping_refs == 0 && unknown_mapping_types == 0),
        joinpath(STAGE8_DIR, "mappings.csv"),
        "bad_refs=$(bad_mapping_refs); unknown_map_types=$(unknown_mapping_types)",
        "bad_refs=0; unknown_map_types=0",
        "All mapping rows should reference items that exist in the declared canonical sets.",
    ))
    push!(rows, artifact_row(
        "08_six_region_bundle",
        "subset_reference_integrity",
        artifact_status(bad_subset_refs == 0 && unknown_subset_parents == 0),
        joinpath(STAGE8_DIR, "subsets.csv"),
        "bad_refs=$(bad_subset_refs); unknown_parent_sets=$(unknown_subset_parents)",
        "bad_refs=0; unknown_parent_sets=0",
        "All subset rows should point to an existing parent set and an item declared in that set.",
    ))
end

function artifact_report_rows()
    rows = Vector{Vector{String}}()

    for filename in STAGE1_FILES
        path = joinpath(STAGE1_DIR, filename)
        push!(rows, artifact_row("01_initial_data", filename, artifact_status(isfile(path)), path, isfile(path) ? "present" : "missing", "present", "Required stage-1 source artifact."))
    end

    append_stage_table_status!(rows, "02_integrated_sut", STAGE2_VALIDATION, "integrated_table")
    append_stage_table_status!(rows, "03_final_preparation", STAGE3_VALIDATION, "final_table")
    append_stage4_checks!(rows)
    append_stage4b_checks!(rows)
    append_stage5_checks!(rows)
    append_stage6_checks!(rows)
    append_stage7_checks!(rows)
    append_stage8_checks!(rows)

    return rows
end

function artifact_summary_rows(rows)
    statuses = [row[3] for row in rows]
    n_pass = count(==("PASS"), statuses)
    n_fail = count(==("FAIL"), statuses)
    overall = n_fail == 0 ? "PASS" : "FAIL"
    return [
        ["overall_status", overall],
        ["n_checks", string(length(rows))],
        ["n_pass", string(n_pass)],
        ["n_fail", string(n_fail)],
        ["sut_report_file", REPORT_FILE],
        ["artifact_report_file", ARTIFACT_REPORT_FILE],
    ]
end

function main()
    validations = Vector{Dict{String,Any}}()

    maybe_validate(validations, "manufacturing_supply", "replace", BASE_SUPPLY, MANUFACTURING_SUPPLY, MANUFACTURING_MAP)
    maybe_validate(validations, "manufacturing_use", "replace", BASE_USE, MANUFACTURING_USE, MANUFACTURING_MAP)
    maybe_validate(validations, "intermediate_supply", "augment", BASE_SUPPLY, INTERMEDIATE_SUPPLY, INTERMEDIATE_MAP)
    maybe_validate(validations, "intermediate_use", "augment", BASE_USE, INTERMEDIATE_USE, INTERMEDIATE_MAP)

    write_tsv(
        REPORT_FILE,
        [
            "label",
            "mode",
            "status",
            "base_file",
            "candidate_file",
            "base_total",
            "candidate_total",
            "comparison_total",
            "n_diff",
            "max_abs_diff",
            "sum_abs_diff",
            "n_keys",
        ],
        report_rows(validations),
    )

    artifact_rows = artifact_report_rows()
    write_tsv(
        ARTIFACT_REPORT_FILE,
        ["stage", "check", "status", "source_file", "observed", "expected", "notes"],
        artifact_rows,
    )
    write_tsv(
        ARTIFACT_SUMMARY_FILE,
        ["key", "value"],
        artifact_summary_rows(artifact_rows),
    )

    println("Wrote:")
    println("  ", REPORT_FILE)
    println("  ", ARTIFACT_REPORT_FILE)
    println("  ", ARTIFACT_SUMMARY_FILE)
    println()
    print_summary(validations)
end

main()
