"""
Six-region JCGE blocks.

The sequence follows the fiscal closure of the stylized circular model.  The
trade block is added because bilateral flows among the six regions and each
regional external account are part of the empirical calibration SAM.
"""

struct MultiRegionBlock{Kind} <: JCGECore.AbstractBlock
    name::Symbol
    outline::MultiRegionOutline
    calibration::MultiRegionCalibration
    scenario::PolicyScenario
end

const MULTI_REGION_BLOCK_KINDS = (
    :metadata,
    :technology,
    :eol,
    :material,
    :route_service,
    :replication,
    :price,
    :fiscal_income,
    :demand,
    :trade,
    :objective,
)

function multi_region_blocks(outline::MultiRegionOutline, calibration::MultiRegionCalibration, scenario::PolicyScenario)
    calibration.bundle.name == outline.bundle.name || error("Model outline and calibration bundle differ.")
    return [MultiRegionBlock{kind}(Symbol(:six_region_, kind), outline, calibration, scenario) for kind in MULTI_REGION_BLOCK_KINDS]
end

block_kind(::MultiRegionBlock{Kind}) where {Kind} = Kind

function JCGECore.build!(block::MultiRegionBlock, ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    return nothing
end
