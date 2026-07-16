"""Policy scenario declarations shared by the six model regions."""

struct PolicyScenario
    name::Symbol
    description::String
    shocks::Dict{Symbol,Any}
    target_regions::Vector{Symbol}
end

_scenario_regions(regions) = regions === nothing ? Symbol[] : Symbol.(collect(regions))

baseline_scenario() = PolicyScenario(:baseline, "Calibration replication with no policy wedge", Dict{Symbol,Any}(), Symbol[])

virgin_material_tax_scenario(; tau = nothing, regions = nothing) = PolicyScenario(
    :virgin_material_tax,
    "Primary-metal tax applied to the selected model regions",
    Dict{Symbol,Any}(:tau_vmtl_ee => tau),
    _scenario_regions(regions),
)

recycling_support_scenario(; tau = nothing, regions = nothing) = PolicyScenario(
    :recycling_support,
    "Recycling-route policy wedge applied to the selected model regions",
    Dict{Symbol,Any}(:tau_rec_ee => tau),
    _scenario_regions(regions),
)

refurbishment_support_scenario(; tau = nothing, regions = nothing) = PolicyScenario(
    :refurbishment_support,
    "Refurbishment-route policy wedge applied to the selected model regions",
    Dict{Symbol,Any}(:tau_ref => tau),
    _scenario_regions(regions),
)

repair_support_scenario(; tau = nothing, regions = nothing) = PolicyScenario(
    :repair_support,
    "Repair-route policy wedge applied to the selected model regions",
    Dict{Symbol,Any}(:tau_rep => tau),
    _scenario_regions(regions),
)

reuse_support_scenario(; tau = nothing, regions = nothing) = PolicyScenario(
    :reuse_support,
    "Reuse-route policy wedge applied to the selected model regions",
    Dict{Symbol,Any}(:tau_reu => tau),
    _scenario_regions(regions),
)
