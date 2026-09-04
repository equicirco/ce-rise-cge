function coefficient_template_status(bundle::CalibrationBundle = default_calibration_bundle())
    return combine(groupby(copy(bundle.physical_coefficients), [:region, :family, :coefficient_kind, :status]), nrow => :count)
end

function quantity_bridge_status(bundle::CalibrationBundle = default_calibration_bundle())
    return combine(groupby(copy(bundle.physical_quantities), [:region, :family, :quantity_kind, :status]), nrow => :count)
end

function route_family_table(bundle::CalibrationBundle = default_calibration_bundle())
    return select(
        copy(bundle.route_registry),
        :region,
        :family,
        :route,
        :service_account,
        :eol_account,
        :route_activity,
        :policy_instrument,
        :material_link,
    )
end
