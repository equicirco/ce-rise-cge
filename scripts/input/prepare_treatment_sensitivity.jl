#!/usr/bin/env julia

"""
Prepare one-at-a-time treatment-calibration checks at unitary behavioural elasticities.

Run `julia --project=. scripts/input/prepare_treatment_sensitivity.jl` to write
case-specific configurations and treatment shares under
`data/interim/treatment_sensitivity/`. These are calibration inputs, not new
physical observations. Each case must pass through SUT balancing and SAM
construction before comparing policy outcomes with its own zero-policy solution.
The script performs no balancing or model solves and preserves the main inputs.
"""

include(joinpath(@__DIR__, "discarded_equipment_treatment.jl"))
using .DiscardedEquipmentTreatment

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const MAPPING_DIR = joinpath(ROOT_DIR, "data", "mappings")
const CASE_FILE = joinpath(MAPPING_DIR, "treatment_sensitivity_grid.tsv")
const CONFIGURATION_FILE = joinpath(MAPPING_DIR, "treatment_allocation.tsv")
const DEFAULT_OUTDIR = joinpath(ROOT_DIR, "data", "interim", "treatment_sensitivity")

function treatment_sensitivity_cases(path = CASE_FILE)
    lines = readlines(path)
    split(first(lines), '\t') == ["case", "changed_assumption", "zero_disposal_share", "disposal_cost_ratio"] ||
        error("Unexpected treatment-sensitivity header")
    baseline = treatment_configuration()
    cases = NamedTuple[]
    names = Set{String}()
    for line in lines[2:end]
        fields = split(line, '\t')
        length(fields) == 4 || error("Malformed treatment-sensitivity case")
        name, changed = String.(fields[1:2])
        occursin(r"^[a-z][a-z0-9_]*$", name) || error("Invalid treatment-sensitivity name")
        name in names && error("Duplicate treatment-sensitivity case")
        push!(names, name)
        seed, cost = parse.(Float64, fields[3:4])
        isfinite(seed) && 0 < seed < 1 || error("Invalid disposal seed")
        isfinite(cost) && cost > 0 || error("Invalid relative treatment cost")
        differences = String[]
        seed == baseline["zero_disposal_share"] || push!(differences, "zero_disposal_share")
        cost == baseline["disposal_cost_ratio"] || push!(differences, "disposal_cost_ratio")
        if name == "reference"
            isempty(differences) && changed == "none" || error("Reference differs from the declared calibration")
        else
            length(differences) == 1 && only(differences) == changed ||
                error("Each treatment check must change exactly one declared assumption")
        end
        push!(cases, (name=name, changed_assumption=changed,
            zero_disposal_share=seed, disposal_cost_ratio=cost))
    end
    count(case -> case.name == "reference", cases) == 1 || error("A reference case is required")
    return cases
end

function prepare_treatment_sensitivity(outdir = DEFAULT_OUTDIR)
    cases = treatment_sensitivity_cases()
    configuration_lines = readlines(CONFIGURATION_FILE)
    mkpath(outdir)
    for case in cases
        case_dir = joinpath(outdir, case.name)
        mkpath(case_dir)
        open(joinpath(case_dir, "treatment_configuration.tsv"), "w") do io
            println(io, first(configuration_lines))
            for line in configuration_lines[2:end]
                fields = String.(split(line, '\t'))
                fields[1] == "zero_disposal_share" && (fields[2] = string(case.zero_disposal_share))
                fields[1] == "disposal_cost_ratio" && (fields[2] = string(case.disposal_cost_ratio))
                println(io, join(fields, '\t'))
            end
        end
        rows = treatment_shares(; zero_disposal_share=case.zero_disposal_share,
            disposal_cost_ratio=case.disposal_cost_ratio)
        write_treatment_shares(joinpath(case_dir, "treatment_shares.tsv"), rows)
    end
    cp(CASE_FILE, joinpath(outdir, "design.tsv"); force=true)
    cp(joinpath(MAPPING_DIR, "policy_wedge_grid.tsv"),
        joinpath(outdir, "policy_wedge_grid.tsv"); force=true)
    # Use the shared behavioural design, fixing each parameter at one.
    grid = [split(line, '\t') for line in readlines(joinpath(MAPPING_DIR, "sensitivity_parameter_grid.tsv"))[2:end]]
    keys = unique([(String(row[1]), String(row[2])) for row in grid])
    open(joinpath(outdir, "behavioural_profile.tsv"), "w") do io
        println(io, "component\tkey\tvalue")
        for (component, key) in keys
            any(row -> row[1] == component && row[2] == key && parse(Float64, row[4]) == 1.0, grid) ||
                error("Unitary value is missing from the declared behavioural design")
            println(io, join((component, key, "1.0"), '\t'))
        end
    end
    return cases
end

function main(args = ARGS)
    outdir = isempty(args) ? DEFAULT_OUTDIR :
        length(args) == 2 && args[1] == "--output-dir" ? abspath(args[2]) :
        error("Usage: prepare_treatment_sensitivity.jl [--output-dir PATH]")
    cases = prepare_treatment_sensitivity(outdir)
    println("Prepared $(length(cases)) treatment-calibration input cases in $outdir")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
