"""
Model-facing sets and mappings for the six-region calibration bundle.

The empirical SAM is industry by industry.  JCGECore currently carries the
standard activity and commodity fields internally; both therefore receive the
same industry set.  The model interface itself exposes industries only.
"""

function _bundle_items(bundle::CalibrationBundle, name::Symbol)
    haskey(bundle.sets, name) || error("Calibration bundle is missing set $(name)")
    return copy(bundle.sets[name])
end

region_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :regions)
industry_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :industries)
factor_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :factors)
institution_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :institutions)
external_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :externals)
investment_pool_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :investment_pools)
family_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :families)
route_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :routes)
service_target_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :service_targets)
eol_target_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :eol_targets)
material_target_codes(bundle::CalibrationBundle = default_calibration_bundle()) = _bundle_items(bundle, :material_targets)

function account_region_lookup(bundle::CalibrationBundle = default_calibration_bundle())
    return Dict(Symbol(row.account_id) => Symbol(row.region) for row in eachrow(bundle.accounts))
end

function _items_by_region(items::Vector{Symbol}, lookup::Dict{Symbol,Symbol}, regions::Vector{Symbol})
    out = Dict(region => Symbol[] for region in regions)
    for item in items
        region = get(lookup, item, nothing)
        region === nothing && continue
        haskey(out, region) && push!(out[region], item)
    end
    return out
end

function _model_sets(bundle::CalibrationBundle)
    industries = industry_codes(bundle)
    institutions = vcat(institution_codes(bundle), investment_pool_codes(bundle), external_codes(bundle))
    return JCGECore.Sets(industries, industries, factor_codes(bundle), institutions)
end

function _model_mappings(bundle::CalibrationBundle)
    industries = industry_codes(bundle)
    return JCGECore.Mappings(Dict(industry => industry for industry in industries))
end

struct MultiRegionOutline
    bundle::CalibrationBundle
    regions::Vector{Symbol}
    industries::Vector{Symbol}
    factors::Vector{Symbol}
    institutions::Vector{Symbol}
    externals::Vector{Symbol}
    investment_pools::Vector{Symbol}
    families::Vector{Symbol}
    routes::Vector{Symbol}
    industries_by_region::Dict{Symbol,Vector{Symbol}}
    factors_by_region::Dict{Symbol,Vector{Symbol}}
    institutions_by_region::Dict{Symbol,Vector{Symbol}}
    externals_by_region::Dict{Symbol,Vector{Symbol}}
    closure::JCGECore.ClosureSpec
    sets::JCGECore.Sets
    mappings::JCGECore.Mappings
end

function multi_region_outline(; bundle::CalibrationBundle = default_calibration_bundle())
    regions = region_codes(bundle)
    lookup = account_region_lookup(bundle)
    industries = industry_codes(bundle)
    factors = factor_codes(bundle)
    institutions = institution_codes(bundle)
    externals = external_codes(bundle)
    return MultiRegionOutline(
        bundle,
        regions,
        industries,
        factors,
        institutions,
        externals,
        investment_pool_codes(bundle),
        family_codes(bundle),
        route_codes(bundle),
        _items_by_region(industries, lookup, regions),
        _items_by_region(factors, lookup, regions),
        _items_by_region(institutions, lookup, regions),
        _items_by_region(externals, lookup, regions),
        numeraire_closure(bundle),
        _model_sets(bundle),
        _model_mappings(bundle),
    )
end

function outline_summary(outline::MultiRegionOutline = multi_region_outline())
    return (
        regions = length(outline.regions),
        industries = length(outline.industries),
        industries_per_region = all(length(outline.industries_by_region[region]) == 25 for region in outline.regions) ? 25 : missing,
        factors = length(outline.factors),
        institutions = length(outline.institutions),
        externals = length(outline.externals),
        investment_pools = length(outline.investment_pools),
        families = length(outline.families),
        routes = length(outline.routes),
        numeraire = outline.closure.numeraire,
        numeraire_kind = outline.closure.kind,
    )
end
