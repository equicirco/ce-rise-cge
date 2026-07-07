#!/usr/bin/env julia

"""
Prepare the first SUT workspace for `ce-rise-cge`.

Relevant methodological information is intentionally kept here in code, not in
the data directories.

Current benchmark:
- FIGARO 2016
- regions kept individually: DE, FR, PL, IT, SK
- all remaining countries aggregated into ROW

Current CE-RISE disaggregation:
- A_ELMA -> HPP, PV, BAT, ELMA_c
- A_OFMA -> LAP, DES, PRI, OFMA_c
- A_RATV -> MOB, MON, RATV_c

Node prefixes in the collaborator data:
- C_: commodity
- A_: activity
- M_: market

Important:
- the collaborator disaggregation overlay is not globally balanced on its own
- it must be applied to a full monetary SUT base
- balancing comes after the overlay is mapped into the monetary layer

This script does not yet do the final balancing. It prepares:
1. normalized regional FIGARO supply and use tables
2. a cleaned CE-RISE disaggregation overlay
3. simple summaries needed for the next SUT-disaggregation step
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const FIGARO_DIR = joinpath(ROOT_DIR, "data", "interim", "figaro_2016")
const DISAGG_DIR = joinpath(ROOT_DIR, "data", "disaggregation")
const OUTDIR = joinpath(ROOT_DIR, "data", "interim", "sut_2016")

const PARENT_TO_CHILDREN = Dict(
    "A_ELMA" => ["HPP", "PV", "BAT", "ELMA_c"],
    "A_OFMA" => ["LAP", "DES", "PRI", "OFMA_c"],
    "A_RATV" => ["MOB", "MON", "RATV_c"],
)

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
end

function read_tabular_lines(path::AbstractString; expected_columns::Int)
    rows = Vector{Vector{String}}()
    open(path, "r") do io
        for line in eachline(io)
            isempty(line) && continue
            parts = split(line, '\t')
            length(parts) == expected_columns || error("Unexpected column count in $(path): $(length(parts))")
            push!(rows, parts)
        end
    end
    return rows
end

function write_lines(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(header, '\t'))
        for row in rows
            println(io, join(row, '\t'))
        end
    end
end

function normalize_figaro_supply()
    infile = joinpath(FIGARO_DIR, "figaro_2016_supply_regions.tsv")
    rows = read_tabular_lines(infile; expected_columns = 5)
    outfile = joinpath(OUTDIR, "sut_supply_base_2016.tsv")
    data = rows[2:end]
    write_lines(outfile, ["product_region", "product_code", "activity_region", "activity_code", "value_meur"], data)
    return outfile, length(data)
end

function normalize_figaro_use()
    infile = joinpath(FIGARO_DIR, "figaro_2016_use_regions.tsv")
    rows = read_tabular_lines(infile; expected_columns = 5)
    outfile = joinpath(OUTDIR, "sut_use_base_2016.tsv")
    data = rows[2:end]
    write_lines(outfile, ["product_region", "product_code", "use_region", "use_code", "value_meur"], data)
    return outfile, length(data)
end

function parse_csv_line(line::AbstractString)
    return split(chomp(line), ',')
end

function normalize_disaggregation_overlay()
    infile = joinpath(DISAGG_DIR, "parent_and_disaggregated_rows_sup_and_use.csv")
    outfile = joinpath(OUTDIR, "sut_disaggregation_overlay.tsv")
    unit_summary = Dict{String, Int}()
    row_count = 0

    open(infile, "r") do input
        header = parse_csv_line(readline(input))
        idx = Dict(name => i for (i, name) in enumerate(header))

        required = [
            "from_node_location",
            "from_node_name",
            "to_node_location",
            "to_node_name",
            "unit",
            "value",
        ]
        for name in required
            haskey(idx, name) || error("Missing required column $(name) in $(infile)")
        end

        open(outfile, "w") do output
            println(output, "from_country\tfrom_node\tto_country\tto_node\tunit\tvalue")
            for line in eachline(input)
                isempty(line) && continue
                fields = parse_csv_line(line)
                from_country = fields[idx["from_node_location"]]
                from_node = fields[idx["from_node_name"]]
                to_country = fields[idx["to_node_location"]]
                to_node = fields[idx["to_node_name"]]
                unit = fields[idx["unit"]]
                value = fields[idx["value"]]
                println(output, join([from_country, from_node, to_country, to_node, unit, value], '\t'))
                unit_summary[unit] = get(unit_summary, unit, 0) + 1
                row_count += 1
            end
        end
    end

    summary_rows = [String[unit, string(count)] for (unit, count) in sort(collect(unit_summary), by = x -> x[1])]
    write_lines(joinpath(OUTDIR, "sut_disaggregation_units.tsv"), ["unit", "rows"], summary_rows)

    return outfile, row_count
end

function write_parent_children_table()
    rows = Vector{Vector{String}}()
    for parent in sort(collect(keys(PARENT_TO_CHILDREN)))
        for child in PARENT_TO_CHILDREN[parent]
            push!(rows, [parent, child])
        end
    end
    outfile = joinpath(OUTDIR, "sut_parent_children.tsv")
    write_lines(outfile, ["parent_sector", "child_sector"], rows)
    return outfile
end

function main()
    ensure_dir(OUTDIR)

    supply_out, supply_n = normalize_figaro_supply()
    use_out, use_n = normalize_figaro_use()
    overlay_out, overlay_n = normalize_disaggregation_overlay()
    parent_children_out = write_parent_children_table()

    println("Prepared SUT workspace:")
    println("  ", supply_out, "  rows=", supply_n)
    println("  ", use_out, "     rows=", use_n)
    println("  ", overlay_out, "  rows=", overlay_n)
    println("  ", parent_children_out)
    println()
    println("Next step: map the CE-RISE parent sectors onto the FIGARO 2016 base SUT")
    println("and then apply the disaggregation overlay before balancing the monetary SUT.")
end

main()
