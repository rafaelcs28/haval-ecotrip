package br.com.redesurftank.ecotrip.models

enum class CarConstants(val value: String) {
    // Instant consumption
    CAR_BASIC_INSTANT_FUEL_CONSUMPTION("car.basic.instant_fuel_consumption"),
    CAR_EV_INFO_INSTANT_ENERGY_CONSUMPTION("car.ev_info.Instant_energy_consumption"),
    CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE("car.ev_info.energy_output_percentage"),

    // Cumulative per ignition cycle (reset when car turns off/on)
    CAR_EV_INFO_CYCLE_FUEL_CONSUME_INFO("car.ev_info.cycle_fuel_consume_info"),
    CAR_EV_INFO_CYCLE_ENERGY_CONSUME_INFO("car.ev_info.cycle_energy_consume_info"),
    CAR_EV_INFO_ENERGY_RECOVERY_INFO("car.ev_info.energy_recovery_info"),

    // Fuel tank
    CAR_BASIC_REMAIN_FUEL_PERCENTAGE("car.basic.remain_fuel_percentage"),

    // Distance, speed & state
    CAR_BASIC_CUR_JOURNEY_ODOMETER("car.basic.cur_journey_odometer"),
    CAR_BASIC_VEHICLE_SPEED("car.basic.vehicle_speed"),
    CAR_BASIC_POWER_MODE("car.basic.power_mode"),

    // Temperature
    CAR_BASIC_INSIDE_TEMP("car.basic.inside_temp"),
    CAR_BASIC_OUTSIDE_TEMP("car.basic.outside_temp"),

    // Battery SoC
    CAR_EV_INFO_BATTERY_CHARGE_PERCENTAGE("car.ev_info.battery_charge_percentage"),
    CAR_EV_INFO_SOC_OF_BATTERY("car.ev_info.soc_of_battery"),
    CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE("car.ev_info.cur_battery_power_percentage"),

    // Battery electrical measurements
    CAR_EV_INFO_CUR_CHARGE_CURRENT("car.ev_info.cur_charge_current"),
    CAR_EV_INFO_POWER_BATTERY_VOLTAGE("car.ev_info.power_battery_voltage"),
    CAR_EV_INFO_POWER_BATTERY_CURRENT("car.ev_info.power_battery_current"),

    // Vehicle model identification
    CAR_BASIC_VEHICLE_MODEL1("car.basic.vehicle_model1"),
    CAR_BASIC_VEHICLE_MODEL2("car.basic.vehicle_model2"),

    // EV settings (writable via request())
    // Values: 0-5 (mapeamento a confirmar com testes no carro)
    CAR_EV_SETTING_CHARGE_SOC_LIMIT("car.ev_setting.charge_soc_limit_config"),

    // Gear status — mapeamento confirmado: 0=N, 2=D, 3=P, 4=R
    CAR_BASIC_GEAR_STATUS("car.basic.gear_status"),
}
