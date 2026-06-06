package br.com.redesurftank.ecotrip.models

enum class CarConstants(val value: String) {
    // Instant consumption
    CAR_BASIC_INSTANT_FUEL_CONSUMPTION("car.basic.instant_fuel_consumption"),
    CAR_EV_INFO_INSTANT_ENERGY_CONSUMPTION("car.ev_info.Instant_energy_consumption"),
    CAR_EV_INFO_INSTANT_ENERGY_CONSUMPTION_LC("car.ev_info.instant_energy_consumption"), // lowercase — Shizuku pode entregar assim
    CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE("car.ev_info.energy_output_percentage"),

    // Cumulative per ignition cycle (reset when car turns off/on)
    CAR_EV_INFO_CYCLE_FUEL_CONSUME_INFO("car.ev_info.cycle_fuel_consume_info"),
    CAR_EV_INFO_CYCLE_ENERGY_CONSUME_INFO("car.ev_info.cycle_energy_consume_info"),
    CAR_EV_INFO_ENERGY_RECOVERY_INFO("car.ev_info.energy_recovery_info"),

    // Fuel tank
    CAR_BASIC_REMAIN_FUEL_PERCENTAGE("car.basic.remain_fuel_percentage"),

    // Distance, speed & state
    CAR_BASIC_CUR_JOURNEY_ODOMETER("car.basic.cur_journey_odometer"),
    CAR_BASIC_TOTAL_ODOMETER("car.basic.total_odometer"),
    CAR_BASIC_VEHICLE_SPEED("car.basic.vehicle_speed"),
    CAR_BASIC_STEERING_WHEEL_ANGLE("car.basic.steering_wheel_angle"),  // ângulo do volante (graus, ±)
    CAR_BASIC_ENGINE_SPEED("car.basic.engine_speed"),
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
    CAR_BASIC_BATTERY_VOLTAGE("car.basic.battery_voltage"),   // tensão do pack (namespace basic)

    // Motor elétrico — potência direta do HCU (kW, sinal positivo = consumo, negativo = regen)
    CAR_EV_INFO_MOTOR_POWER("car.ev_info.motor_power"),

    // Charging state — 0=Desconectado, 1=Carregando, 2=Programado, 3=Finalizado, 5=Aguardando liberação
    CAR_EV_INFO_CHARGING_STATE("car.ev_info.charging_state"),

    // Tempo restante de recarga (em minutos)
    CAR_EV_INFO_CHARGE_REMAINING_TIME("car.ev_info.charge_remaining_time"),

    // Vehicle model identification
    CAR_BASIC_VEHICLE_MODEL1("car.basic.vehicle_model1"),
    CAR_BASIC_VEHICLE_MODEL2("car.basic.vehicle_model2"),

    // EV settings (writable via request())
    // Values: 0-5 (mapeamento a confirmar com testes no carro)
    CAR_EV_SETTING_CHARGE_SOC_LIMIT("car.ev_setting.charge_soc_limit_config"),

    // Modo de condução PHEV — writable via request().
    // Valores: 0=HEV (híbrido), 1=Prioridade EV, 3=EV puro (elétrico).
    CAR_EV_SETTING_POWER_MODEL_CONFIG("car.ev_setting.power_model_config"),

    // Sub-modos do HEV — writable. Só fazem sentido quando power_model_config=0.
    // power_reserve: 1=Inteligente (carro decide), 2=Prioritário (preserva SOC alvo).
    // charge_soc_target: % de bateria a preservar em modo Prioritário (20..80).
    CAR_EV_SETTING_POWER_RESERVE_CONFIG("car.ev_setting.power_reserve_config"),
    CAR_EV_SETTING_CHARGE_SOC_TARGET_CONFIG("car.ev_setting.charge_soc_target_config"),

    // Gear status — mapeamento confirmado: 0=N, 2=D, 3=P, 4=R
    CAR_BASIC_GEAR_STATUS("car.basic.gear_status"),

    // Driving ready state — 1=pronto para condução (carro ligado), 0=desligado/não pronto
    CAR_BASIC_DRIVING_READY_STATE("car.basic.driving_ready_state"),

    // Comfort settings — ventilação dos bancos (0=off, 1/2/3=nível de ventilação)
    CAR_COMFORT_DRIVER_SEAT_VENT("car.comfort_setting.driver_seat_ventilation_level"),
    CAR_COMFORT_PASSENGER_SEAT_VENT("car.comfort_setting.passenger_seat_ventilation_level"),

