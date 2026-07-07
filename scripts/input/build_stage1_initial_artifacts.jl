#!/usr/bin/env julia

"""
Build the stage-1 initial-data artifact set.

Stage 1 contains:
- the FIGARO reference SUT used as the monetary benchmark,
- the BONSAI-derived entries relevant to the CE-RISE product families and
  circular-route interpretation,
- the minimal mapping files that connect the two sources.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const SUT_DIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")
const FIGARO_DIR = joinpath(ROOT_DIR, "data", "interim", "figaro_2016")
const MAP_DIR = joinpath(ROOT_DIR, "data", "mappings")
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "01_initial_data")

const OVERLAY_FULL = joinpath(SUT_DIR, "sut_disaggregation_overlay.tsv")
const OVERLAY_REGIONS = joinpath(SUT_DIR, "sut_disaggregation_overlay_regions.tsv")
const FIGARO_SUPPLY = joinpath(SUT_DIR, "sut_supply_base_2016.tsv")
const FIGARO_USE = joinpath(SUT_DIR, "sut_use_base_2016.tsv")
const FIGARO_CODE_MAP = joinpath(FIGARO_DIR, "figaro_2016_code_map.tsv")
const REGION_MAP = joinpath(MAP_DIR, "figaro_region_map.tsv")
const PARENT_MAP = joinpath(MAP_DIR, "ce_rise_parent_to_figaro.tsv")
const PARENT_CHILDREN = joinpath(SUT_DIR, "sut_parent_children.tsv")

const CE_RISE_PARENTS = Set(["A_ELMA", "A_OFMA", "A_RATV"])
const CE_RISE_CHILDREN = Set([
    "HPP", "PV", "BAT", "ELMA_c",
    "LAP", "DES", "PRI", "OFMA_c",
    "MOB", "MON", "RATV_c",
])
const FAMILY_MARKETS = Set([
    "M_ELMA", "M_ELMA_c", "M_HPP", "M_PV", "M_BAT",
    "M_OFMA", "M_OFMA_c", "M_LAP", "M_DES", "M_PRI",
    "M_RATV", "M_RATV_c", "M_MOB", "M_MON",
])
const EXACT_CIRCULAR_NODES = Set([
    "A_REPAIR", "A_REP_INST", "A_ORGA|A_PERS_SER|A_REPAIR",
    "M_REPAIR", "M_REP_INST", "M_ORGA|M_PERS_SER|M_REPAIR",
    "A_GLAS_reuse",
])

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

function copy_tsv(infile::AbstractString, outfile::AbstractString)
    rows = read_tsv(infile)
    write_tsv(outfile, rows[1], rows[2:end])
end

function relevant_node(node::AbstractString)
    node in CE_RISE_PARENTS && return true
    node in EXACT_CIRCULAR_NODES && return true
    node in FAMILY_MARKETS && return true

    if startswith(node, "A_") || startswith(node, "C_")
        suffix = node[3:end]
        suffix in CE_RISE_CHILDREN && return true
    end

    occursin(r"^A_.*_RECY$", node) && return true
    occursin(r"^A_.*_INCI", node) && return true
    occursin(r"^A_.*_LAND$", node) && return true
    startswith(node, "M_iw") && return true

    return false
end

function filter_overlay(infile::AbstractString, outfile::AbstractString)
    rows = read_tsv(infile)
    filtered = Vector{Vector{String}}()
    for row in rows[2:end]
        from_node = row[2]
        to_node = row[4]
        (relevant_node(from_node) || relevant_node(to_node)) || continue
        push!(filtered, row)
    end
    write_tsv(outfile, rows[1], filtered)
    return length(filtered)
end

function main()
    ensure_dir(OUTDIR)

    n_full = filter_overlay(OVERLAY_FULL, joinpath(OUTDIR, "bonsai_relevant_overlay_full.tsv"))
    n_regions = filter_overlay(OVERLAY_REGIONS, joinpath(OUTDIR, "bonsai_relevant_overlay_regions.tsv"))

    copy_tsv(FIGARO_SUPPLY, joinpath(OUTDIR, "figaro_reference_supply.tsv"))
    copy_tsv(FIGARO_USE, joinpath(OUTDIR, "figaro_reference_use.tsv"))
    copy_tsv(FIGARO_CODE_MAP, joinpath(OUTDIR, "figaro_reference_code_map.tsv"))
    copy_tsv(REGION_MAP, joinpath(OUTDIR, "figaro_region_map.tsv"))
    copy_tsv(PARENT_MAP, joinpath(OUTDIR, "ce_rise_parent_to_figaro.tsv"))
    copy_tsv(PARENT_CHILDREN, joinpath(OUTDIR, "ce_rise_parent_children.tsv"))

    write_tsv(
        joinpath(OUTDIR, "artifact_summary.tsv"),
        ["artifact", "rows"],
        [
            ["bonsai_relevant_overlay_full.tsv", string(n_full)],
            ["bonsai_relevant_overlay_regions.tsv", string(n_regions)],
        ],
    )

    println("Wrote stage-1 artifacts to ", OUTDIR)
end

main()
