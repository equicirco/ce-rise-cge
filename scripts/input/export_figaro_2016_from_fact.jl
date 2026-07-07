#!/usr/bin/env julia

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_OUTDIR = joinpath(ROOT_DIR, "data", "raw", "figaro_2016_from_fact")
const DEFAULT_CONTAINER = "fact_national_io_tables"
const DEFAULT_DB = "FACT_national_io_tables"
const DEFAULT_USER = "root"
const DEFAULT_PASSWORD = "devops"
const DEFAULT_YEAR = "2016"

function parse_kv_args(args)
    opts = Dict{String, String}()
    for arg in args
        startswith(arg, "--") || error("Unsupported argument: $arg")
        key, value = occursin("=", arg) ? split(arg[3:end], "=", limit = 2) : (arg[3:end], "true")
        opts[key] = value
    end
    return opts
end

function podman_query(container, db, user, password, sql)
    cmd = `podman exec $container mariadb -N -B -u$user -p$password -e $sql $db`
    return read(cmd, String)
end

function stream_podman_query(io, container, db, user, password, sql)
    cmd = `podman exec $container mariadb -N -B -u$user -p$password -e $sql $db`
    open(cmd, "r") do proc
        while !eof(proc)
            write(io, readavailable(proc))
        end
    end
end

function write_query(outfile, header, container, db, user, password, sql)
    mkpath(dirname(outfile))
    open(outfile, "w") do io
        println(io, header)
        stream_podman_query(io, container, db, user, password, sql)
    end
end

function main(args)
    opts = parse_kv_args(args)
    outdir = get(opts, "outdir", DEFAULT_OUTDIR)
    container = get(opts, "container", DEFAULT_CONTAINER)
    db = get(opts, "db", DEFAULT_DB)
    user = get(opts, "user", DEFAULT_USER)
    password = get(opts, "password", DEFAULT_PASSWORD)
    year = get(opts, "year", DEFAULT_YEAR)

    supply_sql = """
        SELECT
            RowCountry,
            RowCode,
            ColCountry,
            ColCode,
            CAST(DataValue AS CHAR)
        FROM NATIONAL_IO_CELLS
        WHERE SourceAgency = 'Eurostat'
          AND Country = 'FIGARO'
          AND SourceDataset = 'NAIO_10_F'
          AND SourceTableID = 'NAIO_10_FCP_S2:MIO_EUR'
          AND Year = $year
          AND DataValue IS NOT NULL;
    """

    use_sql = """
        SELECT
            RowCountry,
            RowCode,
            ColCountry,
            ColCode,
            CAST(DataValue AS CHAR)
        FROM NATIONAL_IO_CELLS
        WHERE SourceAgency = 'Eurostat'
          AND Country = 'FIGARO'
          AND SourceDataset = 'NAIO_10_F'
          AND SourceTableID = 'NAIO_10_FCP_U2:MIO_EUR'
          AND Year = $year
          AND DataValue IS NOT NULL;
    """

    code_map_sql = """
        SELECT
            CodeSystem,
            Code,
            Description
        FROM NATIONAL_IO_CODE_MAP
        WHERE SourceAgency = 'Eurostat'
          AND Country = 'FIGARO'
          AND SourceDataset = 'NAIO_10_F'
          AND CodeSystem IN ('cpa2_1', 'nace_r2', 'prd_ava', 'ind_use')
        ORDER BY CodeSystem, Code;
    """

    write_query(
        joinpath(outdir, "figaro_2016_supply_raw.tsv"),
        "row_country\trow_code\tcol_country\tcol_code\tvalue_meur",
        container,
        db,
        user,
        password,
        supply_sql,
    )
    write_query(
        joinpath(outdir, "figaro_2016_use_raw.tsv"),
        "row_country\trow_code\tcol_country\tcol_code\tvalue_meur",
        container,
        db,
        user,
        password,
        use_sql,
    )
    write_query(
        joinpath(outdir, "figaro_2016_code_map.tsv"),
        "code_system\tcode\tdescription",
        container,
        db,
        user,
        password,
        code_map_sql,
    )

    println("Wrote:")
    println("  ", joinpath(outdir, "figaro_2016_supply_raw.tsv"))
    println("  ", joinpath(outdir, "figaro_2016_use_raw.tsv"))
    println("  ", joinpath(outdir, "figaro_2016_code_map.tsv"))
end

main(ARGS)
