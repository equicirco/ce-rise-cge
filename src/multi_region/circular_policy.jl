"""Model-local EU-wide circular-policy wedges and fiscally neutral transfers."""

const _CIRCULAR_POLICY_REVENUE_VAR = :POLICY_REVENUE
const _CIRCULAR_POLICY_SUPPORT_VAR = :POLICY_SUPPORT
const _CIRCULAR_POLICY_TRANSFER_VAR = :POLICY_TRANSFER

const _CIRCULAR_ROUTE_POLICY = Dict(
    :REF => :refurbishment_support,
    :REP => :repair_support,
    :REU => :reuse_support,
)

"""Return the policy instrument applicable to a household circular-service route."""
_route_policy_instrument(route::Symbol) = get(_CIRCULAR_ROUTE_POLICY, route, nothing)

"""Return the policy-adjusted purchaser-price multiplier for a service route."""
function _route_policy_multiplier(scenario::PolicyScenario, route::Symbol)
    instrument = _route_policy_instrument(route)
    return instrument === nothing ? 1.0 : 1.0 + policy_wedge(scenario, instrument)
end

function _effective_route_price_expr(block::CircularServiceDemandBlock,
    route::Symbol, good::Symbol)
    multiplier = _route_policy_multiplier(block.params.scenario, route)
    multiplier > 0.0 || error("Policy-adjusted route prices must remain positive.")
    price = EVar(:pq, Any[good])
    return isone(multiplier) ? price : EMul([EConst(multiplier), price])
end

"""
Policy fiscal account for each region.

The government collects the virgin-metal tax and pays material and household
route supports.  Its net policy balance is returned to the same region's
households, leaving calibrated government saving and government consumption
unchanged.  The policy is EU-wide, while incidence remains regional.
"""
struct CircularPolicyFiscalBlock <: JCGECore.AbstractBlock
    name::Symbol
    regions::Vector{Symbol}
    material_structure
    routes::CircularRouteCalibration
    scenario::PolicyScenario
    params::NamedTuple
end

"""Household demand block with the regional net policy transfer in disposable income."""
struct PolicyAwareHouseholdDemandBlock <: JCGECore.AbstractBlock
    name::Symbol
    regions::Vector{Symbol}
    goods_by_region::Dict{Symbol,Vector{Symbol}}
    factors_by_region::Dict{Symbol,Vector{Symbol}}
    activities_by_region::Dict{Symbol,Vector{Symbol}}
    params::NamedTuple
end

"""Private saving remains a calibrated share of disposable income, including policy transfers."""
struct PolicyAwarePrivateSavingBlock <: JCGECore.AbstractBlock
    name::Symbol
    regions::Vector{Symbol}
    factors_by_region::Dict{Symbol,Vector{Symbol}}
    activities_by_region::Dict{Symbol,Vector{Symbol}}
    params::NamedTuple
end

function _ensure_policy_variable!(ctx::JCGERuntime.KernelContext, model,
    name::Symbol; lower::Union{Nothing,Float64}=nothing)
    return _ensure_circular_route_variable!(ctx, model, name; lower=lower)
end

function _register_policy_equation!(ctx::JCGERuntime.KernelContext,
    block::JCGECore.AbstractBlock, tag::Symbol, ids::Symbol...;
    info::String, expr, index_names::Union{Nothing,Tuple}=nothing)
    return _register_circular_route_equation!(ctx, block, tag, ids...;
        info=info, expr=expr, index_names=index_names)
end

function _policy_base_term(good::Symbol, activity::Symbol)
    return EMul([
        EVar(:pq, Any[good]),
        EVar(:X, Any[good, activity]),
    ])
end

function _policy_route_base_term(good::Symbol)
    return EMul([
        EVar(:pq, Any[good]),
        EVar(:Xp, Any[good]),
    ])
end

function _policy_sum(terms::Vector{JCGECore.EquationExpr})
    return isempty(terms) ? EConst(0.0) : EAdd(terms)
end

