function write_rows_csv(path::AbstractString, rows)
    CSV.write(path, DataFrame(rows))
    return path
end
