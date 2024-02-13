module ControlFunctions
# Time-dependent control inputs for prosumers

export PumpModel


function PumpModel(massflow_ref1, deltaP_ref1, speed_ref1,
                    massflow_ref2, deltaP_ref2, speed_ref2,
                    fluid_density, nominal_speed
                )
    # Returns closure with reference values captured
    # Following Licklederer et al, "Thermohydraulic model of Smart Thermal Grids with bidirectional power flow between prosumers", 2021, pages 4, 12
    
    # Unit conversions to conform to Licklederer et al
    # non-dimensionalise [rpm]:
    u_1 = speed_ref1 / nominal_speed
    u_2 = speed_ref2 / nominal_speed 
    # [kg/s] -> [l/min]:
    V_1 = massflow_ref1 / fluid_density * 60 * 1e3
    V_2 = massflow_ref2 / fluid_density * 60 * 1e3
    # [Pa] -> [hPa]:
    dP_1 = deltaP_ref1 * 1e-2
    dP_2 = deltaP_ref2 * 1e-2

    c1 = (dP_1 - (u_1 / u_2)^2 * dP_2) / (V_1^2 - (u_1 / u_2)^2 * V_2^2)
    c2 = (1.0 / u_2)^2 * (dP_2 - (V_2^2 * c1))

    function model(pump_speed, massflow)
        # Returns pressure increase across pump
        # Constant outer values in let-block for performance
        let c1 = c1
            c2 = c2
            nominal_speed = nominal_speed
            fluid_density = fluid_density
            # Local variables
            speed_ratio = pump_speed / nominal_speed
            vol_rate = massflow / fluid_density * 60 * 1e3 # [kg/s] -> [l/min]
            return ((c1 * vol_rate^2) + (c2 * speed_ratio^2)) * 1e2 # [hPa] -> [Pa]
        end
    end

    return model
end

end # module