function JCGECore.build!(block::CircularPolicyFiscalBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Circular-policy fiscal accounting requires a positive lower bound.")
    structure = block.material_structure
    scenario = block.scenario
    primary_tax = policy_wedge(scenario, :virgin_metal_tax)
    recycled_support = -policy_wedge(scenario, :recycling_support)
    route_support = Dict(
        route => -policy_wedge(scenario, instrument)
        for (route, instrument) in _CIRCULAR_ROUTE_POLICY
    )
    primary_tax_activities = _policy_primary_tax_activities(block.routes, structure)
    recycled_support_activities = _policy_recycled_support_activities(block.routes, structure)

    for region in block.regions
        revenue_name = JCGEBlocks.global_var(_CIRCULAR_POLICY_REVENUE_VAR, region)
        support_name = JCGEBlocks.global_var(_CIRCULAR_POLICY_SUPPORT_VAR, region)
        transfer_name = JCGEBlocks.global_var(_CIRCULAR_POLICY_TRANSFER_VAR, region)
        _ensure_policy_variable!(ctx, model, revenue_name; lower=nothing)
        _ensure_policy_variable!(ctx, model, support_name; lower=nothing)
        _ensure_policy_variable!(ctx, model, transfer_name; lower=nothing)

        revenue_terms = JCGECore.EquationExpr[]
        support_terms = JCGECore.EquationExpr[]
        for activity in structure.activities_by_region[region]
            primary = structure.primary_good[activity]
            recycled = structure.recycled_good[activity]
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:pq, primary); lower=lower)
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:pq, recycled); lower=lower)
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:X, primary, activity); lower=0.0)
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:X, recycled, activity); lower=0.0)
            if activity in primary_tax_activities && !iszero(primary_tax)
                push!(revenue_terms,
                    EMul([EConst(primary_tax), _policy_base_term(primary, activity)]))
            end
            if activity in recycled_support_activities && !iszero(recycled_support)
                push!(support_terms,
                    EMul([EConst(recycled_support), _policy_base_term(recycled, activity)]))
            end
        end
        for service in block.routes.services
            block.routes.service_region[service] === region || continue
            for (route, good) in block.routes.route_goods_by_service[service]
                instrument = _route_policy_instrument(route)
                instrument === nothing && continue
                amount = route_support[route]
                iszero(amount) && continue
                _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:pq, good); lower=lower)
                _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:Xp, good); lower=0.0)
                push!(support_terms, EMul([EConst(amount), _policy_route_base_term(good)]))
            end
        end

        _register_policy_equation!(ctx, block, :circular_policy_revenue, region;
            info="regional government receipts from the EU-wide virgin-metal tax",
            expr=EEq(EVar(_CIRCULAR_POLICY_REVENUE_VAR, Any[region]), _policy_sum(revenue_terms)),
            index_names=(:region,))
        _register_policy_equation!(ctx, block, :circular_policy_support, region;
            info="regional government expenditure on recycled-metal and life-extension support",
            expr=EEq(EVar(_CIRCULAR_POLICY_SUPPORT_VAR, Any[region]), _policy_sum(support_terms)),
            index_names=(:region,))
        _register_policy_equation!(ctx, block, :circular_policy_transfer, region;
            info="the regional government returns its net circular-policy balance to households",
            expr=EEq(
                EVar(_CIRCULAR_POLICY_TRANSFER_VAR, Any[region]),
                EAdd([
                    EVar(_CIRCULAR_POLICY_REVENUE_VAR, Any[region]),
                    ENeg(EVar(_CIRCULAR_POLICY_SUPPORT_VAR, Any[region])),
                ]),
            ), index_names=(:region,))
    end
    return nothing
end

function JCGECore.build!(block::PolicyAwareHouseholdDemandBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Policy-aware household demand requires a positive lower bound.")
    for region in block.regions
        goods = block.goods_by_region[region]
        factors = block.factors_by_region[region]
        activities = block.activities_by_region[region]
        _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:Sp, region); lower=nothing)
        _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:Td, region); lower=nothing)
        _ensure_policy_variable!(ctx, model,
            JCGEBlocks.global_var(_CIRCULAR_POLICY_TRANSFER_VAR, region); lower=nothing)
        for factor in factors, activity in activities
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:pf, factor); lower=lower)
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:F, factor, activity); lower=0.0)
        end
        disposable_income = EAdd([
            ESum(:factor, factors, ESum(:activity, activities, EMul([
                EVar(:pf, Any[EIndex(:factor)]),
                EVar(:F, Any[EIndex(:factor), EIndex(:activity)]),
            ]))),
            ENeg(EVar(:Sp, Any[region])),
            ENeg(EVar(:Td, Any[region])),
            EVar(_CIRCULAR_POLICY_TRANSFER_VAR, Any[region]),
        ])
        for good in goods
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:pq, good); lower=lower)
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:Xp, good); lower=0.0)
            _register_policy_equation!(ctx, block, :regional_household_demand, good, region;
                info="household demand allocates disposable factor income including the regional policy transfer",
                expr=EEq(
                    EVar(:Xp, Any[good]),
                    EDiv(
                        EMul([
                            EParam(:alpha, Any[good, region]),
                            disposable_income,
                        ]),
                        EVar(:pq, Any[good]),
                    ),
                ), index_names=(:good, :region))
        end
    end
    return nothing
