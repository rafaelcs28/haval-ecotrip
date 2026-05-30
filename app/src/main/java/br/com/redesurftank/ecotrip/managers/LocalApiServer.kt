package br.com.redesurftank.ecotrip.managers

import android.util.Log
import com.google.gson.Gson
import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoWSD
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Servidor HTTP + WebSocket leve embutido no APK do carro.
 *
 * Objetivo: quando iPad e carro estão na mesma LAN (hotspot do iPad, WiFi
 * compartilhado), iPad fala direto com o APK sem passar pelo Mac mini —
 * latência LAN (~5ms) em vez de Tailscale internet (~100-300ms).
 *
 * Escopo (HÍBRIDO):
 *   • Telemetria RAW em tempo real (rpm, kW, speed, GPS, SOC, status) — fast
 *   • Comandos drive (ESP, modo, regen, etc) — aplica via SDK GWM no APK
 *   • NÃO serve cálculos complexos (trip cost, history) — iPad usa Mac mini
 *     via Tailscale como fallback pra esses
 *
 * Endpoints:
 *   GET  /              → status: {ok, version, ts}
 *   GET  /api/state     → snapshot raw das últimas leituras do CAN
 *   POST /api/cmd/{cmd} → aplica via SDK GWM. cmd ∈ {esp, one_pedal, drive_mode,
 *                          terrain_mode, regen_level, steer_mode}
 *   WS   /ws/state      → push do snapshot a cada mudança relevante (10 fps max)
 *
 * Segurança: nenhuma (LAN privada). Aceita só requests vindo da mesma /24
 * (rede privada). Em IP público responde 403. Isso evita acidente se o iPad
 * configurar hotspot público por engano.
 */
