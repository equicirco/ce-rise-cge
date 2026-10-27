module RunCheckpoints

using CSV
using DataFrames
using CERiseCGE

function input_signature(root, bundle)
    paths = [joinpath(root, "Project.toml"), joinpath(root, "Manifest.toml")]
    for directory in (joinpath(root, "src"), joinpath(root, "scripts", "analysis"))
        for (dir, _, files) in walkdir(directory), file in files
            endswith(file, ".jl") && push!(paths, joinpath(dir, file))
        end
    end
    append!(paths, filter(isfile, readdir(bundle.dir; join=true)))
    sort!(unique!(paths))
    table = DataFrame(file=relpath.(paths, Ref(root)), sha256=CERiseCGE._file_digest.(paths))
    push!(table, ("julia_version", string(VERSION)))
    return table
end

function verify_run!(directory, signature)
    manifest = joinpath(directory, "run_inputs.csv")
    if isfile(manifest)
        isequal(CSV.read(manifest, DataFrame), signature) ||
            error("Saved results use different model code, calibration inputs or Julia version. Use a separate empty result directory.")
    else
        isdir(directory) && !isempty(readdir(directory)) &&
            error("The result directory is not empty and has no verified run-input record.")
        mkpath(directory)
        CERiseCGE._write_atomic_csv(manifest, signature)
    end
    return manifest
end

end
