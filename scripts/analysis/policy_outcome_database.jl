module PolicyOutcomeDatabase

using DataFrames
using DBInterface
using DuckDB

const OUTCOME_TABLE = "policy_outcomes"
const POLICY_POINT_TABLE = "policy_points"

"""Return a copy with symbolic labels converted to database strings."""
function database_table(table::DataFrame)
    converted = copy(table)
    for name in names(converted)
        column = converted[!, name]
        any(value -> value isa Symbol, skipmissing(column)) || continue
        converted[!, name] = Union{Missing,String}[
            ismissing(value) ? missing : string(value)
            for value in column
        ]
    end
    return converted
end

function _create_table!(connection, name::AbstractString, table::DataFrame)
    nrow(table) > 0 || error("Cannot create $(name) from an empty table.")
    DuckDB.register_table(connection, table, "incoming")
    try
        DBInterface.execute(connection,
            "CREATE TABLE $(name) AS SELECT * FROM incoming")
    finally
        DuckDB.unregister_table(connection, "incoming")
    end
    return nothing
end

"""
    create_database(path, policy_points)

Create a new DuckDB results database containing the declared policy-point
table. The database path must not already exist; this prevents an incomplete
or unrelated outcome store from being overwritten.
"""
function create_database(path::AbstractString, policy_points::DataFrame)
    ispath(path) && error("Refusing to overwrite existing outcome database: $(path)")
    mkpath(dirname(path))
    database = DuckDB.DB(path)
    connection = DBInterface.connect(database)
    try
        _create_table!(connection, POLICY_POINT_TABLE, database_table(policy_points))
    catch
        DBInterface.close!(connection)
        close(database)
        rethrow()
    end
    return (database = database, connection = connection)
end

"""Append detailed outcomes for one or more solved policy points."""
function append_outcomes!(store, outcomes::DataFrame)
    nrow(outcomes) > 0 || return store
    incoming = database_table(outcomes)
    connection = store.connection
    tables = DataFrame(DBInterface.execute(connection,
        "SELECT table_name FROM information_schema.tables " *
        "WHERE table_schema = 'main' AND table_name = '$(OUTCOME_TABLE)'"))
    if isempty(tables)
        _create_table!(connection, OUTCOME_TABLE, incoming)
    else
        DuckDB.register_table(connection, incoming, "incoming")
        try
            DBInterface.execute(connection,
                "INSERT INTO $(OUTCOME_TABLE) SELECT * FROM incoming")
        finally
            DuckDB.unregister_table(connection, "incoming")
        end
    end
    return store
end

"""Return compact counts from an open or persisted policy-outcome database."""
function database_summary(connection)
    policy_points = DataFrame(DBInterface.execute(connection,
        "SELECT count(*) AS policy_points FROM $(POLICY_POINT_TABLE)"))
    outcome_tables = DataFrame(DBInterface.execute(connection,
        "SELECT count(*) AS present FROM information_schema.tables " *
        "WHERE table_schema = 'main' AND table_name = '$(OUTCOME_TABLE)'"))
    outcome_rows = outcome_tables.present[1] == 0 ? 0 : only(DataFrame(
        DBInterface.execute(connection,
            "SELECT count(*) AS outcome_rows FROM $(OUTCOME_TABLE)")).outcome_rows)
    return (
        policy_points = only(policy_points.policy_points),
        outcome_rows = outcome_rows,
    )
end

function close_database!(store)
    DBInterface.close!(store.connection)
    close(store.database)
    return nothing
end

end
