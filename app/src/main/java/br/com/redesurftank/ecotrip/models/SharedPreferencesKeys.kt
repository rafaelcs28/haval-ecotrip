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

    // Lifetime — nunca zera (acumulado desde a primeira instalação)
    const val LIFETIME_FUEL_L      = "lifetime_fuel_l"
    const val LIFETIME_ENERGY_KWH  = "lifetime_energy_kwh"
    const val LIFETIME_REGEN_KWH   = "lifetime_regen_kwh"
    const val LIFETIME_DISTANCE_KM = "lifetime_distance_km"
    const val LIFETIME_TIME_SEC    = "lifetime_time_sec"
    const val LIFETIME_CHARGE_KWH  = "lifetime_charge_kwh"   // kWh injetados em recargas
    const val LIFETIME_CHARGE_SEC  = "lifetime_charge_sec"   // segundos conectado ao carregador
    const val LIFETIME_CHECKPOINTS_JSON = "lifetime_checkpoints_json"  // checkpoints P↔D/R (para StatsScreen)
    const val AUTO_TRIP_HISTORY_JSON    = "auto_trip_history_json"     // viagens automáticas

    // Estado de condução + baseline do trip automático em andamento (sobrevive reinício do app)
    const val LAST_DRIVING_READY_STATE  = "last_driving_ready_state"
    const val AUTO_TRIP_START_MS        = "auto_trip_start_ms"
    const val AUTO_TRIP_START_SOC       = "auto_trip_start_soc"
    const val AUTO_TRIP_START_FUEL      = "auto_trip_start_fuel"
    const val AUTO_TRIP_START_ENERGY    = "auto_trip_start_energy"
    const val AUTO_TRIP_START_REGEN     = "auto_trip_start_regen"
    const val AUTO_TRIP_START_DIST      = "auto_trip_start_dist"
    const val AUTO_TRIP_START_FUEL_L    = "auto_trip_start_fuel_l"
    const val AUTO_TRIP_START_TIME_SEC  = "auto_trip_start_time_sec"

    // Rolling window (Desde Última Partida) accumulated
    const val ROLLING_FUEL_L = "rolling_fuel_l"
    const val ROLLING_ENERGY_KWH = "rolling_energy_kwh"
    const val ROLLING_REGEN_KWH = "rolling_regen_kwh"
    const val ROLLING_DISTANCE_KM = "rolling_distance_km"
    const val ROLLING_SHUTDOWN_MS = "rolling_shutdown_ms"
    // Rolling start bookmarks (capturados no Zerar — persistidos para sobreviver reinício do app)
    const val ROLLING_START_SOC_PCT = "rolling_start_soc_pct"
    const val ROLLING_START_TANK_L  = "rolling_start_tank_l"

    // Settings
    const val TANK_CAPACITY_L      = "tank_capacity_l"
    const val PRICE_GASOLINE_PER_L = "price_gasoline_per_l"
    const val PRICE_ENERGY_PER_KWH = "price_energy_per_kwh"

    // Trip history (JSON array)
    const val TRIP_HISTORY_JSON      = "trip_history_json"
    const val MAX_HISTORY_ENTRIES    = "max_history_entries"
    // Charge history (JSON array)
    const val CHARGE_HISTORY_JSON    = "charge_history_json"

    // Auto-trip display filter
    const val MIN_AUTO_TRIP_DIST_KM  = "min_auto_trip_dist_km"

    // Sessão de recarga em andamento — persiste para sobreviver reinício do app enquanto carregando
    const val CHARGE_SESSION_ENERGY_KWH = "charge_session_energy_kwh"
    const val CHARGE_SESSION_SEC        = "charge_session_sec"

    // IDs (startMs) de auto-trips já enviados com sucesso ao bridge
    // JSON array de Long — evita re-envio de trips já sincronizados
    const val BRIDGE_SYNCED_TRIP_IDS = "bridge_synced_trip_ids_json"

    // Chart raw samples (JSON)
    const val TRIP_A_RAW_SAMPLES_JSON = "trip_a_raw_samples_json"
    const val TRIP_B_RAW_SAMPLES_JSON = "trip_b_raw_samples_json"

    // SOC and fuel % at trip start
    const val TRIP_A_START_SOC_PCT  = "trip_a_start_soc_pct"
    const val TRIP_B_START_SOC_PCT  = "trip_b_start_soc_pct"
    const val TRIP_A_START_FUEL_PCT = "trip_a_start_fuel_pct"
    const val TRIP_B_START_FUEL_PCT = "trip_b_start_fuel_pct"

    // Session baselines — persistidos para recuperar sessão após crash/atualização do app
    const val TRIP_A_SESS_START_ENERGY = "trip_a_sess_start_energy"
    const val TRIP_A_SESS_START_REGEN  = "trip_a_sess_start_regen"
    const val TRIP_B_SESS_START_ENERGY = "trip_b_sess_start_energy"
    const val TRIP_B_SESS_START_REGEN  = "trip_b_sess_start_regen"

    // Flag: true se a sessão terminou normalmente (onSessionEnd rodou).
    // false = app fechou/travou no meio → na próxima sessão manter baselines de energia.
    const val SESSION_ENDED_CLEANLY = "session_ended_cleanly"

    // Último valor recebido do carro — persistido para não zerar após reinício do app
    const val LATEST_FUEL_PCT     = "latest_fuel_pct"
    const val LATEST_SOC_PCT      = "latest_soc_pct"
    const val LATEST_OUTSIDE_TEMP = "latest_outside_temp"
    const val LATEST_INSIDE_TEMP  = "latest_inside_temp"

    // Trips pendentes de envio ao MQTT (salvos enquanto broker estava inacessível)
    // JSON array de PendingTripPayload — sobrevive ao reinício do app
    const val PENDING_TRIP_PAYLOADS_JSON = "pending_trip_payloads_json"

    // Home Assistant export
    const val HA_EXPORT_URL = "ha_export_url"

    // URL do Bridge Node.js (iPhone PWA) — configurado manualmente pois pode diferir do broker MQTT
    const val BRIDGE_URL   = "bridge_url"
    // Senha do Bridge — enviada como Authorization: Bearer no sync de auto-trips
    const val BRIDGE_TOKEN = "bridge_token"

    // MQTT
    const val MQTT_ENABLED  = "mqtt_enabled"
    const val MQTT_HOST     = "mqtt_host"
    const val MQTT_PORT     = "mqtt_port"
    const val MQTT_USERNAME = "mqtt_username"
    const val MQTT_PASSWORD = "mqtt_password"
    const val MQTT_PREFIX            = "mqtt_prefix"
    const val MQTT_PUBLISH_INTERVAL_S           = "mqtt_publish_interval_s"           // legado (segundos)
    const val MQTT_PUBLISH_INTERVAL_MS          = "mqtt_publish_interval_ms"          // legado (ms único)
    const val MQTT_PUBLISH_INTERVAL_WIFI_MS     = "mqtt_publish_interval_wifi_ms"     // WiFi
    const val MQTT_PUBLISH_INTERVAL_CELLULAR_MS = "mqtt_publish_interval_cellular_ms" // 4G/Celular
}
