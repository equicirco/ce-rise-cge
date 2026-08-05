"""Scenario declaration for the six-region calibration and EU-wide policy runs."""

const CIRCULAR_POLICY_INSTRUMENTS = (
    :virgin_metal_tax,
    :recycling_support,
    :refurbishment_support,
    :repair_support,
    :reuse_support,
)

const SENSITIVITY_PARAMETER_KEYS = (
    ("trade", "armington_elasticity"),
    ("trade", "cet_transformation_elasticity"),
    ("circular_routes", "service_elasticity"),
    ("circular_routes", "eol_allocation_elasticity"),
    ("circular_routes", "eol_productivity_elasticity"),
    ("circular_metal", "material_substitution_elasticity"),
)

"""One fully specified behavioural sensitivity case drawn from the shared grid."""
struct SensitivityProfile
    name::Symbol
    description::String
    values::Dict{Tuple{String,String},Float64}
end

struct PolicyScenario
    name::Symbol
    description::String
    shocks::Dict{Symbol,Any}
    target_regions::Vector{Symbol}
end

baseline_scenario() = PolicyScenario(:baseline, "Calibration replication with no policy wedge", Dict{Symbol,Any}(), Symbol[])

function _policy_wedge_value(instrument::Symbol, wedge::Real)
    instrument in CIRCULAR_POLICY_INSTRUMENTS || error(
        "Unknown circular-policy instrument $(instrument).")
    value = Float64(wedge)
    isfinite(value) || error("Policy wedge for $(instrument) must be finite.")
    value > -1.0 || error("Policy wedge for $(instrument) must be strictly greater than -1.")
    if instrument === :virgin_metal_tax
        value >= 0.0 || error("The virgin-metal tax must be non-negative.")
    else
        value <= 0.0 || error("$(instrument) is a support and must be non-positive.")
    end
    return value
end

"""
    eu_wide_policy_scenario(instrument, wedge; bundle=default_calibration_bundle())

Create one EU-wide, individually evaluated circular-economy policy scenario.
The common sign convention follows the stylized model: a positive wedge is a
tax and a negative wedge is a support.  Combinations are intentionally not
accepted at this stage.
"""
function eu_wide_policy_scenario(instrument::Symbol, wedge::Real;
    bundle::CalibrationBundle=default_calibration_bundle())
    value = _policy_wedge_value(instrument, wedge)
    magnitude = replace(string(abs(value)), "." => "_")
    label = iszero(value) ? :policy_zero :
        Symbol(instrument, value < 0.0 ? :_support_ : :_tax_, magnitude)
    description = "EU-wide $(replace(String(instrument), '_' => ' ')) wedge of $(value)."
    return PolicyScenario(
        label,
        description,
        Dict{Symbol,Any}(instrument => value),
        copy(region_codes(bundle)),
    )
end

"""Return the declared wedge for one circular-policy instrument."""
function policy_wedge(scenario::PolicyScenario, instrument::Symbol)
    instrument in CIRCULAR_POLICY_INSTRUMENTS || error(
        "Unknown circular-policy instrument $(instrument).")
    return _policy_wedge_value(instrument, get(scenario.shocks, instrument, 0.0))
end