    // HVAC settings — temperatura, ventilação, sync e auto (apenas leitura)
    CAR_HVAC_DRIVER_TEMPERATURE("car.hvac.driver_temperature"),
    CAR_HVAC_PASSENGER_TEMPERATURE("car.hvac.pass_temperature"),
    CAR_HVAC_FAN_SPEED("car.hvac.fan_speed"),           // 1..7
    CAR_HVAC_SYNC_ENABLE("car.hvac.sync_enable"),       // 0=off, 1=on
    CAR_HVAC_AUTO_ENABLE("car.hvac.auto_enable"),       // 0=off, 1=on
    CAR_HVAC_AC_ENABLE("car.hvac.ac_enable"),           // 0=off, 1=on (master AC)
    CAR_HVAC_CYCLE_MODE("car.hvac.cycle_mode"),         // 0=recirculação interna, 1=ar externo
    CAR_HVAC_ACMAX_ENABLE("car.hvac.acmax_enable"),         // 0=off, 1=on (resfriamento máximo)
    CAR_HVAC_ANION_ENABLE("car.hvac.anion_enable"),         // 0=off, 1=on (ionizador)
    CAR_HVAC_AQS_ENABLE("car.hvac.aqs_enable"),             // 0=off, 1=on (recirc. autom. por qualidade do ar)
    CAR_HVAC_HEATING_ENABLE("car.hvac.heating_enable"),     // 0=off, 1=on (aquecimento)
    CAR_HVAC_FRONT_DEFROST_ENABLE("car.hvac.front_defrost_enable"),  // 0=off, 1=on
    CAR_HVAC_REAR_DEFROST_ENABLE("car.hvac.rear_defrost_enable"),    // 0=off, 1=on
    CAR_HVAC_AUTO_DEFROST_ENABLE("car.hvac.setting.auto_defrost_enable"), // 0=off, 1=on
    CAR_HVAC_PM25_VALUE("car.hvac.pm2.5_value"),            // µg/m³ (leitura — qualidade do ar)
    CAR_HVAC_BLOWER_MODE("car.hvac.blower_mode"),           // 0=frente,1=frente+pés,2=pés,3=pés+parabrisa,4=parabrisa
    CAR_HVAC_POWER_MODE("car.hvac.power_mode"),             // 0=AC desligado (mestre) | 1=ligado

    // Body — portas, vidros, trava, teto solar
    // door_lock_status: 1=trancado, 0=destrancado (confirmado no barramento 2026-06-05)
    CAR_BASIC_DOOR_LOCK_STATUS("car.basic.door_lock_status"),
    // door_status: CSV "FL,FR,RL,RR,Trunk(,..)" — 0=fechada, 1=aberta (vem entre chaves: "{0,0,0,0,0,0}")
    CAR_BASIC_DOOR_STATUS("car.basic.door_status"),
    // window_status: CSV "FL,FR,RL,RR" — 1=fechado, 2=aberto, 3=entreaberto (confirmado via dashboard HA havaleiros)
    CAR_BASIC_WINDOW_STATUS("car.basic.window_status"),
    // sunroof_status: 0=fechado, >0=aberto (vários estágios — normalizamos pra binário)
    CAR_BASIC_SUNROOF_STATUS("car.basic.sunroof_status"),
    // front_fog_light_status: 0=desligado, 1=ligado (farol) — chave real confirmada no carro
    CAR_BASIC_FRONT_LIGHT_STATUS("car.basic.front_fog_light_status"),
    // Setas — lâmpada (pisca; acende nos 2 lados no pisca-alerta) + alavanca (seta simples)
    CAR_BASIC_LEFT_TURN_LIGHT_STATUS("car.basic.left_turn_light_status"),
    CAR_BASIC_RIGHT_TURN_LIGHT_STATUS("car.basic.right_turn_light_status"),
    CAR_BASIC_LEFT_TURN_SWITCH_STATUS("car.basic.left_turn_switch_status"),
    CAR_BASIC_RIGHT_TURN_SWITCH_STATUS("car.basic.right_turn_switch_status"),
    // TSR (reconhecimento de sinalização do carro): limite de velocidade + distância ao radar
    CAR_MAP_TSR_NAV_SPEED_LIMIT("car.map.tsr.nav_speed_limit"),
    CAR_MAP_TSR_NAV_SPEED_LIMIT_SIGN_STATUS("car.map.tsr.nav_speed_limit_sign_status"),
    CAR_MAP_TSR_NAV_TO_TRAFFIC_EYE_DISTANCE("car.map.tsr.nav_to_traffic_eye_distance"),
    // seat_belt_warning: alerta de ocupante sentado SEM cinto afivelado (0=ok, >0=alerta)
    CAR_BASIC_SEAT_BELT_WARNING("car.basic.seat_belt_warning"),
    // seated_state: ocupação dos bancos (formato cru a confirmar — bitmask/CSV por assento)
    CAR_BASIC_SEATED_STATE("car.basic.seated_state"),

    // Terrain / driving style — writable. 0=Normal, 1=Sport, 2=Eco, 3=Neve, 4=Areia, 5=Lama, 11=AWD
    CAR_DRIVE_SETTING_DRIVE_MODE("car.drive_setting.drive_mode"),

    // Energy recovery level — writable. 0=Normal, 1=Alto, 2=Baixo
    CAR_EV_SETTING_ENERGY_RECOVERY_LEVEL("car.ev_setting.energy_recovery_level"),

    // One-pedal driving — writable. 0=off, 1=on
    CAR_EV_SETTING_PEDAL_CONTROL_ENABLE("car.ev.setting.pedal_control_enable"),

    // ESP stability control — writable. 0=off, 1=on
    CAR_DRIVE_SETTING_ESP_ENABLE("car.drive_setting.esp_enable"),

    // Steering wheel assist mode — writable. 0=Normal, 1=Sport, 2=Conforto
    CAR_DRIVE_SETTING_STEER_MODE("car.drive_setting.steering_wheel_assist_mode"),
}
