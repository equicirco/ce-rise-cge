"""RunSpec assembly for the intended six-region CE-RISE CGE model."""

struct MultiRegionModelSpec
    label::String
    outline::MultiRegionOutline
    calibration::MultiRegionCalibration
    scenario::PolicyScenario
    coefficient_template::DataFrame
    quantity_template::DataFrame
end

default_optimizer() = Ipopt.Optimizer

function multi_region_model(; label::AbstractString = "eu-2016-six-region",
    bundle::CalibrationBundle = default_calibration_bundle(),
    calibration::MultiRegionCalibration = multi_region_calibration(bundle),
    scenario::PolicyScenario = baseline_scenario())
    return MultiRegionModelSpec(
        String(label),
        multi_region_outline(; bundle = bundle),
        calibration,
        scenario,
        copy(bundle.physical_coefficients),
        copy(bundle.physical_quantities),
    )
end

function _block(blocks, kind::Symbol)
    return only(filter(block -> block_kind(block) == kind, blocks))
end

function run_spec(model::MultiRegionModelSpec = multi_region_model())
    blocks = multi_region_blocks(model.outline, model.calibration, model.scenario)
    sections = [
        JCGECore.section(:production, Any[_block(blocks, :metadata), _block(blocks, :technology), _block(blocks, :eol), _block(blocks, :material), _block(blocks, :route_service)]),
        JCGECore.section(:init, Any[_block(blocks, :replication)]),
        JCGECore.section(:prices, Any[_block(blocks, :price)]),
        JCGECore.section(:government, Any[_block(blocks, :fiscal_income)]),
        JCGECore.section(:households, Any[_block(blocks, :demand)]),
        JCGECore.section(:trade, Any[_block(blocks, :trade)]),
        JCGECore.section(:objective, Any[_block(blocks, :objective)]),
    ]
    scenario = JCGECore.ScenarioSpec(model.scenario.name, copy(model.scenario.shocks))
    return JCGECore.build_spec(
        "$(model.label):$(model.scenario.name)",
        model.outline.sets,
        model.outline.mappings,
        sections;
        closure = model.outline.closure,
        scenario = scenario,
        allowed_sections = JCGECore.allowed_sections(),
    )
end

baseline(model::MultiRegionModelSpec = multi_region_model()) = run_spec(model)
