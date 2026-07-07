#!/usr/bin/env julia

"""
Extract CE-RISE family-specific circular-route anchor flows from the regional
overlay.

This script does not construct final benchmark accounts yet. It summarizes the
empirical evidence available in the BONSAI-derived overlay for:
- route inflows from family product-market nodes into circular activities,
- service and waste-management inputs from circular-service nodes into family
  activities.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const INFILE = joinpath(ROOT_DIR, "data", "interim", "sut_2016", "sut_disaggregation_overlay_regions.tsv")
const OUTDIR = joinpath(ROOT_DIR, "data", "interim", "structure")

const FAMILY_MARKETS = Dict(
    "ELMA" => Set(["M_ELMA", "M_ELMA_c", "M_HPP", "M_PV", "M_BAT"]),
    "OFMA" => Set(["M_OFMA", "M_OFMA_c", "M_LAP", "M_DES", "M_PRI"]),
    "RATV" => Set(["M_RATV", "M_RATV_c", "M_MOB", "M_MON"]),
)

const FAMILY_ACTIVITIES = Dict(
    "ELMA" => Set(["A_ELMA", "A_ELMA_c", "A_HPP", "A_PV", "A_BAT"]),
    "OFMA" => Set(["A_OFMA", "A_OFMA_c", "A_LAP", "A_DES", "A_PRI"]),
    "RATV" => Set(["A_RATV", "A_RATV_c", "A_MOB", "A_MON"]),
)

function ensure_dir(path::AbstractString)
    isdir(path) || mkpath(path)
end

function write_tsv(path::AbstractString, header::Vector{String}, rows::Vector{Vector{String}})
    open(path, "w") do io
        println(io, join(header, '\t'))
        for row in rows
            println(io, join(row, '\t'))
        end
    end
end

function route_activity_category(node::AbstractString)
    node == "A_REPAIR" && return "repair"
    node == "A_REP_INST" && return "repair_installation"
    node == "A_ORGA|A_PERS_SER|A_REPAIR" && return "repair_combined_services"
    node == "A_GLAS_reuse" && return "reuse_proxy"
    occursin(r"^A_.*_RECY$", node) && return "recycling"
    occursin(r"^A_.*_INCI", node) && return "incineration"
    occursin(r"^A_.*_LAND$", node) && return "landfill"
    return nothing
end

function circular_service_category(node::AbstractString)
    node == "M_REPAIR" && return "repair_service_market"
    node == "M_REP_INST" && return "repair_installation_market"
    node == "M_ORGA|M_PERS_SER|M_REPAIR" && return "repair_combined_service_market"
    startswith(node, "M_iw") && return "industrial_waste_service_market"
    return nothing
end

function family_for_market(node::AbstractString)
    for (family, nodes) in FAMILY_MARKETS
        node in nodes && return family
    end
    return nothing
end

function family_for_activity(node::AbstractString)
    for (family, nodes) in FAMILY_ACTIVITIES
        node in nodes && return family
    end
    return nothing
end

function main()
    ensure_dir(OUTDIR)

    route_inflows = Dict{NTuple{7,String},Float64}()
    service_inputs = Dict{NTuple{7,String},Float64}()

    open(INFILE, "r") do io
        readline(io)
        for line in eachline(io)
            isempty(line) && continue
            from_region, from_node, to_region, to_node, unit, value_str = split(line, '\t')
            value = parse(Float64, value_str)

            family_from = family_for_market(from_node)
            route_category = route_activity_category(to_node)
            if !isnothing(family_from) && !isnothing(route_category)
                key = (from_region, family_from, route_category, from_node, to_node, unit, "")
                route_inflows[key] = get(route_inflows, key, 0.0) + value
            end

            service_category = circular_service_category(from_node)
            family_to = family_for_activity(to_node)
            if !isnothing(service_category) && !isnothing(family_to)
                key = (from_region, family_to, service_category, from_node, to_node, unit, "")
                service_inputs[key] = get(service_inputs, key, 0.0) + value
            end
        end
    end

    route_rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(route_inflows)))
        push!(route_rows, [key[1], key[2], key[3], key[4], key[5], key[6], string(route_inflows[key])])
    end

    service_rows = Vector{Vector{String}}()
    for key in sort!(collect(keys(service_inputs)))
        push!(service_rows, [key[1], key[2], key[3], key[4], key[5], key[6], string(service_inputs[key])])
    end

    route_file = joinpath(OUTDIR, "circular_route_anchor_inflows.tsv")
    service_file = joinpath(OUTDIR, "circular_route_service_inputs.tsv")

    write_tsv(
        route_file,
        ["region", "family", "route_category", "from_market_node", "to_activity_node", "unit", "value"],
        route_rows,
    )
    write_tsv(
        service_file,
        ["region", "family", "service_category", "from_service_node", "to_activity_node", "unit", "value"],
        service_rows,
    )

    println("Wrote:")
    println("  ", route_file)
    println("  ", service_file)
end

main()
