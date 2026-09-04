#!/usr/bin/env julia

"""Report persisted progress for a checkpointed six-region policy grid."""

using CSV
using DataFrames
using CERiseCGE

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const OUTPUT_DIR = joinpath(ROOT_DIR, "results", "policy_sensitivity")
const DEFAULT_OUTPUT_FILE = joinpath(OUTPUT_DIR, "policy_sensitivity_grid.csv")

function output_file(args)
    isempty(args) && return DEFAULT_OUTPUT_FILE
    length(args) == 2 && first(args) == "--output" &&
        return normpath(joinpath(ROOT_DIR, last(args)))
    error("Usage: julia --project=. scripts/analysis/policy_sensitivity_status.jl [--output PATH]")
end

function checkpoint_dir(path::AbstractString)
    stem = splitext(basename(path))[1]
    return joinpath(dirname(path), "$(stem)_checkpoints")
end

status_rows(tables::Vector{DataFrame}) = isempty(tables) ? DataFrame() :
    vcat(tables...; cols=:union)

function main()
    path = output_file(ARGS)
    directory = checkpoint_dir(path)
    profiles = sensitivity_profiles(default_calibration_bundle())
    isdir(directory) || begin
        println("No checkpoint directory exists yet: ", directory)
        return nothing
    end
    status_paths = Dict(
        replace(basename(file), ".status.csv" => "") => joinpath(directory, file)
        for file in readdir(directory; join=false)
        if endswith(file, ".status.csv")
    )
    completed = 0
    running = DataFrame[]
    failed = DataFrame[]
    for profile in profiles
        name = String(profile.name)
        haskey(status_paths, name) || continue
        status = DataFrame(CSV.File(status_paths[name]))
        state = only(String.(status.state))
        state == "completed" && (completed += 1)
        state == "running" && push!(running, status)
        state == "failed" && push!(failed, status)
    end
    running_rows = status_rows(running)
    failed_rows = status_rows(failed)
    println("Profiles: ", length(profiles))
    println("Completed: ", completed)
    println("Running: ", nrow(running_rows))
    println("Failed: ", nrow(failed_rows))
    println("Pending: ", length(profiles) - completed - nrow(running_rows) - nrow(failed_rows))
    isempty(running) || begin
        println("\nActive profiles:")
        show(stdout, running_rows; allrows=true, allcols=true)
        println()
    end
    isempty(failed) || begin
        println("\nFailed profiles:")
        show(stdout, failed_rows; allrows=true, allcols=true)
        println()
    end
end

main()