end

function JCGECore.build!(block::PolicyAwarePrivateSavingBlock,
    ctx::JCGERuntime.KernelContext, spec::JCGECore.RunSpec)
    model = ctx.model
    lower = Float64(block.params.positive_lower)
    lower > 0.0 || error("Policy-aware private saving requires a positive lower bound.")
    for region in block.regions
        factors = block.factors_by_region[region]
        activities = block.activities_by_region[region]
        _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:Sp, region); lower=nothing)
        _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:Td, region); lower=nothing)
        _ensure_policy_variable!(ctx, model,
            JCGEBlocks.global_var(_CIRCULAR_POLICY_TRANSFER_VAR, region); lower=nothing)
        for factor in factors, activity in activities
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:pf, factor); lower=lower)
            _ensure_policy_variable!(ctx, model, JCGEBlocks.global_var(:F, factor, activity); lower=0.0)
        end
        disposable_income = EAdd([
            ESum(:factor, factors, ESum(:activity, activities, EMul([
                EVar(:pf, Any[EIndex(:factor)]),
                EVar(:F, Any[EIndex(:factor), EIndex(:activity)]),
            ]))),
            ENeg(EVar(:Td, Any[region])),
            EVar(_CIRCULAR_POLICY_TRANSFER_VAR, Any[region]),
        ])
        _register_policy_equation!(ctx, block, :regional_private_saving, region;
            info="private saving remains the calibrated share of regional disposable income including the policy transfer",
            expr=EEq(
                EVar(:Sp, Any[region]),
                EMul([EParam(:ssp, Any[region]), disposable_income]),
            ), index_names=(:region,))
    end
    return nothing
end

"""Return the policy blocks and their calibrated zero starts."""
function circular_policy_blocks(outline::MultiRegionOutline,
    calibration::MultiRegionCalibration, routes::CircularRouteCalibration,
    material_structure, scenario::PolicyScenario;
    positive_lower::Real=calibration.positive_lower)
    validate_policy_scenario(scenario, outline)
    lower = Float64(positive_lower)
    lower > 0.0 || error("Circular-policy variable lower bound must be strictly positive.")
    fiscal = CircularPolicyFiscalBlock(
        :regional_circular_policy_fiscal,
        outline.regions,
        material_structure,
        routes,
        scenario,
        (positive_lower = lower,),
    )
    household = PolicyAwareHouseholdDemandBlock(
        :regional_policy_aware_household_demand,
        outline.regions,
        routes.nonservice_goods_by_region,
        outline.factors_by_region,
        outline.industries_by_region,
        (alpha = calibration.household_demand_share,
         positive_lower = lower,),
    )
    private_saving = PolicyAwarePrivateSavingBlock(
        :regional_policy_aware_private_saving,
        outline.regions,
        outline.factors_by_region,
        outline.industries_by_region,
        (ssp = calibration.private_saving_share,
         positive_lower = lower,),
    )
    return (fiscal = fiscal, household = household, private_saving = private_saving)
end

"""Return zero calibrated starts for regional circular-policy fiscal variables."""
function circular_policy_initial_values(outline::MultiRegionOutline)
    starts = Dict{Symbol,Float64}()
    for region in outline.regions
        starts[JCGEBlocks.global_var(_CIRCULAR_POLICY_REVENUE_VAR, region)] = 0.0
        starts[JCGEBlocks.global_var(_CIRCULAR_POLICY_SUPPORT_VAR, region)] = 0.0
        starts[JCGEBlocks.global_var(_CIRCULAR_POLICY_TRANSFER_VAR, region)] = 0.0
    end
    return starts
end
