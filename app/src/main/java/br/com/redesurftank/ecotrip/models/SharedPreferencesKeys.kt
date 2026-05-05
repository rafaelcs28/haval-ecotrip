package br.com.redesurftank.ecotrip.models

object SharedPreferencesKeys {
    const val PREFS_NAME = "ecotrip_prefs"

    // Trip A accumulated
    const val TRIP_A_FUEL_L = "trip_a_fuel_l"
    const val TRIP_A_ENERGY_KWH = "trip_a_energy_kwh"
    const val TRIP_A_REGEN_KWH = "trip_a_regen_kwh"
    const val TRIP_A_DISTANCE_KM = "trip_a_distance_km"
    const val TRIP_A_TIME_SEC = "trip_a_time_sec"

    // Trip B accumulated
    const val TRIP_B_FUEL_L = "trip_b_fuel_l"
    const val TRIP_B_ENERGY_KWH = "trip_b_energy_kwh"
    const val TRIP_B_REGEN_KWH = "trip_b_regen_kwh"
    const val TRIP_B_DISTANCE_KM = "trip_b_distance_km"
    const val TRIP_B_TIME_SEC = "trip_b_time_sec"

    // Rolling window (Desde Última Partida) accumulated
    const val ROLLING_FUEL_L = "rolling_fuel_l"
    const val ROLLING_ENERGY_KWH = "rolling_energy_kwh"
    const val ROLLING_REGEN_KWH = "rolling_regen_kwh"
    const val ROLLING_DISTANCE_KM = "rolling_distance_km"
    const val ROLLING_SHUTDOWN_MS = "rolling_shutdown_ms"

    // Settings
    const val TANK_CAPACITY_L      = "tank_capacity_l"
    const val PRICE_GASOLINE_PER_L = "price_gasoline_per_l"
    const val PRICE_ENERGY_PER_KWH = "price_energy_per_kwh"

    // Trip history (JSON array)
    const val TRIP_HISTORY_JSON      = "trip_history_json"
    const val MAX_HISTORY_ENTRIES    = "max_history_entries"

    // Chart raw samples (JSON)
    const val TRIP_A_RAW_SAMPLES_JSON = "trip_a_raw_samples_json"
    const val TRIP_B_RAW_SAMPLES_JSON = "trip_b_raw_samples_json"

    // SOC and fuel % at trip start
    const val TRIP_A_START_SOC_PCT  = "trip_a_start_soc_pct"
    const val TRIP_B_START_SOC_PCT  = "trip_b_start_soc_pct"
    const val TRIP_A_START_FUEL_PCT = "trip_a_start_fuel_pct"
    const val TRIP_B_START_FUEL_PCT = "trip_b_start_fuel_pct"

    // Último valor recebido do carro — persistido para não zerar após reinício do app
    const val LATEST_FUEL_PCT     = "latest_fuel_pct"
    const val LATEST_SOC_PCT      = "latest_soc_pct"
    const val LATEST_OUTSIDE_TEMP = "latest_outside_temp"
    const val LATEST_INSIDE_TEMP  = "latest_inside_temp"

    // MQTT
    const val MQTT_ENABLED  = "mqtt_enabled"
    const val MQTT_HOST     = "mqtt_host"
    const val MQTT_PORT     = "mqtt_port"
    const val MQTT_USERNAME = "mqtt_username"
    const val MQTT_PASSWORD = "mqtt_password"
    const val MQTT_PREFIX            = "mqtt_prefix"
    const val MQTT_PUBLISH_INTERVAL_S = "mqtt_publish_interval_s"
}
