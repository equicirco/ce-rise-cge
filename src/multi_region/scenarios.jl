"""Scenario declaration for the six-region calibration replication."""

struct PolicyScenario
    name::Symbol
    description::String
    shocks::Dict{Symbol,Any}
    target_regions::Vector{Symbol}
end

baseline_scenario() = PolicyScenario(:baseline, "Calibration replication with no policy wedge", Dict{Symbol,Any}(), Symbol[])
