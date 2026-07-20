#!/usr/bin/env julia

"""
Build the stage-7 circular-economy model templates.

This stage does not yet calibrate or solve a JCGE model. It fixes the
route structure that mirrors the stylized circular CGE model and prepares the
physical-bridge templates later instantiated in every model region.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const OUTDIR = joinpath(ROOT_DIR, "data", "artifacts", "07_model_scaffold")
const FINAL_SECTOR_REGISTRY = joinpath(ROOT_DIR, "data", "mappings", "final_sector_registry.tsv")

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

function write_key_value_tsv(path::AbstractString, pairs::Vector{Tuple{String,String}})
    open(path, "w") do io
        println(io, "key\tvalue")
        for (key, value) in pairs
            println(io, key, '\t', value)
        end
    end
end

function load_final_sector_registry()
    rows = read_tsv(FINAL_SECTOR_REGISTRY)
    header = rows[1]
    idx = Dict(name => i for (i, name) in enumerate(header))
    return Dict(
        row[idx["sector_id"]] => Dict(
            "sector_label" => row[idx["sector_label"]],
            "paper_observability" => row[idx["paper_observability"]],
            "notes" => row[idx["notes"]],
        )
        for row in rows[2:end]
    )
end

function family_definitions()
    return [
        (
            family = "ELMA",
            family_label = "Electrical machinery and apparatus",
            service_account = "TST_ELMA",
            eol_account = "EOL_ELMA",
            new_route = "NEW_ELMA",
            repair_route = "REP_ELMA",
            refurbishment_route = "REF_ELMA",
            reuse_route = "REU_ELMA",
        ),
        (
            family = "OFMA",
            family_label = "Office machinery and computers",
            service_account = "TST_OFMA",
            eol_account = "EOL_OFMA",
            new_route = "NEW_OFMA",
            repair_route = "REP_OFMA",
            refurbishment_route = "REF_OFMA",
            reuse_route = "REU_OFMA",
        ),
        (
            family = "RATV",
            family_label = "Radio, television and communication equipment",
            service_account = "TST_RATV",
            eol_account = "EOL_RATV",
            new_route = "NEW_RATV",
            repair_route = "REP_RATV",
            refurbishment_route = "REF_RATV",
            reuse_route = "REU_RATV",
        ),
    ]
end

function family_rows()
    return [
        [
            fam.family,
            fam.family_label,
            fam.service_account,
            fam.eol_account,
            fam.new_route,
            fam.repair_route,
            fam.refurbishment_route,
            fam.reuse_route,
            "REC_EE",
            "INC_EE",
            "METAL",
            "BASIC_METALS;REC_EE;interregional_and_extra_european_imports",
            "BASIC_METALS",
            "NEW;REF;REP;REU",
            "REF;REP;REU;REC;INC",
            "CES(NEW,REF,REP,REU)",
            "Stylized-model-consistent family structure with one service composite per CE-RISE family in each model region.",
        ]
        for fam in family_definitions()
    ]
end

function route_rows(final_registry)
    rows = Vector{Vector{String}}()

    function obs(route_id::String)
        return get(get(final_registry, route_id, Dict{String,String}()), "paper_observability", "")
    end

    for fam in family_definitions()
        push!(rows, [
            fam.family,
            fam.family_label,
            "NEW",
            "service_supply",
            fam.service_account,
            fam.eol_account,
            fam.new_route,
            fam.new_route,
            "NEW",
            obs(fam.new_route),
            "primary_metal_tax (supply-side)",
            "METAL_input",
            "own_route_price",
            fam.new_route,
            "New product route supplying the family-specific service composite.",
        ])
        push!(rows, [
            fam.family,
            fam.family_label,
            "REF",
            "service_supply",
            fam.service_account,
            fam.eol_account,
            fam.refurbishment_route,
            fam.refurbishment_route,
            "REF",
            obs(fam.refurbishment_route),
            "refurbishment_support",
            "METAL_parts_plus_eol_input",
            "own_route_price",
            fam.refurbishment_route,
            "Refurbishment route kept comparable with the stylized model as a service-supplying life-extension activity using end-of-life inflows.",
        ])
        push!(rows, [
            fam.family,
            fam.family_label,
            "REP",
            "service_supply",
            fam.service_account,
            fam.eol_account,
            fam.repair_route,
            fam.repair_route,
            "REP",
            obs(fam.repair_route),
            "repair_support",
            "METAL_parts_plus_eol_input",
            "own_route_price",
            fam.repair_route,
            "Repair route kept explicit and family specific.",
        ])
        push!(rows, [
            fam.family,
            fam.family_label,
            "REU",
            "service_supply",
            fam.service_account,
            fam.eol_account,
            fam.reuse_route,
            fam.reuse_route,
            "REU",
            obs(fam.reuse_route),
            "reuse_support",
            "negligible_or_zero_METAL_plus_eol_input",
            "own_route_price",
            fam.reuse_route,
            "Reuse route supplying the service composite through second-life product provision.",
        ])
        push!(rows, [
            fam.family,
            fam.family_label,
            "REC",
            "eol_recovery",
            "",
            fam.eol_account,
            "REC_EE",
            "METAL",
            "REC",
            obs("REC_EE"),
            "recycling_support",
            "produces_METAL",
            "common_METAL_price",
            "REC_EE",
            "Family-specific end-of-life flows can be allocated to the common recycling activity, whose output supplies the single METAL commodity.",
        ])
        push!(rows, [
            fam.family,
            fam.family_label,
            "INC",
            "eol_disposal",
            "",
            fam.eol_account,
            "INC_EE",
            "INC_EE",
            "INC",
            obs("INC_EE"),
            "none",
            "disposal_sink",
            "disposal_price",
            "INC_EE",
            "Family-specific end-of-life flows can be allocated to the common disposal activity.",
        ])
    end

    return rows
end

function quantity_bridge_rows()
    rows = Vector{Vector{String}}()

    for fam in family_definitions()
        for (component, account, unit, source, notes) in [
            ("service_output", fam.service_account, "service_unit", "family-level use, stock, or turnover evidence", "Benchmark service quantity for the family-specific service composite."),
            ("new_route_output", fam.new_route, "product_unit", "observed benchmark output and product counts", "Benchmark quantity of newly produced CE-RISE products."),
            ("repair_route_output", fam.repair_route, "product_unit", "repair-event counts and benchmark route output", "Repair quantity anchor; can also be expressed as repaired units."),
            ("refurbishment_route_output", fam.refurbishment_route, "product_unit", "constructed route output and refurbishment-unit estimate", "Refurbishment quantity anchor."),
            ("reuse_route_output", fam.reuse_route, "product_unit", "constructed route output and second-life unit estimate", "Reuse quantity anchor."),
            ("end_of_life_flow", fam.eol_account, "product_unit", "retirement or discard estimate by family", "Benchmark end-of-life flow entering route allocation."),
        ]
            push!(rows, [
                string(fam.family, "_", component),
                fam.family,
                account,
                component,
                account,
                source,
                unit,
                string("P_", account),
                "benchmark_unit_value = benchmark_value / benchmark_physical_quantity",
                "Q_t = Q0 * q_t using the model quantity index for the linked account",
                "If only value outputs are exported, recover quantity as value_t / (benchmark_unit_value * relative_price_t)",
                "template",
                notes,
            ])
        end
    end

    for row in [
        [
            "METAL_common_market",
            "ALL",
            "METAL",
            "metal_supply",
            "METAL",
            "basic-metal production, recycling output, and interregional or extra-European imports",
            "kg_metal",
            "P_METAL",
            "benchmark_unit_value = benchmark_value / benchmark_physical_quantity",
            "Q_t = Q0 * q_t using the common METAL quantity index",
            "If only value outputs are exported, recover quantity as value_t / (benchmark_unit_value * relative_price_t)",
            "template",
            "Single metal commodity supplied by primary production, recycling, and trade.",
        ],
        [
            "REC_EE_recycling_throughput",
            "ALL",
            "REC_EE",
            "recycling_throughput",
            "REC_EE",
            "end-of-life mass routed to recycling",
            "kg_eol",
            "P_REC_EE",
            "benchmark_unit_value = benchmark_value / benchmark_physical_quantity",
            "Q_t = Q0 * q_t using the recycling-activity quantity index",
            "If only value outputs are exported, recover quantity as value_t / (benchmark_unit_value * relative_price_t)",
            "template",
            "Physical throughput of end-of-life material sent to recycling.",
        ],
        [
            "INC_EE_disposal_throughput",
            "ALL",
            "INC_EE",
            "disposal_throughput",
            "INC_EE",
            "end-of-life mass routed to disposal",
            "kg_eol",
            "P_INC_EE",
            "benchmark_unit_value = benchmark_value / benchmark_physical_quantity",
            "Q_t = Q0 * q_t using the disposal-activity quantity index",
            "If only value outputs are exported, recover quantity as value_t / (benchmark_unit_value * relative_price_t)",
            "template",
            "Physical throughput of end-of-life material sent to incineration or landfill.",
        ],
    ]
        push!(rows, row)
    end

    return rows
end

function coefficient_rows()
    rows = Vector{Vector{String}}()

    for fam in family_definitions()
        for (route, parameter, unit, notes) in [
            ("NEW", string("alpha_new_", lowercase(fam.family)), "kg_metal_per_product_unit", "Metal intensity of new production."),
            ("REF", string("alpha_ref_", lowercase(fam.family)), "kg_metal_per_product_unit", "Replacement-parts metal intensity of refurbishment."),
            ("REP", string("alpha_rep_", lowercase(fam.family)), "kg_metal_per_product_unit", "Replacement-parts metal intensity of repair."),
            ("REU", string("alpha_reu_", lowercase(fam.family)), "kg_metal_per_product_unit", "Metal intensity of reuse, often close to zero."),
            ("REF", string("yield_ref_", lowercase(fam.family)), "product_unit_per_eol_unit", "Refurbishment output yield from end-of-life inflows."),
            ("REP", string("yield_rep_", lowercase(fam.family)), "product_unit_per_eol_unit", "Repair output yield from end-of-life inflows."),
            ("REU", string("yield_reu_", lowercase(fam.family)), "product_unit_per_eol_unit", "Reuse output yield from end-of-life inflows."),
        ]
            push!(rows, [
                string(fam.family, "_", route, "_", parameter),
                fam.family,
                route,
                route in ("NEW", "REF", "REP", "REU") && startswith(parameter, "alpha_") ? "metal_intensity" : "yield",
                parameter,
                unit,
                "to_fill",
                "Populate from observed physical evidence where available; otherwise construct transparently and document.",
                "template",
                notes,
            ])
        end
    end

    for row in [
        [
            "ALL_METAL_external_price",
            "ALL",
            "METAL",
            "external_price",
            "external_metal_price",
            "model_value_per_tonne_METAL",
            "to_fill",
            "Common fixed external price of METAL, used to convert monetary BASIC_METALS use into physical METAL demand.",
            "template",
            "The same value is required in every European region because METAL has one EU-wide market price.",
        ],
        [
            "ALL_RECOVERY_yield_metal_ee",
            "ALL",
            "REC",
            "recovery_yield",
            "yield_metal_ee",
            "kg_METAL_per_kg_eol",
            "to_fill",
            "Recovery yield converting recycled end-of-life throughput into METAL output.",
            "template",
            "Common recycling yield for the single METAL commodity.",
        ],
    ]
        push!(rows, row)
    end

    return rows
end

function validation_pairs(final_registry, route_registry, quantity_template, coefficient_template)
    required_sut_sectors = Set([
        "BASIC_METALS",
        "METAL_COMPONENTS",
        "NEW_ELMA",
        "NEW_OFMA",
        "NEW_RATV",
        "REP_ELMA",
        "REP_OFMA",
        "REP_RATV",
        "REF_ELMA",
        "REF_OFMA",
        "REF_RATV",
        "REU_ELMA",
        "REU_OFMA",
        "REU_RATV",
        "REC_EE",
        "INC_EE",
    ])
    present = Set(keys(final_registry))
    missing = sort!(collect(setdiff(required_sut_sectors, present)))

    n_service_routes = count(row -> row[4] == "service_supply", route_registry)
    n_eol_routes = count(row -> row[4] in ("eol_recovery", "eol_disposal"), route_registry)

    return [
        ("model_scope", "six_european_regions_with_regional_external_accounts"),
        ("missing_required_sut_sectors", isempty(missing) ? "none" : join(missing, ";")),
        ("n_families", string(length(family_definitions()))),
        ("n_route_rows", string(length(route_registry))),
        ("n_service_routes", string(n_service_routes)),
        ("n_eol_routes", string(n_eol_routes)),
        ("n_quantity_rows", string(length(quantity_template))),
        ("n_coefficient_rows", string(length(coefficient_template))),
        ("service_alignment", "TST uses NEW,REF,REP,REU by family"),
        ("eol_alignment", "EOL allocates across REF,REP,REU,REC,INC by family"),
        ("physical_quantity_rule", "Q_t = Q0 * q_t; fallback uses value divided by benchmark unit value and relative price"),
        ("metal_commodity", "METAL is supplied by BASIC_METALS, REC_EE, and trade"),
    ]
end

function main()
    ensure_dir(OUTDIR)
    final_registry = load_final_sector_registry()

    family_header = [
        "family",
        "family_label",
        "service_account",
        "eol_account",
        "new_route",
        "repair_route",
        "refurbishment_route",
        "reuse_route",
        "recycling_activity",
        "disposal_activity",
        "metal_commodity",
        "metal_supply_sources",
        "primary_metal_activity",
        "service_route_set",
        "eol_route_set",
        "service_nest",
        "notes",
    ]
    family_table = family_rows()

    route_header = [
        "family",
        "family_label",
        "route",
        "route_scope",
        "service_account",
        "eol_account",
        "route_activity",
        "route_commodity",
        "stylized_counterpart",
        "observability",
        "policy_instrument",
        "material_link",
        "price_anchor_role",
        "source_sector_id",
        "notes",
    ]
    route_table = route_rows(final_registry)

    quantity_header = [
        "bridge_id",
        "family",
        "linked_account",
        "quantity_kind",
        "benchmark_value_anchor",
        "benchmark_physical_source",
        "physical_unit",
        "benchmark_price_anchor",
        "benchmark_unit_value_rule",
        "simulation_quantity_rule",
        "fallback_value_conversion_rule",
        "status",
        "notes",
    ]
    quantity_table = quantity_bridge_rows()

    coefficient_header = [
        "coefficient_id",
        "family",
        "route_or_pool",
        "coefficient_kind",
        "model_parameter",
        "physical_unit",
        "benchmark_source",
        "calibration_rule",
        "status",
        "notes",
    ]
    coefficient_table = coefficient_rows()

    validation = validation_pairs(final_registry, route_table, quantity_table, coefficient_table)

    write_tsv(joinpath(OUTDIR, "family_registry.tsv"), family_header, family_table)
    write_tsv(joinpath(OUTDIR, "route_registry.tsv"), route_header, route_table)
    write_tsv(joinpath(OUTDIR, "physical_quantity_bridge_template.tsv"), quantity_header, quantity_table)
    write_tsv(joinpath(OUTDIR, "physical_coefficient_template.tsv"), coefficient_header, coefficient_table)
    write_key_value_tsv(joinpath(OUTDIR, "stage7_validation.tsv"), validation)

    println("Wrote:")
    println("  ", joinpath(OUTDIR, "family_registry.tsv"))
    println("  ", joinpath(OUTDIR, "route_registry.tsv"))
    println("  ", joinpath(OUTDIR, "physical_quantity_bridge_template.tsv"))
    println("  ", joinpath(OUTDIR, "physical_coefficient_template.tsv"))
    println("  ", joinpath(OUTDIR, "stage7_validation.tsv"))
end

main()