"""
    policy_wedge_grid(bundle=default_calibration_bundle())

Load and validate the common proportional wedge ladder used to compare each
EU-wide circular-policy instrument. The baseline is deliberately excluded: it
is solved once as the common zero-policy reference.
"""
function policy_wedge_grid(bundle::CalibrationBundle = default_calibration_bundle())
    table = copy(bundle.policy_wedge_grid)
    required = Set(["instrument", "sequence", "wedge", "description"])
    issubset(required, Set(names(table))) || error(
        "The policy wedge grid must contain instrument, sequence, wedge, and description columns.")
    nrow(table) > 0 || error("The policy wedge grid cannot be empty.")
    table.instrument = Symbol.(table.instrument)
    table.sequence = Int.(table.sequence)
    table.wedge = Float64.(table.wedge)
    all(table.sequence .> 0) || error("Policy-wedge sequences must be positive integers.")
    instruments = Set(table.instrument)
    instruments == Set(CIRCULAR_POLICY_INSTRUMENTS) || error(
        "The policy wedge grid must contain exactly the declared circular-policy instruments.")

    reference_strengths = nothing
    for group in groupby(table, :instrument)
        ordered = sort(group, :sequence)
        group_instrument = only(unique(ordered.instrument))
        ordered.sequence == collect(1:nrow(ordered)) || error(
            "Policy-wedge sequence for $(group_instrument) must be consecutive from one.")
        wedges = Float64.(ordered.wedge)
        all(wedge -> !iszero(wedge), wedges) || error(
            "The zero-policy reference must not be repeated in the policy wedge grid.")
        all(_policy_wedge_value(group_instrument, wedge) == wedge
            for wedge in wedges) || error(
            "Policy-wedge signs are inconsistent for $(group_instrument).")
        strengths = abs.(wedges)
        issorted(strengths; lt = <) || error(
            "Policy-wedge strengths for $(group_instrument) must increase strictly.")
        length(unique(strengths)) == length(strengths) || error(
            "Policy-wedge strengths for $(group_instrument) must be unique.")
        if reference_strengths === nothing
            reference_strengths = strengths
        else
            length(strengths) == length(reference_strengths) &&
                all(isapprox.(strengths, reference_strengths; atol=0.0, rtol=0.0)) || error(
                    "All circular-policy instruments must share the same proportional wedge ladder.")
        end
    end
    sort!(table, [:instrument, :sequence])
    return table
end

"""Return the configured EU-wide scenarios for one policy instrument."""
function policy_sweep_scenarios(instrument::Symbol;
    bundle::CalibrationBundle = default_calibration_bundle())
    table = policy_wedge_grid(bundle)
    instrument in CIRCULAR_POLICY_INSTRUMENTS || error(
        "Unknown circular-policy instrument $(instrument).")
    rows = sort!(collect(filter(row -> row.instrument === instrument, eachrow(table)));
        by = row -> row.sequence)
    return [eu_wide_policy_scenario(instrument, row.wedge; bundle=bundle) for row in rows]
end

"""
    sensitivity_parameter_grid(bundle=default_calibration_bundle())

Load the shared three-level grid for the six behavioural parameters that are
varied jointly with every policy path. Physical reporting coefficients and
numerical solver settings are deliberately excluded.
"""
function sensitivity_parameter_grid(bundle::CalibrationBundle = default_calibration_bundle())
    table = copy(bundle.sensitivity_parameter_grid)
    required = Set(["component", "key", "sequence", "value", "description"])
    issubset(required, Set(names(table))) || error(
        "The sensitivity-parameter grid must contain component, key, sequence, value, and description columns.")
    nrow(table) > 0 || error("The sensitivity-parameter grid cannot be empty.")
    table.component = String.(table.component)
    table.key = String.(table.key)
    table.sequence = Int.(table.sequence)
    table.value = Float64.(table.value)
    all(table.sequence .> 0) || error("Sensitivity-grid sequences must be positive integers.")
    all(isfinite, table.value) || error("Sensitivity-grid values must be finite.")
    all(>(0.0), table.value) || error("Sensitivity-grid values must be strictly positive.")

    declared = Set((row.component, row.key) for row in eachrow(table))
    declared == Set(SENSITIVITY_PARAMETER_KEYS) || error(
        "The sensitivity-parameter grid must contain exactly the declared behavioural parameters.")
    reference_values = nothing
    for parameter in SENSITIVITY_PARAMETER_KEYS
        component, key = parameter
        rows = sort!(collect(filter(row -> row.component == component && row.key == key,
            eachrow(table))); by = row -> row.sequence)
        [row.sequence for row in rows] == collect(1:length(rows)) || error(
            "Sensitivity sequence for $(component).$(key) must be consecutive from one.")
        values = Float64[row.value for row in rows]
        length(unique(values)) == length(values) || error(
            "Sensitivity values for $(component).$(key) must be unique.")
        calibration_option(bundle, component, key)
        if reference_values === nothing
            reference_values = values
        else
            values == reference_values || error(
                "All behavioural sensitivity parameters must use the same shared value ladder.")
        end
    end
    sort!(table, [:component, :key, :sequence])
    return table
