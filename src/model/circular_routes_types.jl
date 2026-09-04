"""Calibration-derived structure for the circular service and end-of-life system."""
struct CircularRouteCalibration
    services::Vector{Symbol}
    service_region::Dict{Symbol,Symbol}
    service_family::Dict{Symbol,Symbol}
    route_goods_by_service::Dict{Symbol,Dict{Symbol,Symbol}}
    nonservice_goods_by_region::Dict{Symbol,Vector{Symbol}}
    service_share::Dict{Symbol,Float64}
    route_share::Dict{Tuple{Symbol,Symbol},Float64}
    eol_lines_by_family::Dict{Symbol,Vector{Symbol}}
    eol_line_activity::Dict{Symbol,Symbol}
    eol_share::Dict{Tuple{Symbol,Symbol},Float64}
    eol_reference_price::Dict{Symbol,Float64}
    eol_reference_total::Dict{Symbol,Float64}
    eol_allocation_elasticity::Float64
    eol_productivity_elasticity::Float64
    service_elasticity::Float64
end
