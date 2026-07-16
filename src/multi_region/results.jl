function summary_row(model::MultiRegionModelSpec = multi_region_model())
    summary = calibration_summary(model.outline.bundle)
    return (
        label = model.label,
        scenario = model.scenario.name,
        regions = summary.regions,
        industries = summary.industries,
        families = summary.families,
        routes = summary.routes,
        coefficient_rows = summary.coefficient_rows,
        quantity_bridge_rows = summary.quantity_bridge_rows,
    )
end