class LocalApiServer(
    private val mqttManager: MqttManager,
    port: Int = LOCAL_API_PORT,
) : NanoWSD(port) {

    companion object {
        const val LOCAL_API_PORT = 8080
        private const val TAG = "LocalApiServer"
        private const val MAX_FPS = 10  // throttle WS push
    }

    private val gson = Gson()
    private val clients = CopyOnWriteArrayList<StateWebSocket>()
    private var lastPushMs = 0L

    // ── Lifecycle ────────────────────────────────────────────────────────────

    fun startServer() {
        try {
            start(SOCKET_READ_TIMEOUT, false)
            Log.i(TAG, "rodando em :$LOCAL_API_PORT (${clients.size} clients)")
        } catch (e: Exception) {
            Log.e(TAG, "falha ao iniciar: ${e.message}")
        }
    }

    fun stopServer() {
        clients.toList().forEach { try { it.close(WebSocketFrame.CloseCode.GoingAway, "shutdown", false) } catch (_: Exception) {} }
        clients.clear()
        try { stop() } catch (_: Exception) {}
        Log.i(TAG, "parado")
    }

    /**
     * Chamado pelo MqttManager quando o snapshot interno muda. Faz push pros
     * WS clients (throttle 10 fps).
     */
    fun notifyStateChange() {
        val now = System.currentTimeMillis()
        if (now - lastPushMs < 1000L / MAX_FPS) return
        lastPushMs = now
        if (clients.isEmpty()) return
        val json = buildStateJson()
        clients.forEach { ws ->
            try { ws.send(json) } catch (e: Exception) {
                Log.w(TAG, "send falhou pro client: ${e.message}")
            }
        }
    }

    // ── HTTP (NanoHTTPD) ─────────────────────────────────────────────────────

    override fun serveHttp(session: IHTTPSession): Response {
        // Sanity: bloqueia IPs fora da LAN privada
        val remote = session.remoteIpAddress ?: ""
        if (!isPrivateIp(remote)) {
            Log.w(TAG, "request rejeitado de IP público: $remote")
            return newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "LAN only")
        }

        val uri = session.uri
        val method = session.method

        // CORS pra desenvolvimento (iPad WKWebView faz preflight)
        val headers = mapOf(
            "Access-Control-Allow-Origin"  to "*",
            "Access-Control-Allow-Headers" to "Content-Type, X-Cluster",
            "Access-Control-Allow-Methods" to "GET, POST, OPTIONS",
        )
        if (method == Method.OPTIONS) {
            return newFixedLengthResponse(Response.Status.NO_CONTENT, "text/plain", "").also {
                headers.forEach { (k, v) -> it.addHeader(k, v) }
            }
        }

        return try {
            val resp = when {
                uri == "/" && method == Method.GET -> handleRoot()
                uri == "/api/state" && method == Method.GET -> handleState()
                uri.startsWith("/api/cmd/") && method == Method.POST -> handleCommand(session, uri.removePrefix("/api/cmd/"))
                else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404")
            }
            headers.forEach { (k, v) -> resp.addHeader(k, v) }
            resp
        } catch (e: Exception) {
            Log.e(TAG, "erro processando $method $uri: ${e.message}")
            newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "500: ${e.message}")
        }
    }

    private fun handleRoot(): Response {
        val payload = mapOf(
            "ok" to true,
            "service" to "haval-ecotrip-apk",
            "ts" to System.currentTimeMillis(),
        )
        return newFixedLengthResponse(Response.Status.OK, "application/json", gson.toJson(payload))
    }

    private fun handleState(): Response =
        newFixedLengthResponse(Response.Status.OK, "application/json", buildStateJson())

    private fun handleCommand(session: IHTTPSession, cmd: String): Response {
        // Lê body
        val body = HashMap<String, String>()
        session.parseBody(body)
        val rawBody = body["postData"] ?: ""
        val payload = try {
            // Aceita {"value": X} ou {"enable": X} ou {"mode": X} ou {"level": X}
            val parsed = gson.fromJson(rawBody, Map::class.java) as? Map<*, *>
            (parsed?.get("value") ?: parsed?.get("enable") ?: parsed?.get("mode") ?: parsed?.get("level"))
                ?.toString()?.trim()?.removeSuffix(".0") ?: ""
        } catch (e: Exception) {
            return newFixedLengthResponse(Response.Status.BAD_REQUEST, "application/json",
                """{"ok":false,"error":"json inválido: ${e.message}"}""")
        }

        if (cmd !in ALLOWED_COMMANDS) {
            return newFixedLengthResponse(Response.Status.BAD_REQUEST, "application/json",
                """{"ok":false,"error":"comando desconhecido: $cmd"}""")
        }

        // Delega pro MqttManager — mesmo handler usado pelo MQTT pro Mac mini.
        // Isso garante que o Mac mini também recebe o resultado via MQTT (dual-publish).
        Log.i(TAG, "comando local: $cmd = '$payload'")
        mqttManager.dispatchLocalCommand(cmd, payload)

        return newFixedLengthResponse(Response.Status.ACCEPTED, "application/json",
            """{"ok":true,"cmd":"$cmd","value":"$payload"}""")
    }

    // ── WebSocket ────────────────────────────────────────────────────────────

    override fun openWebSocket(handshake: IHTTPSession): WebSocket {
        val remote = handshake.remoteIpAddress ?: ""
        if (!isPrivateIp(remote)) {
            Log.w(TAG, "WS rejeitado de IP público: $remote — close 4003")
            // Não há jeito direto de rejeitar pre-handshake; deixa abrir e fecha
            // logo. Cliente recebe close imediato.
        }
        return StateWebSocket(handshake, this)
    }

    inner class StateWebSocket(handshake: IHTTPSession, val server: LocalApiServer) : WebSocket(handshake) {

        override fun onOpen() {
            clients.add(this)
            Log.i(TAG, "WS aberto · ${clients.size} clients ativos")
            try { send(buildStateJson()) } catch (_: Exception) {}
        }

        override fun onClose(code: WebSocketFrame.CloseCode?, reason: String?, initiatedByRemote: Boolean) {
            clients.remove(this)
            Log.i(TAG, "WS fechado: $code/$reason · ${clients.size} restantes")
        }

        override fun onMessage(message: WebSocketFrame) {
            // iPad só recebe — não esperamos mensagens. Mas se vier "ping" texto,
            // responde "pong" pra cliente medir latência.
            val txt = message.textPayload ?: return
            if (txt == "ping") try { send("pong") } catch (_: Exception) {}
        }

        override fun onPong(pong: WebSocketFrame) { /* heartbeat OK */ }

        override fun onException(exception: java.io.IOException) {
            Log.w(TAG, "WS exception: ${exception.message}")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun buildStateJson(): String {
        val m = mqttManager
        // Escopo HÍBRIDO: APK serve só telemetria RAW fast (que muda rápido +
        // tem valor cru direto do CAN). Dados calculados (trip cost, history,
        // soc_pct consolidado, fuel_l preciso, etc) continuam vindo do Mac mini
        // via Tailscale — o iPad consome ambos em paralelo.
        val data = linkedMapOf<String, Any?>(
            "source"            to "havalobd-apk-local",
            "ts"                to System.currentTimeMillis(),
            // Telemetria fast (alvo principal do canal LAN)
            "speed_kmh"         to m.latestSpeedKmh,
            "motor_power_kw"    to m.latestMotorPowerKw,
            "engine_rpm"        to m.latestEngineRpm,
            "battery_current_a" to m.latestBatteryCurrentA,
            "pack_voltage_v"    to m.latestBatteryVoltageV,
            "batt_power_pct"    to m.latestBattPowerPct,
            "charging_state"    to m.latestChargingState,
            "outside_temp"      to m.latestOutsideTemp,
            "inside_temp"       to m.latestInsideTemp,
            "ac_state"          to m.latestHvacAcEnable,
            "gear"              to m.latestGear,
            "odometer_km"       to m.latestOdometerKm,
            "steering_angle"    to m.latestSteeringAngle,
        )
        return gson.toJson(data)
    }

    /** /24 simples: 10.x, 192.168.x, 172.16-31.x, 127.x, link-local 169.254.x */
    private fun isPrivateIp(ip: String): Boolean {
        if (ip.startsWith("127.")) return true
        if (ip.startsWith("10.")) return true
        if (ip.startsWith("192.168.")) return true
        if (ip.startsWith("169.254.")) return true
        if (ip.startsWith("172.")) {
            val second = ip.split(".").getOrNull(1)?.toIntOrNull() ?: return false
            return second in 16..31
        }
        // IPv6 link-local: fe80::/10
        if (ip.startsWith("fe80:", ignoreCase = true)) return true
        return false
    }

    object ALLOWED_COMMANDS_HOLDER {
        val SET = setOf(
            "esp", "one_pedal", "drive_mode", "terrain_mode",
            "regen_level", "steer_mode", "charge_limit", "hf_mode",
        )
    }
}

private val ALLOWED_COMMANDS = LocalApiServer.ALLOWED_COMMANDS_HOLDER.SET
