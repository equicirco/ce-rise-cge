#!/usr/bin/env julia

"""
Define the target empirical account structure for the CE-RISE CGE model.

This step does not balance data. It fixes the intended benchmark architecture
so later SUT/SAM work follows one explicit model design.

Guiding rule:
- keep the CE-RISE manufacturing split detailed in the SUT,
- construct benchmark SAM accounts that mirror the stylized circular model
  route logic by family,
- represent a single METAL commodity supplied by primary production, recycling,
  and trade rather than separate primary and secondary metal commodities.
"""

const ROOT_DIR = normpath(joinpath(@__DIR__, "..", ".."))
const OUTDIR = joinpath(ROOT_DIR, "data", "interim", "structure")

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

function account_rows()
    return [
        (
            account_id = "MET_ORE",
            account_label = "Metal ores and concentrates",
            scope = "upstream",
            stylized_counterpart = "",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "",
            observability = "future_figaro_product_split",
            figaro_anchor = "CPA_B07",
            overlay_anchor = "",
            notes = "Needed to separate mining from downstream metal manufacturing; not explicit in the current CPA_B base export.",
        ),
        (
            account_id = "BASIC_METALS",
            account_label = "Basic metals",
            scope = "upstream",
            stylized_counterpart = "METAL",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "",
            observability = "direct_figaro",
            figaro_anchor = "CPA_C24",
            overlay_anchor = "",
            notes = "Primary-metal production sector available directly in FIGARO; its output supplies the single METAL commodity.",
        ),
        (
            account_id = "METAL_COMPONENTS",
            account_label = "Fabricated metal products and metal components",
            scope = "upstream",
            stylized_counterpart = "",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "",
            observability = "direct_figaro",
            figaro_anchor = "CPA_C25",
            overlay_anchor = "",
            notes = "Keeps downstream metal components separate from basic metals; it is a metal-using industry, not a separate METAL commodity source.",
        ),
        (
            account_id = "NEW_ELMA",
            account_label = "New electrical equipment route",
            scope = "downstream_route",
            stylized_counterpart = "NEW",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "constructed_from_disaggregated_sut",
            figaro_anchor = "CPA_C27_HPP;CPA_C27_PV;CPA_C27_BAT;CPA_C27_ELMA_c",
            overlay_anchor = "A_ELMA children",
            notes = "Aggregates targeted C27 child sectors into the new-production route for the ELMA family.",
        ),
        (
            account_id = "NEW_OFMA",
            account_label = "New office machinery and computers route",
            scope = "downstream_route",
            stylized_counterpart = "NEW",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "constructed_from_disaggregated_sut",
            figaro_anchor = "CPA_C26_LAP;CPA_C26_DES;CPA_C26_PRI;CPA_C26_OFMA_c",
            overlay_anchor = "A_OFMA children",
            notes = "Aggregates targeted C26 office/computer child sectors into the new-production route.",
        ),
        (
            account_id = "NEW_RATV",
            account_label = "New communication and consumer electronics route",
            scope = "downstream_route",
            stylized_counterpart = "NEW",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "constructed_from_disaggregated_sut",
            figaro_anchor = "CPA_C26_MOB;CPA_C26_MON;CPA_C26_RATV_c",
            overlay_anchor = "A_RATV children",
            notes = "Aggregates targeted C26 communication/electronics child sectors into the new-production route.",
        ),
        (
            account_id = "REP_ELMA",
            account_label = "Repair route for electrical equipment",
            scope = "circular_route",
            stylized_counterpart = "REP",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "direct_family_specific_s95_split",
            figaro_anchor = "CPA_S95",
            overlay_anchor = "A_REPAIR",
            notes = "Observed household and personal repair services assigned to the ELMA repair route through the family-specific S95 split.",
        ),
        (
            account_id = "REP_OFMA",
            account_label = "Repair route for office machinery and computers",
            scope = "circular_route",
            stylized_counterpart = "REP",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "direct_family_specific_s95_split",
            figaro_anchor = "CPA_S95",
            overlay_anchor = "A_REPAIR",
            notes = "Observed household and personal repair services assigned to the OFMA repair route through the family-specific S95 split.",
        ),
        (
            account_id = "REP_RATV",
            account_label = "Repair route for communication and consumer electronics",
            scope = "circular_route",
            stylized_counterpart = "REP",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "direct_family_specific_s95_split",
            figaro_anchor = "CPA_S95",
            overlay_anchor = "A_REPAIR",
            notes = "Observed household and personal repair services assigned to the RATV repair route through the family-specific S95 split.",
        ),
        (
            account_id = "REF_ELMA",
            account_label = "Refurbishment route for electrical equipment",
            scope = "circular_route",
            stylized_counterpart = "REF",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "C",
            observability = "constructed_explicit_sut_sector",
            figaro_anchor = "CPA_C33;CPA_G46",
            overlay_anchor = "",
            notes = "Explicit target SUT sector constructed from the family-specific machinery-repair and wholesale channels for ELMA.",
        ),
        (
            account_id = "REF_OFMA",
            account_label = "Refurbishment route for office machinery and computers",
            scope = "circular_route",
            stylized_counterpart = "REF",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "C",
            observability = "constructed_explicit_sut_sector",
            figaro_anchor = "CPA_C33;CPA_G46",
            overlay_anchor = "",
            notes = "Explicit target SUT sector constructed from the family-specific machinery-repair and wholesale channels for OFMA.",
        ),
        (
            account_id = "REF_RATV",
            account_label = "Refurbishment route for communication and consumer electronics",
            scope = "circular_route",
            stylized_counterpart = "REF",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "C",
            observability = "constructed_explicit_sut_sector",
            figaro_anchor = "CPA_C33;CPA_G46",
            overlay_anchor = "",
            notes = "Explicit target SUT sector constructed from the family-specific machinery-repair and wholesale channels for RATV.",
        ),
        (
            account_id = "REU_ELMA",
            account_label = "Reuse route for electrical equipment",
            scope = "circular_route",
            stylized_counterpart = "REU",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "P",
            observability = "constructed_from_retail_leasing_and_overlay_proxy",
            figaro_anchor = "CPA_G47;CPA_N77",
            overlay_anchor = "A_GLAS_reuse",
            notes = "Explicit target SUT sector anchored in family-specific retail and leasing channels, with the overlay reuse node retained as supporting evidence.",
        ),
        (
            account_id = "REU_OFMA",
            account_label = "Reuse route for office machinery and computers",
            scope = "circular_route",
            stylized_counterpart = "REU",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "P",
            observability = "constructed_from_retail_leasing_and_overlay_proxy",
            figaro_anchor = "CPA_G47;CPA_N77",
            overlay_anchor = "A_GLAS_reuse",
            notes = "Explicit target SUT sector anchored in family-specific retail and leasing channels, with the overlay reuse node retained as supporting evidence.",
        ),
        (
            account_id = "REU_RATV",
            account_label = "Reuse route for communication and consumer electronics",
            scope = "circular_route",
            stylized_counterpart = "REU",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "P",
            observability = "constructed_from_retail_leasing_and_overlay_proxy",
            figaro_anchor = "CPA_G47;CPA_N77",
            overlay_anchor = "A_GLAS_reuse",
            notes = "Explicit target SUT sector anchored in family-specific retail and leasing channels, with the overlay reuse node retained as supporting evidence.",
        ),
        (
            account_id = "REC_EE",
            account_label = "Recycling and recovery activities for electronics chains",
            scope = "circular_route",
            stylized_counterpart = "REC",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "explicit_sut_sector",
            figaro_anchor = "CPA_E37-39",
            overlay_anchor = "A_*_RECY",
            notes = "Recycling activity that converts end-of-life inputs into the single METAL commodity; it is not a separate secondary-metal commodity account.",
        ),
        (
            account_id = "INC_EE",
            account_label = "Incineration and landfill treatment for electronics chains",
            scope = "disposal",
            stylized_counterpart = "INC",
            benchmark_role = "benchmark_sam_account",
            paper_observability = "O",
            observability = "constructed_from_overlay",
            figaro_anchor = "",
            overlay_anchor = "A_*_INCI;A_*_LAND",
            notes = "Common disposal sink for the targeted chains.",
        ),
        (
            account_id = "EOL_ELMA",
            account_label = "End-of-life flow for electrical equipment",
            scope = "stockflow",
            stylized_counterpart = "EOL",
            benchmark_role = "derived_account",
            paper_observability = "",
            observability = "derived_from_stock_and_routing",
            figaro_anchor = "",
            overlay_anchor = "repair/recycling/disposal routing nodes",
            notes = "Derived from product stock and retirement assumptions; not a native SUT sector.",
        ),
        (
            account_id = "EOL_OFMA",
            account_label = "End-of-life flow for office machinery and computers",
            scope = "stockflow",
            stylized_counterpart = "EOL",
            benchmark_role = "derived_account",
            paper_observability = "",
            observability = "derived_from_stock_and_routing",
            figaro_anchor = "",
            overlay_anchor = "repair/recycling/disposal routing nodes",
            notes = "Derived from product stock and retirement assumptions; not a native SUT sector.",
        ),
        (
            account_id = "EOL_RATV",
            account_label = "End-of-life flow for communication and consumer electronics",
            scope = "stockflow",
            stylized_counterpart = "EOL",
            benchmark_role = "derived_account",
            paper_observability = "",
            observability = "derived_from_stock_and_routing",
            figaro_anchor = "",
            overlay_anchor = "repair/recycling/disposal routing nodes",
            notes = "Derived from product stock and retirement assumptions; not a native SUT sector.",
        ),
        (
            account_id = "TST_ELMA",
            account_label = "Service composite for electrical equipment",
            scope = "service_composite",
            stylized_counterpart = "TST",
            benchmark_role = "derived_account",
            paper_observability = "",
            observability = "derived_from_route_composite",
            figaro_anchor = "",
            overlay_anchor = "",
            notes = "Composite final-use service combining new, refurbished, repaired, and reused ELMA routes.",
        ),
        (
            account_id = "TST_OFMA",
            account_label = "Service composite for office machinery and computers",
            scope = "service_composite",
            stylized_counterpart = "TST",
            benchmark_role = "derived_account",
            paper_observability = "",
            observability = "derived_from_route_composite",
            figaro_anchor = "",
            overlay_anchor = "",
            notes = "Composite final-use service combining new, refurbished, repaired, and reused OFMA routes.",
        ),
        (
            account_id = "TST_RATV",
            account_label = "Service composite for communication and consumer electronics",
            scope = "service_composite",
            stylized_counterpart = "TST",
            benchmark_role = "derived_account",
            paper_observability = "",
            observability = "derived_from_route_composite",
            figaro_anchor = "",
            overlay_anchor = "",
            notes = "Composite final-use service combining new, refurbished, repaired, and reused RATV routes.",
        ),
    ]
