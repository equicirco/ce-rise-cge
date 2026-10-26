#!/usr/bin/env julia

"""
Extract family production from the V2 archive, DOI 10.5281/zenodo.23342753.

Usage:
    julia scripts/input/import_bonsai_family_outputs.jl [workbook.xlsx]

With no argument, download the archived CE-RISE_D3.2_data.xlsx temporarily.
Only the relevant parent outputs are persisted in data/disaggregation.
The supplied supply/use CSV remains intact. Its other transactions are not
reconstructed from a change in parent production.

The workbook has a fixed SHA-256 checksum. Its Production_result sheet repeats
parent_production across child rows: verify equality and keep each value once.
The XML reader below reads this verified workbook using the system unzip
utility; it does not require adding an Excel package to the model environment.
"""

using Downloads
using SHA

include(joinpath(@__DIR__, "bonsai_family_outputs.jl"))
using .BonsaiFamilyOutputs

const WORKBOOK_URL = "https://zenodo.org/api/records/23342753/files/CE-RISE_D3.2_data.xlsx/content"
const WORKBOOK_SHA256 = "22c391862d92789d930126f287b518e1ee64ae1b31e967dbb4db8cbc069d0b4b"
const SUPPLIED_FILE = normpath(joinpath(
    @__DIR__, "..", "..", "data", "disaggregation",
    "parent_and_disaggregated_rows_sup_and_use.csv",
))

xmltext(s) = replace(s, "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"",
                     "&apos;" => "'", "&amp;" => "&")

function workbook_rows(path)
    checksum = open(sha256, path) |> bytes2hex
    checksum == WORKBOOK_SHA256 || error("Workbook differs from the verified V2 archive: $checksum")
    unzip = Sys.which("unzip")
    unzip === nothing && error("The system unzip utility is required to read the V2 workbook")
    xml(entry) = read(`$unzip -p $path $entry`, String)
    workbook = xml("xl/workbook.xml")
    sheet = match(r"<sheet\b[^>]*\bname=\"Production_result\"[^>]*\br:id=\"([^\"]+)\"", workbook)
    sheet === nothing && error("Missing Production_result worksheet")
    relationships = xml("xl/_rels/workbook.xml.rels")
    target = nothing
    for relationship in eachmatch(r"<Relationship\b[^>]*>", relationships)
        id = match(r"\bId=\"([^\"]+)\"", relationship.match)
        id !== nothing && id.captures[1] == sheet.captures[1] || continue
        target = match(r"\bTarget=\"([^\"]+)\"", relationship.match).captures[1]
    end
    target === nothing && error("Missing worksheet relationship")
    shared = [xmltext(join(t.captures[1] for t in eachmatch(
        r"<t(?:\s[^>]*)?>(.*?)</t>"s, item.captures[1],
    ))) for item in eachmatch(r"<si(?:\s[^>]*)?>(.*?)</si>"s, xml("xl/sharedStrings.xml"))]
    rows = Dict{String,String}[]
    for row in eachmatch(r"<row\b[^>]*>(.*?)</row>"s, xml("xl/" * target))
        cells = Dict{String,String}()
        for cell in eachmatch(r"<c\b([^>]*)>(.*?)</c>"s, row.captures[1])
            column = match(r"\br=\"([A-Z]+)[0-9]+\"", cell.captures[1])
            value = match(r"<v>(.*?)</v>"s, cell.captures[2])
            (column === nothing || value === nothing) && continue
            raw = value.captures[1]
            cells[column.captures[1]] = occursin(r"\bt=\"s\"", cell.captures[1]) ?
                shared[parse(Int, raw) + 1] : xmltext(raw)
        end
        push!(rows, cells)
    end
    return rows
end

function extract_family_outputs(path)
    rows = workbook_rows(path)
    header = Dict(value => column for (column, value) in first(rows))
    all(haskey(header, name) for name in ("parent", "region", "parent_production")) ||
        error("Unexpected Production_result columns")
    outputs = Dict{Tuple{String,String},Float64}()
    for row in rows[2:end]
        family, region, value = (row[header[name]] for name in ("parent", "region", "parent_production"))
        family in ("ELMA", "OFMA", "RATV") || error("Unexpected parent $family")
        tonnes = parse(Float64, value)
        isfinite(tonnes) && tonnes >= 0 || error("Invalid output for $region/$family")
        key = (region, family)
        haskey(outputs, key) && outputs[key] != tonnes &&
            error("Inconsistent repeated parent output for $key")
        outputs[key] = tonnes
    end
    # Pseudo-regions and absent activities have zero parent production. They
    # are not additional observations and do not enter the regional totals.
    filter!(pair -> last(pair) > 0, outputs)
    return outputs
end

function supplied_output_keys(path = SUPPLIED_FILE)
    keys_found = Set{Tuple{String,String}}()
    open(path, "r") do io
        index = Dict(name => i for (i, name) in enumerate(split(readline(io), ',')))
        for line in eachline(io)
            fields = split(line, ',')
            family = output_family((fields[index[name]] for name in (
                "from_node_location", "from_node_name", "to_node_location", "to_node_name", "unit",
            ))...)
            family === nothing && continue
            key = (String(fields[index["from_node_location"]]), family)
            key in keys_found && error("Duplicate supplied parent output: $key")
            push!(keys_found, key)
        end
    end
    return keys_found
end

function import_family_outputs(workbook; outfile = FAMILY_OUTPUT_FILE)
    outputs = extract_family_outputs(workbook)
    Set(keys(outputs)) == supplied_output_keys() ||
        error("V2 positive parent-output coverage differs from the supplied CSV")
    mkpath(dirname(outfile))
    open(outfile, "w") do io
        println(io, "source_country\tfamily\toutput_tonnes")
        for (country, family) in sort!(collect(keys(outputs)))
            println(io, country, '\t', family, '\t', outputs[(country, family)])
        end
    end
    load_family_outputs(outfile) == outputs || error("Family-output round-trip failed")
    println("Imported ", length(outputs), " family outputs from ", SOURCE_DOI, " into ", outfile)
end

function main(args = ARGS)
    length(args) <= 1 || error("Usage: import_bonsai_family_outputs.jl [workbook.xlsx]")
    if isempty(args)
        mktempdir() do dir
            path = Downloads.download(WORKBOOK_URL, joinpath(dir, "CE-RISE_D3.2_data.xlsx"))
            import_family_outputs(path)
        end
    else
        import_family_outputs(only(args))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
