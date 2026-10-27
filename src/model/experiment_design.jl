"""Agreed information/fiscal experiment specification, independent of model execution."""

const INFORMATION_MECHANISMS = (
    :repair_labour_saving,
    :refurbishment_labour_saving,
    :recycling_labour_saving,
    :circular_preference_increase,
)

"""Load the information-improvement assumptions, separately from elasticities and fiscal rates."""
function information_parameter_grid(; data_dir::AbstractString=datadir())
    table = _load_tsv(joinpath(data_dir, "mappings", "information_parameter_grid.tsv"))
    return _validated_information_grid(table)
end

function _validated_information_grid(grid::DataFrame)
    table = copy(grid)
    required = Set(["mechanism", "sequence", "value", "interpretation"])
    issubset(required, Set(names(table))) || error("Information grid is missing required columns.")
    table.mechanism = Symbol.(table.mechanism)
    table.sequence = Int.(table.sequence)
    table.value = Float64.(table.value)
    Set(table.mechanism) == Set(INFORMATION_MECHANISMS) || error("Information mechanisms do not match the declared design.")
    all(value -> isfinite(value) && 0.0 < value < 1.0, table.value) ||
        error("Information changes must be finite fractions strictly between zero and one.")
    ladder = nothing
    for mechanism in INFORMATION_MECHANISMS
        rows = sort(filter(:mechanism => ==(mechanism), table), :sequence)
        rows.sequence == collect(1:nrow(rows)) || error("Information levels must have consecutive sequences.")
        all(diff(rows.value) .> 0.0) || error("Information levels must be unique and increasing.")
        if ladder === nothing
            ladder = rows.value
        else
            rows.value == ladder || error("Information mechanisms must use the same proportional ladder.")
        end
    end
    sort!(table, [:mechanism, :sequence])
    return table
end

_information_level_label(value::Real) = replace(string(Float64(value)), "." => "_")
_information_package_id(value::Real) = Symbol("information_package_", _information_level_label(value))

"""
    policy_experiment_design(; bundle=default_calibration_bundle(), information_grid=information_parameter_grid())

Return the agreed 55 interventions and their common reference. All changes
apply to every modelled region and electronics family. Repair, refurbishment
and recycling labour savings are separate mechanisms; the acceptance mechanism
shifts all three household circular alternatives together. The 10% package is
paired with each existing fiscal instrument and wedge.

This catalogue supports model implementation and analysis planning. It is
independent of numerical scenario execution.
"""
function policy_experiment_design(; bundle::CalibrationBundle=default_calibration_bundle(),
    information_grid::DataFrame=information_parameter_grid())
    information_grid = _validated_information_grid(information_grid)
    regions = join(string.(region_codes(bundle)), ';')
    families = join(string.(family_codes(bundle)), ';')
    rows = NamedTuple[]
    function add(id, kind; mechanism=:none, strength=0.0, instrument=missing, wedge=0.0,
        repair=0.0, refurbishment=0.0, recycling=0.0, preference=0.0)
        push!(rows, (scenario_id=Symbol(id), scenario_kind=Symbol(kind),
            information_mechanism=Symbol(mechanism), information_strength=Float64(strength),
            fiscal_instrument=instrument, fiscal_wedge=Float64(wedge),
            repair_labour_saving=Float64(repair), refurbishment_labour_saving=Float64(refurbishment),
            recycling_labour_saving=Float64(recycling), circular_preference_increase=Float64(preference),
            regions=regions, families=families))
    end
    add(:baseline, :reference)
    fiscal_grid = policy_wedge_grid(bundle)
    for row in eachrow(fiscal_grid)
        fiscal = eu_wide_policy_scenario(row.instrument, row.wedge; bundle)
        add(fiscal.name, :fiscal; instrument=row.instrument, wedge=row.wedge)
    end
    for row in eachrow(information_grid)
        row.mechanism in INFORMATION_MECHANISMS || error("Unknown information mechanism.")
        value = Float64(row.value)
        add(Symbol("information_", row.mechanism, "_", _information_level_label(value)), :information_single;
            mechanism=row.mechanism, strength=value,
            repair=row.mechanism == :repair_labour_saving ? value : 0.0,
            refurbishment=row.mechanism == :refurbishment_labour_saving ? value : 0.0,
            recycling=row.mechanism == :recycling_labour_saving ? value : 0.0,
            preference=row.mechanism == :circular_preference_increase ? value : 0.0)
    end
    levels = sort(unique(Float64.(information_grid.value)))
    0.10 in levels || error("The agreed joint scenarios require the 10% information package.")
    for value in levels
        add(_information_package_id(value), :information_package; mechanism=:package, strength=value,
            repair=value, refurbishment=value, recycling=value, preference=value)
    end
    for row in eachrow(fiscal_grid)
        fiscal = eu_wide_policy_scenario(row.instrument, row.wedge; bundle)
        add(Symbol(_information_package_id(0.10), "__", fiscal.name), :joint;
            mechanism=:package, strength=0.10, instrument=row.instrument, wedge=row.wedge,
            repair=0.10, refurbishment=0.10, recycling=0.10, preference=0.10)
    end
    table = DataFrame(rows)
    allunique(table.scenario_id) || error("Experiment scenario identifiers must be unique.")
    return table
end

"""
Define comparisons using outcome levels within the same sensitivity profile.
Interaction = joint - information-only - fiscal-only + reference. This measures
departure from additive effects; its favourable direction depends on the
outcome (a negative interaction in primary-metal use means additional saving).
"""
function policy_experiment_comparisons(design::DataFrame=policy_experiment_design())
    rows = NamedTuple[]
    function contrast(kind, id, terms)
        for (scenario, coefficient) in terms
            scenario in design.scenario_id || error("Comparison references an unknown scenario: $scenario")
            push!(rows, (comparison_id=Symbol(kind, "__", id), comparison_kind=kind,
                scenario_id=Symbol(scenario), coefficient=Float64(coefficient)))
        end
    end
    for row in eachrow(design)
        row.scenario_kind == :reference && continue
        contrast(:total_change, row.scenario_id, ((row.scenario_id, 1.0), (:baseline, -1.0)))
        row.scenario_kind == :joint || continue
        information = _information_package_id(row.information_strength)
        fiscal = only(filter(other -> other.scenario_kind == :fiscal &&
            isequal(other.fiscal_instrument, row.fiscal_instrument) &&
            other.fiscal_wedge == row.fiscal_wedge, eachrow(design))).scenario_id
        contrast(:fiscal_with_information, row.scenario_id, ((row.scenario_id, 1.0), (information, -1.0)))
        contrast(:information_with_fiscal, row.scenario_id, ((row.scenario_id, 1.0), (fiscal, -1.0)))
        contrast(:interaction, row.scenario_id,
            ((row.scenario_id, 1.0), (information, -1.0), (fiscal, -1.0), (:baseline, 1.0)))
    end
    return DataFrame(rows)
end