end

"""Return the Cartesian product of the declared behavioural sensitivity ladder."""
function sensitivity_profiles(bundle::CalibrationBundle = default_calibration_bundle())
    table = sensitivity_parameter_grid(bundle)
    values_by_parameter = Vector{Vector{Float64}}()
    for (component, key) in SENSITIVITY_PARAMETER_KEYS
        rows = sort!(collect(filter(row -> row.component == component && row.key == key,
            eachrow(table))); by = row -> row.sequence)
        push!(values_by_parameter, Float64[row.value for row in rows])
    end
    profiles = SensitivityProfile[]
    for (index, combination) in enumerate(Iterators.product(values_by_parameter...))
        values = Dict(
            parameter => Float64(combination[position])
            for (position, parameter) in enumerate(SENSITIVITY_PARAMETER_KEYS)
        )
        assignments = join([
            "$(key)=$(values[(component, key)])"
            for (component, key) in SENSITIVITY_PARAMETER_KEYS
        ], "; ")
        push!(profiles, SensitivityProfile(
            Symbol("sensitivity_", lpad(string(index), 3, '0')),
            "Shared behavioural sensitivity profile: $(assignments).",
            values,
        ))
    end
    return profiles
end

"""Return the calibration bundle with one sensitivity profile substituted into its data configuration."""
function sensitivity_bundle(profile::SensitivityProfile;
    bundle::CalibrationBundle = default_calibration_bundle())
    expected = Set(SENSITIVITY_PARAMETER_KEYS)
    Set(keys(profile.values)) == expected || error(
        "Sensitivity profile $(profile.name) must define every declared behavioural parameter exactly once.")
    configuration = copy(bundle.configuration)
    for ((component, key), value) in profile.values
        isfinite(value) && value > 0.0 || error(
            "Sensitivity value for $(component).$(key) must be finite and strictly positive.")
        matches = findall(row -> String(row.component) == component && String(row.key) == key,
            eachrow(configuration))
        length(matches) == 1 || error(
            "Calibration configuration must contain one value for $(component).$(key).")
        configuration.value[only(matches)] = string(value)
    end
    return CalibrationBundle(
        bundle.name,
        bundle.dir,
        bundle.sets,
        bundle.labels,
        bundle.subsets,
        bundle.mappings,
        bundle.accounts,
        bundle.sam,
        bundle.route_registry,
        bundle.family_registry,
        bundle.physical_coefficients,
        bundle.circular_metal_baseline,
        bundle.physical_quantities,
        bundle.physical_flows,
        configuration,
        bundle.policy_wedge_grid,
        bundle.sensitivity_parameter_grid,
        bundle.product_use_registry,
        bundle.trade_registry,
    )
end

"""Validate that a scenario is a baseline or one EU-wide policy intervention."""
function validate_policy_scenario(scenario::PolicyScenario,
    outline::MultiRegionOutline)
    unknown = setdiff(Set(keys(scenario.shocks)), Set(CIRCULAR_POLICY_INSTRUMENTS))
    isempty(unknown) || error("Scenario $(scenario.name) has unknown shocks: $(join(string.(sort!(collect(unknown))), ", ")).")
    if scenario.name === :baseline
        isempty(scenario.shocks) || error("The baseline scenario cannot contain policy wedges.")
        isempty(scenario.target_regions) || error("The baseline scenario cannot target regions.")
        return nothing
    end
    sort(unique(scenario.target_regions)) == sort(outline.regions) || error(
        "Circular-policy scenarios must apply uniformly to all modelled European regions.")
    active = Symbol[]
    for instrument in CIRCULAR_POLICY_INSTRUMENTS
        value = policy_wedge(scenario, instrument)
        iszero(value) || push!(active, instrument)
    end
    length(active) <= 1 || error(
        "A policy scenario may contain at most one non-zero wedge at this stage.")
    return nothing
end
