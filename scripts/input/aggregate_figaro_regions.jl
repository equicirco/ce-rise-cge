#!/usr/bin/env julia

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_REGION_MAP = joinpath(ROOT_DIR, "data", "mappings", "figaro_region_map.tsv")
const DEFAULT_RAW_DIR = joinpath(ROOT_DIR, "data", "raw", "figaro_2016_from_fact")
const DEFAULT_OUTDIR = joinpath(ROOT_DIR, "data", "interim", "figaro_2016")

function parse_kv_args(args)
    opts = Dict{String, String}()
    for arg in args
        startswith(arg, "--") || error("Unsupported argument: $arg")
        key, value = occursin("=", arg) ? split(arg[3:end], "=", limit = 2) : (arg[3:end], "true")
        opts[key] = value
    end
    return opts
end

function load_region_map(path)
    mapping = Dict{String, String}()
    open(path, "r") do io
        first = true
        for line in eachline(io)
            first && (first = false; continue)
            isempty(line) && continue
            parts = split(line, '\t')
            length(parts) == 2 || error("Invalid region-map row: $line")
            mapping[parts[1]] = parts[2]
        end
    end
    return mapping
end

function mapped_region(region_map::Dict{String,String}, country::AbstractString)
    haskey(region_map, country) || error("Missing FIGARO region mapping for country $(country)")
    return region_map[String(country)]
end

strip_country_prefix(code) = occursin(':', code) ? split(code, ':', limit = 2)[2] : code

function aggregate_matrix(infile, outfile, region_map)
    totals = Dict{NTuple{4, String}, Float64}()
    open(infile, "r") do io
        first = true
        for line in eachline(io)
            first && (first = false; continue)
            isempty(line) && continue
            row_country, row_code, col_country, col_code, value_text = split(line, '\t')
            row_region = mapped_region(region_map, row_country)
            col_region = mapped_region(region_map, col_country)
            key = (
                row_region,
                strip_country_prefix(row_code),
                col_region,
                strip_country_prefix(col_code),
            )
            totals[key] = get(totals, key, 0.0) + parse(Float64, value_text)
        end
    end

    ordered_keys = sort!(collect(keys(totals)))
    mkpath(dirname(outfile))
    open(outfile, "w") do io
        println(io, "row_region\trow_code\tcol_region\tcol_code\tvalue_meur")
        for key in ordered_keys
            value = totals[key]
            abs(value) <= 1e-12 && continue
            println(io, join((key[1], key[2], key[3], key[4], string(value)), '\t'))
        end
    end
end

function main(args)
    opts = parse_kv_args(args)
    region_map_file = get(opts, "region-map", DEFAULT_REGION_MAP)
    raw_dir = get(opts, "raw-dir", DEFAULT_RAW_DIR)
    outdir = get(opts, "outdir", DEFAULT_OUTDIR)

    region_map = load_region_map(region_map_file)

    aggregate_matrix(
        joinpath(raw_dir, "figaro_2016_supply_raw.tsv"),
        joinpath(outdir, "figaro_2016_supply_regions.tsv"),
        region_map,
    )
    aggregate_matrix(
        joinpath(raw_dir, "figaro_2016_use_raw.tsv"),
        joinpath(outdir, "figaro_2016_use_regions.tsv"),
        region_map,
    )

    println("Wrote:")
    println("  ", joinpath(outdir, "figaro_2016_supply_regions.tsv"))
    println("  ", joinpath(outdir, "figaro_2016_use_regions.tsv"))
end

main(ARGS)