end

function route_rows()
    return [
        (
            family = "ELMA",
            family_label = "Electrical machinery and apparatus",
            route_observability = "NEW=O;REP=O;REF=C;REU=P;REC=O;INC=O",
            new_anchor = "HPP;PV;BAT;ELMA_c",
            repair_anchor = "S95 split; A_REPAIR",
            refurbishment_anchor = "C33 split + G46 split",
            reuse_anchor = "G47 split + N77 split; A_GLAS_reuse as evidence",
            recycling_activity = "REC_EE",
            metal_commodity = "METAL",
            disposal_account = "INC_EE",
            eol_account = "EOL_ELMA",
            service_account = "TST_ELMA",
        ),
        (
            family = "OFMA",
            family_label = "Office machinery and computers",
            route_observability = "NEW=O;REP=O;REF=C;REU=P;REC=O;INC=O",
            new_anchor = "LAP;DES;PRI;OFMA_c",
            repair_anchor = "S95 split; A_REPAIR",
            refurbishment_anchor = "C33 split + G46 split",
            reuse_anchor = "G47 split + N77 split; A_GLAS_reuse as evidence",
            recycling_activity = "REC_EE",
            metal_commodity = "METAL",
            disposal_account = "INC_EE",
            eol_account = "EOL_OFMA",
            service_account = "TST_OFMA",
        ),
        (
            family = "RATV",
            family_label = "Radio, television and communication equipment",
            route_observability = "NEW=O;REP=O;REF=C;REU=P;REC=O;INC=O",
            new_anchor = "MOB;MON;RATV_c",
            repair_anchor = "S95 split; A_REPAIR",
            refurbishment_anchor = "C33 split + G46 split",
            reuse_anchor = "G47 split + N77 split; A_GLAS_reuse as evidence",
            recycling_activity = "REC_EE",
            metal_commodity = "METAL",
            disposal_account = "INC_EE",
            eol_account = "EOL_RATV",
            service_account = "TST_RATV",
        ),
    ]
