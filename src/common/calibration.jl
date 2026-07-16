"""
Loader for the six-region calibration bundle produced by the data workflow.
"""

struct CalibrationBundle
    name::Symbol
    dir::String
    sets::Dict{Symbol,Vector{Symbol}}
    labels::Dict{Tuple{Symbol,Symbol},String}
    subsets::Dict{Symbol,Vector{Symbol}}
    mappings::DataFrame
    accounts::DataFrame
    sam::JCGECalibrate.LabeledMatrix{Float64}
    route_registry::DataFrame
    family_registry::DataFrame
    physical_coefficients::DataFrame
    physical_quantities::DataFrame
    configuration::DataFrame
    product_use_registry::DataFrame
    trade_registry::DataFrame
end

datadir() = normpath(joinpath(@__DIR__, "..", "..", "data"))

available_bundles() = (:eu_2016_six_region,)

function bundle_dir(name::Symbol = :eu_2016_six_region; data_dir::AbstractString = datadir())
    name === :eu_2016_six_region || error("Unknown calibration bundle $(name)")
    return joinpath(data_dir, "artifacts", "08_six_region_bundle")
end

function _load_optional_csv(path::AbstractString)
    return isfile(path) ? DataFrame(CSV.File(path)) : DataFrame()
end

function _load_tsv(path::AbstractString)
    return DataFrame(CSV.File(path; delim = '\t'))
end

function load_calibration_bundle(name::Symbol = :eu_2016_six_region; data_dir::AbstractString = datadir())
    dir = bundle_dir(name; data_dir = data_dir)
    isdir(dir) || error("Calibration bundle directory does not exist: $(dir)")
    return CalibrationBundle(
        name,
        dir,
        JCGECalibrate.load_canonical_sets(dir),
        JCGECalibrate.load_canonical_labels(dir),
        JCGECalibrate.load_canonical_subsets(dir),
        _load_optional_csv(joinpath(dir, "mappings.csv")),
        _load_tsv(joinpath(dir, "bundle_account_registry.tsv")),
        JCGECalibrate.load_labeled_matrix(joinpath(dir, "sam.csv"); label_col = "label"),
        _load_tsv(joinpath(dir, "regional_route_registry.tsv")),
        _load_tsv(joinpath(dir, "regional_family_registry.tsv")),
        _load_tsv(joinpath(dir, "regional_physical_coefficient_template.tsv")),
        _load_tsv(joinpath(dir, "regional_physical_quantity_bridge_template.tsv")),
        _load_tsv(joinpath(dir, "model_configuration.tsv")),
        _load_tsv(joinpath(dir, "regional_product_use_registry.tsv")),
        _load_tsv(joinpath(dir, "regional_trade_registry.tsv")),
    )
end

default_calibration_bundle() = load_calibration_bundle(:eu_2016_six_region)

"""Return the model-defined numeraire closure declared in a calibration bundle."""
function numeraire_closure(bundle::CalibrationBundle = default_calibration_bundle())
    columns = Set(names(bundle.configuration))
    required = Set(["component", "key", "value"])
    issubset(required, columns) || error("Calibration bundle configuration must contain component, key, and value columns.")
    closure_rows = filter(row -> row.component == "closure", bundle.configuration)
    values = Dict(String(row.key) => String(row.value) for row in eachrow(closure_rows))
    label = get(values, "numeraire_label", nothing)
    kind = get(values, "numeraire_kind", nothing)
    label === nothing && error("Calibration bundle configuration is missing closure.numeraire_label.")
    kind === nothing && error("Calibration bundle configuration is missing closure.numeraire_kind.")
    return JCGECore.ClosureSpec(Symbol(label); kind = Symbol(kind))
end

function calibration_summary(bundle::CalibrationBundle = default_calibration_bundle())
    return (
        name = bundle.name,
        dir = bundle.dir,
        regions = length(get(bundle.sets, :regions, Symbol[])),
        industries = length(get(bundle.sets, :industries, Symbol[])),
        factors = length(get(bundle.sets, :factors, Symbol[])),
        institutions = length(get(bundle.sets, :institutions, Symbol[])),
        externals = length(get(bundle.sets, :externals, Symbol[])),
        investment_pools = length(get(bundle.sets, :investment_pools, Symbol[])),
        families = length(get(bundle.sets, :families, Symbol[])),
        routes = length(get(bundle.sets, :routes, Symbol[])),
        sam_accounts = size(bundle.sam.data, 1),
        coefficient_rows = nrow(bundle.physical_coefficients),
        quantity_bridge_rows = nrow(bundle.physical_quantities),
        configuration_rows = nrow(bundle.configuration),
        product_use_rows = nrow(bundle.product_use_registry),
        trade_route_rows = nrow(bundle.trade_registry),
    )
end