end

function main()
    ensure_dir(OUTDIR)

    accounts = account_rows()
    account_table = [
        [
            row.account_id,
            row.account_label,
            row.scope,
            row.stylized_counterpart,
            row.benchmark_role,
            row.paper_observability,
            row.observability,
            row.figaro_anchor,
            row.overlay_anchor,
            row.notes,
        ]
        for row in accounts
    ]
    account_header = [
        "account_id",
        "account_label",
        "scope",
        "stylized_counterpart",
        "benchmark_role",
        "paper_observability",
        "observability",
        "figaro_anchor",
        "overlay_anchor",
        "notes",
    ]
    write_tsv(
        joinpath(OUTDIR, "target_account_structure.tsv"),
        account_header,
        account_table,
    )
    routes = route_rows()
    route_table = [
        [
            row.family,
            row.family_label,
            row.route_observability,
            row.new_anchor,
            row.repair_anchor,
            row.refurbishment_anchor,
            row.reuse_anchor,
            row.recycling_activity,
            row.metal_commodity,
            row.disposal_account,
            row.eol_account,
            row.service_account,
        ]
        for row in routes
    ]
    route_header = [
        "family",
        "family_label",
        "route_observability",
        "new_anchor",
        "repair_anchor",
        "refurbishment_anchor",
        "reuse_anchor",
        "recycling_activity",
        "metal_commodity",
        "disposal_account",
        "eol_account",
        "service_account",
    ]
    write_tsv(
        joinpath(OUTDIR, "target_route_family_structure.tsv"),
        route_header,
        route_table,
    )
    println("Wrote:")
    println("  ", joinpath(OUTDIR, "target_account_structure.tsv"))
    println("  ", joinpath(OUTDIR, "target_route_family_structure.tsv"))
end

main()
