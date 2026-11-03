package br.com.redesurftank.ecotrip.managers

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
    private val appCtx: android.content.Context? = null,
) : NanoWSD(port) {

    companion object {
        // Porta default. Se 8080 estiver em uso, tenta fallbacks.
        const val LOCAL_API_PORT = 8088
        val FALLBACK_PORTS = listOf(8080, 9080, 7777, 9999)
        private const val TAG = "LocalApiServer"
        private const val MAX_FPS = 10  // throttle WS push

        // Controles físicos de toggle que o iPad (Haval Cockpit) reassenta no
        // ciclo de sync — edge-trigger por valor pra impedir reabertura sozinha
        // (teto solar voltando pra ventilação=200 depois que você fecha no botão).
        // Mesmo valor reenviado dentro da janela = reassert de estado em cache → ignora.
        private val PHYS_DEDUP_CMDS = setOf("vehicle/skylight", "vehicle/shade", "vehicle/window_all")
        private const val PHYS_DEDUP_WINDOW_MS = 120_000L

        /** Porta que conseguiu bindar — atualizada por startServer(). */
        @Volatile var activePort: Int = -1
            private set

        /** Instância viva — usada pela tela Controles embarcada p/ snapshot in-process. */
        @Volatile var current: LocalApiServer? = null
            private set
    }

    private val gson = Gson()
    private val clients = CopyOnWriteArrayList<StateWebSocket>()
    // Último comando físico aplicado por cmd: valor + timestamp. Usado pelo
    // guard anti-reassert (ver PHYS_DEDUP_CMDS).
    private val lastPhysCmd = java.util.concurrent.ConcurrentHashMap<String, Pair<String, Long>>()
    private var lastPushMs = 0L
    // Heartbeat: manda snapshot a cada 1s mesmo sem mudança no CAN. Mantém o
    // stream WS vivo (senão o iOS NWConnection seca a conexão com POSIX 96
    // "No message available on STREAM" quando o carro está parado/idle).
    private var heartbeatTimer: java.util.Timer? = null

    private val lanAuth by lazy {
        val deviceId = appCtx?.let {
            android.provider.Settings.Secure.getString(it.contentResolver, android.provider.Settings.Secure.ANDROID_ID)
        }.orEmpty()
        CameraLanAuth(deviceId, { mqttManager.bridgeToken }, System::currentTimeMillis)
    }
    private val lanDownloads by lazy { appCtx?.let(CameraLanDownloads::from) }
    private class LanLive(val id: String, val expires: Long) {
        val relay = CameraLanRelay()
        val sockets = CopyOnWriteArrayList<VideoWebSocket>()
    }
    private val lanLock = Any()
    @Volatile private var lanLive: LanLive? = null
    private var lanTimer: java.util.Timer? = null
    private val lanCommands = java.util.concurrent.Executors.newSingleThreadExecutor { task ->
        Thread(task, "camera-lan-commands").apply { isDaemon = true }
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    /** Snapshot in-process (mesmo JSON que o iPad recebe via LAN). */
    fun snapshotJson(): String = buildStateJson()

    fun startServer() {
        current = this
        try {
            start(SOCKET_READ_TIMEOUT, false)
            activePort = listeningPort
            AppLogger.i(TAG, "✓ rodando em 0.0.0.0:$activePort (bind OK, daemon=false)")
            AppLogger.i(TAG, "  teste: curl http://<ip>:$activePort/")
            startHeartbeat()
            lanTimer = java.util.Timer("camera-lan-expiry", true).apply {
                scheduleAtFixedRate(object : java.util.TimerTask() {
                    override fun run() {
                        val live = lanLive ?: return
                        val now = System.currentTimeMillis()
                        if (now >= live.expires || !CameraLanAuth.cameraAvailable(appCtx) ||
                            live.sockets.any { it.writeStarted > 0 && now - it.writeStarted > 3_000 }) endLanLive(live)
                    }
                }, 250L, 250L)
            }
        } catch (e: Exception) {
            AppLogger.e(TAG, "✗ falha ao iniciar na porta $listeningPort: ${e.message}")
            activePort = -1
        }
    }

    private fun startHeartbeat() {
        heartbeatTimer?.cancel()
        // 100ms (10 Hz): gráficos do iPad bem fluidos via LAN. Tráfego ~5 KB/s,
        // desprezível na rede local. Só envia se há clients conectados.
        heartbeatTimer = java.util.Timer("lan-ws-heartbeat", true).apply {
            scheduleAtFixedRate(object : java.util.TimerTask() {
                override fun run() {
                    if (clients.isEmpty()) return
                    val json = buildStateJson()
                    clients.forEach { ws ->
                        try { ws.send(json) } catch (_: Exception) {}
                    }
                }
            }, 100L, 100L)
        }
    }

    fun stopServer() {
        lanTimer?.cancel(); lanTimer = null
        lanLive?.let(::endLanLive)
        lanAuth.clear()
        lanCommands.shutdown()
        heartbeatTimer?.cancel(); heartbeatTimer = null
        clients.toList().forEach { try { it.close(WebSocketFrame.CloseCode.GoingAway, "shutdown", false) } catch (_: Exception) {} }
        clients.clear()
        try { stop() } catch (_: Exception) {}
        AppLogger.i(TAG, "parado")
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
                AppLogger.w(TAG, "send falhou pro client: ${e.message}")
            }
        }
    }

    // ── HTTP (NanoHTTPD) ─────────────────────────────────────────────────────

    override fun serveHttp(session: IHTTPSession): Response {
        if (session.uri == "/api/capabilities" || session.uri.startsWith("/api/video/lan/")) {
            return serveLanVideo(session)
        }
        // Sanity: bloqueia IPs fora da LAN privada
        val remote = session.remoteIpAddress ?: ""
        if (!isPrivateIp(remote)) {
            AppLogger.w(TAG, "request rejeitado de IP público: $remote")
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
                uri == "/api/rec/list" && method == Method.GET -> handleRecList()
                uri.startsWith("/api/rec/file/") && method == Method.GET -> handleRecFile(uri.removePrefix("/api/rec/file/"))
                else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404")
            }
            headers.forEach { (k, v) -> resp.addHeader(k, v) }
            resp
        } catch (e: Exception) {
            AppLogger.e(TAG, "erro processando $method $uri: ${e.message}")
            newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "500: ${e.message}")
        }
    }

    // Video routes have their own authority; legacy telemetry/control behavior is unchanged.
    override fun serve(session: IHTTPSession): Response {
        if (isWebsocketRequested(session) && session.uri.startsWith("/ws/video")) {
            val role = when (session.uri) {
                "/ws/video/lan/car" -> "producer"
                "/ws/video/lan/viewer" -> "viewer"
                else -> return lanJson(404)
            }
            val remote = session.remoteIpAddress.orEmpty()
            if (!isPrivateIp(remote) && remote != "::1" && remote != "0:0:0:0:0:0:0:1") return lanJson(403)
            if (role == "producer" && remote !in setOf("127.0.0.1", "::1", "0:0:0:0:0:0:0:1")) return lanJson(403)
            val id = lanSessionQuery(session) ?: return lanJson(401)
            val live = lanLive ?: return lanJson(401)
            if (id != live.id || !CameraLanAuth.cameraAvailable(appCtx) ||
                !lanAuth.consume(id, role, lanBearer(session))) return lanJson(401)
        }
        return super.serve(session)
    }

    private fun serveLanVideo(session: IHTTPSession): Response {
        if (!isPrivateIp(session.remoteIpAddress.orEmpty())) return lanJson(403)
        return try {
            val uri = session.uri
            val method = session.method
            if (uri == "/api/capabilities" && method == Method.GET) {
                return lanJson(200, CameraLanAuth.capabilityFields(CameraLanAuth.cameraAvailable(appCtx)))
            }
            if (uri.startsWith("/api/video/lan/session/") && method == Method.DELETE) {
                val id = uri.removePrefix("/api/video/lan/session/")
                if (!lanAuth.authorize(id, "control", lanBearer(session))) return lanJson(401)
                lanLive?.takeIf { it.id == id }?.let(::endLanLive)
                lanAuth.revoke(id)
                return lanJson(200, mapOf("ok" to true))
            }
            if (!CameraLanAuth.cameraAvailable(appCtx)) return lanJson(503)
            if (uri == "/api/video/lan/challenge" && method == Method.POST) {
                readLanBody(session)
                return lanAuth.challenge()?.let { lanJson(200, it) } ?: lanJson(401)
            }
            if (uri == "/api/video/lan/session" && method == Method.POST) {
                val body = com.google.gson.JsonParser.parseString(readLanBody(session)).asJsonObject
                val created = lanAuth.createSession(body.get("deviceId").asString, body.get("nonce").asString,
                    body.get("expiresAt").asLong, body.get("hmac").asString, body.get("scope").asString)
                    ?: return lanJson(401)
                val id = created.getValue("sessionId") as String
                if (created["scope"] == "live") {
                    val live = LanLive(id, created.getValue("expiresAt") as Long)
                    synchronized(lanLock) {
                        if (lanLive != null) { lanAuth.revoke(id); return lanJson(409) }
                        lanLive = live
                    }
                    val started = runCatching {
                        TripVideoBridge.startLanSession(id, listeningPort, created.getValue("producerToken") as String, live.expires)
                    }.getOrDefault(false)
                    if (!started || lanLive !== live) {
                        endLanLive(live)
                        // A disconnect can precede START_LIVE's acknowledgement; stop after it too.
                        lanCommands.execute { runCatching { TripVideoBridge.stopLanSession(id) } }
                        return lanJson(503)
                    }
                    return lanJson(201, (created - "producerToken") +
                        ("viewerPath" to "/ws/video/lan/viewer?session=$id"))
                }
                return lanJson(201, created)
            }
            if (method == Method.GET && (uri == "/api/video/lan/catalog" || uri.startsWith("/api/video/lan/trips/"))) {
                val id = lanSessionQuery(session) ?: return lanJson(401)
                if (!lanAuth.authorize(id, "download", lanBearer(session))) return lanJson(401)
                val downloads = lanDownloads ?: return lanJson(503)
                if (uri == "/api/video/lan/catalog") return lanJson(200, mapOf("trips" to downloads.catalog()))
                val match = Regex("/api/video/lan/trips/([^/]+)/segments/([^/]+)").matchEntire(uri) ?: return lanJson(404)
                val result = downloads.open(match.groupValues[1], match.groupValues[2], session.headers["range"])
                val code = result.getValue("status") as Int
                if (code == 404) return lanJson(404)
                if (code == 416) return lanJson(416).also { it.addHeader("Content-Range", result.getValue("contentRange").toString()) }
                val body = result.getValue("body") as java.io.InputStream
                return object : Response(if (code == 206) Response.Status.PARTIAL_CONTENT else Response.Status.OK,
                    "video/mp4", body, result.getValue("length") as Long) {
                    override fun send(output: java.io.OutputStream) {
                        try { super.send(output) } finally { runCatching { body.close() } }
                    }
                }.also {
                    it.addHeader("Accept-Ranges", "bytes")
                    it.addHeader("Cache-Control", "no-store")
                    if (code == 206) it.addHeader("Content-Range", result.getValue("contentRange").toString())
                }
            }
            lanJson(404)
        } catch (_: IllegalArgumentException) { lanJson(400) }
          catch (_: Exception) { lanJson(503) }
    }

    private fun readLanBody(session: IHTTPSession): String {
        require(session.queryParameterString.isNullOrEmpty() && session.headers["transfer-encoding"] == null)
        val size = session.headers["content-length"]?.toIntOrNull() ?: 0
        require(size in 0..4096)
        val bytes = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val n = session.inputStream.read(bytes, offset, size - offset)
            require(n > 0); offset += n
        }
        return bytes.toString(Charsets.UTF_8).ifBlank { "{}" }
    }
    private fun lanSessionQuery(session: IHTTPSession): String? =
        Regex("session=([a-f0-9]{32})").matchEntire(session.queryParameterString.orEmpty())?.groupValues?.get(1)
    private fun lanBearer(session: IHTTPSession): String = session.headers["authorization"]
        ?.takeIf { it.startsWith("Bearer ") }?.removePrefix("Bearer ").orEmpty()
    private fun lanJson(code: Int, payload: Any = mapOf("ok" to false)): Response =
        newFixedLengthResponse(Response.Status.lookup(code), "application/json", gson.toJson(payload)).also {
            it.addHeader("Cache-Control", "no-store")
        }

    private fun endLanLive(live: LanLive) {
        synchronized(lanLock) {
            if (lanLive !== live) return
            lanLive = null
            lanAuth.revoke(live.id)
            live.relay.disconnect()
        }
        live.sockets.toList().forEach { it.abort() }
        if (!lanCommands.isShutdown) lanCommands.execute { runCatching { TripVideoBridge.stopLanSession(live.id) } }
    }

    private inner class VideoWebSocket(
        handshake: IHTTPSession, private val live: LanLive, private val role: String,
    ) : WebSocket(object : IHTTPSession by handshake {
        private val bounded = CameraLanFrameInput(handshake.inputStream)
        override fun getInputStream(): java.io.InputStream = bounded
    }) {
        private val rawInput = handshake.inputStream
        @Volatile var writeStarted = 0L
        @Volatile private var ended = false
        override fun onOpen() {
            if (lanLive !== live || !lanAuth.active(live.id) || !live.relay.join(role)) { abort(); return }
            live.sockets.add(this)
            Thread({
                try {
                    while (!ended && lanLive === live) {
                        if (role == "viewer") {
                            val bytes = live.relay.poll()
                            if (bytes != null) {
                                writeStarted = System.currentTimeMillis()
                                try { send(bytes) } finally { writeStarted = 0 }
                                live.relay.delivered()
                            }
                        } else if (live.relay.takeKeyframeRequest()) {
                            writeStarted = System.currentTimeMillis()
                            try { send("{\"type\":\"request_keyframe\"}") } finally { writeStarted = 0 }
                        }
                        Thread.sleep(10)
                    }
                } catch (_: Exception) { endLanLive(live) }
            }, "camera-lan-$role").apply { isDaemon = true; start() }
        }
        fun abort() { ended = true; runCatching { rawInput.close() } }
        override fun onMessage(message: WebSocketFrame) {
            if (role != "producer" || !lanAuth.active(live.id) ||
                !live.relay.offer(message.binaryPayload, message.opCode == WebSocketFrame.OpCode.Binary)) endLanLive(live)
        }
        override fun onClose(code: WebSocketFrame.CloseCode?, reason: String?, initiatedByRemote: Boolean) {
            ended = true; live.sockets.remove(this); endLanLive(live)
        }
        override fun onException(exception: java.io.IOException) { endLanLive(live) }
        override fun onPong(pong: WebSocketFrame) { }
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

    // ── Gravações locais (LAN direto) ─────────────────────────────────────────
    private fun handleRecList(): Response {
        val ctx = appCtx ?: return newFixedLengthResponse(
            Response.Status.INTERNAL_ERROR, "application/json", """{"error":"sem contexto"}""")
        return newFixedLengthResponse(Response.Status.OK, "application/json", CabinRecorder.listJson(ctx))
    }

    private fun handleRecFile(id: String): Response {
        val ctx = appCtx ?: return newFixedLengthResponse(
            Response.Status.INTERNAL_ERROR, "text/plain", "sem contexto")
        val safe = id.substringBefore('?').filter { it.isLetterOrDigit() }
        val f = CabinRecorder.fileFor(ctx, safe)
            ?: return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "gravação não encontrada")
        val resp = newFixedLengthResponse(
            Response.Status.OK, "audio/wav", f.inputStream(), f.length())
        resp.addHeader("Content-Disposition", "attachment; filename=\"$safe.wav\"")
        resp.addHeader("Accept-Ranges", "bytes")
        return resp
    }

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

        if (cmd !in ALLOWED_COMMANDS && !cmd.startsWith("hvac/")) {
            return newFixedLengthResponse(Response.Status.BAD_REQUEST, "application/json",
                """{"ok":false,"error":"comando desconhecido: $cmd"}""")
        }

        val remote = session.remoteIpAddress ?: "?"
        val applied = relayLocalCommand(cmd, payload, "HTTP $remote")
        return newFixedLengthResponse(Response.Status.ACCEPTED, "application/json",
            """{"ok":true,"cmd":"$cmd","value":"$payload","applied":$applied}""")
    }

    /**
     * Aplica um comando vindo da LAN (HTTP ou WS) via MqttManager — mesmo handler
     * do MQTT, então o Mac mini também recebe o resultado (dual-publish).
     * Em controles físicos de toggle (PHYS_DEDUP_CMDS) descarta reassert: mesmo
     * valor reenviado dentro da janela é ignorado, pra não reabrir o teto sozinho
     * depois que você fechou no botão. `source` = origem (ex.: "WS 192.168.x.y").
     * Retorna true se aplicou, false se ignorou.
     */
    private fun relayLocalCommand(cmd: String, value: String, source: String): Boolean {
        if (cmd in PHYS_DEDUP_CMDS) {
            val now = System.currentTimeMillis()
            val last = lastPhysCmd[cmd]
            if (last != null && last.first == value && now - last.second < PHYS_DEDUP_WINDOW_MS) {
                lastPhysCmd[cmd] = value to now   // janela deslizante: zera enquanto o spam continua
                AppLogger.w(TAG, "comando $source IGNORADO (reassert $cmd='$value' < ${PHYS_DEDUP_WINDOW_MS / 1000}s)")
                return false
            }
            lastPhysCmd[cmd] = value to now
        }
        AppLogger.i(TAG, "comando $source: $cmd = '$value'")
        mqttManager.dispatchLocalCommand(cmd, value)
        return true
    }

    // ── WebSocket ────────────────────────────────────────────────────────────

    override fun openWebSocket(handshake: IHTTPSession): WebSocket {
        if (handshake.uri.startsWith("/ws/video/lan/")) {
            val live = lanLive ?: throw IllegalStateException("Session ended")
            return VideoWebSocket(handshake, live, if (handshake.uri.endsWith("/car")) "producer" else "viewer")
        }
        val remote = handshake.remoteIpAddress ?: ""
        if (!isPrivateIp(remote)) {
            AppLogger.w(TAG, "WS rejeitado de IP público: $remote — close 4003")
            // Não há jeito direto de rejeitar pre-handshake; deixa abrir e fecha
            // logo. Cliente recebe close imediato.
        }
        return StateWebSocket(handshake, this)
    }

    inner class StateWebSocket(handshake: IHTTPSession, val server: LocalApiServer) : WebSocket(handshake) {

        private val remoteIp = handshake.remoteIpAddress ?: "?"

        override fun onOpen() {
            clients.add(this)
            AppLogger.i(TAG, "WS aberto · ${clients.size} clients ativos")
            try { send(buildStateJson()) } catch (_: Exception) {}
        }

        override fun onClose(code: WebSocketFrame.CloseCode?, reason: String?, initiatedByRemote: Boolean) {
            clients.remove(this)
            AppLogger.i(TAG, "WS fechado: $code/$reason · ${clients.size} restantes")
        }

        override fun onMessage(message: WebSocketFrame) {
            // iPad só recebe — não esperamos mensagens. Mas se vier "ping" texto,
            // responde "pong" pra cliente medir latência.
            val txt = message.textPayload ?: return
            if (txt == "ping") { try { send("pong") } catch (_: Exception) {}; return }
            // Comando via WS: {"__cmd":"esp","value":1} — iPad manda comandos
            // pelo WS porque URLSession POST é bloqueado pelo Local Network
            // Privacy do iOS. Delega pro MqttManager (mesmo handler do MQTT).
            try {
                @Suppress("UNCHECKED_CAST")
                val map = gson.fromJson(txt, Map::class.java) as? Map<String, Any?> ?: return
                val cmd = map["__cmd"]?.toString() ?: return
                val value = (map["value"] ?: map["enable"] ?: map["mode"] ?: map["level"] ?: map["pct"])
                    ?.toString()?.trim()?.removeSuffix(".0") ?: ""
                if (cmd in ALLOWED_COMMANDS || cmd.startsWith("hvac/")) {
                    relayLocalCommand(cmd, value, "WS $remoteIp")
                }
            } catch (e: Exception) {
                AppLogger.w(TAG, "WS cmd parse falhou: ${e.message}")
            }
        }

        override fun onPong(pong: WebSocketFrame) { /* heartbeat OK */ }

        override fun onException(exception: java.io.IOException) {
            AppLogger.w(TAG, "WS exception: ${exception.message}")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    // Cortina/teto: leitura ATIVA via AIDL é cara p/ chamar a 10Hz (heartbeat do WS).
    // Throttle: relê no máximo 1x/s e serve o cache. Assim o WS reflete em ~1s na LAN
    // (em vez dos ~2.5s do poll cloud), sem 20 chamadas de binder por segundo.
    private var _shadeAtMs = 0L; private var _shadeVal = -1
    private var _skyAtMs = 0L;   private var _skyVal = -1
    private fun cachedShade(): Int? {
        val now = System.currentTimeMillis()
        if (now - _shadeAtMs > 1000L) { _shadeAtMs = now; VehicleControlManager.getShadeScreensLevel()?.let { _shadeVal = it } }
        return if (_shadeVal >= 0) _shadeVal else null
    }
    private fun cachedSkylight(): Int? {
        val now = System.currentTimeMillis()
        if (now - _skyAtMs > 1000L) { _skyAtMs = now; VehicleControlManager.getSkylightLevel()?.let { _skyVal = it } }
        return if (_skyVal >= 0) _skyVal else null
    }
    // Autonomia de combustível REAL do CAN (a do painel) — car.ev_info.fuel_mode_remain_odometer.
    // Throttle 1s; substitui o sensor HA legado (range_ice_km) que reportava tanque cheio.
    private var _fuelRemAtMs = 0L; private var _fuelRemVal = -1
    private fun cachedFuelRemain(): Int? {
        val now = System.currentTimeMillis()
        if (now - _fuelRemAtMs > 1000L) { _fuelRemAtMs = now
            CarDataManager.getInstance().fetchCurrent("car.ev_info.fuel_mode_remain_odometer")?.trim()?.toFloatOrNull()?.let { _fuelRemVal = it.toInt() } }
        return if (_fuelRemVal >= 0) _fuelRemVal else null
    }
    // Autonomia elétrica real do CAN — car.ev_info.electric_mode_remain_odometer.
    private var _evRemAtMs = 0L; private var _evRemVal = -1
    private fun cachedEvRemain(): Int? {
        val now = System.currentTimeMillis()
        if (now - _evRemAtMs > 1000L) { _evRemAtMs = now
            CarDataManager.getInstance().fetchCurrent("car.ev_info.electric_mode_remain_odometer")?.trim()?.toFloatOrNull()?.let { _evRemVal = it.toInt() } }
        return if (_evRemVal >= 0) _evRemVal else null
    }
    // % de combustível no tanque — car.basic.remain_fuel_percentage (litros = pct × 55/100 no iPad).
    private var _fuelPctAtMs = 0L; private var _fuelPctVal = -1
    private val _fuelFilter = MedianFilter(7)   // suaviza o ruído do sensor no display
    private fun cachedFuelPct(): Int? {
        val now = System.currentTimeMillis()
        if (now - _fuelPctAtMs > 1000L) { _fuelPctAtMs = now
            CarDataManager.getInstance().fetchCurrent("car.basic.remain_fuel_percentage")?.trim()?.toFloatOrNull()?.let { _fuelPctVal = _fuelFilter.push(it).toInt() } }
        return if (_fuelPctVal >= 0) _fuelPctVal else null
    }
    private fun buildStateJson(): String {
        val m = mqttManager
        // Escopo HÍBRIDO: APK serve só telemetria RAW fast (que muda rápido +
        // tem valor cru direto do CAN). Dados calculados (trip cost, history,
        // soc_pct consolidado, fuel_l preciso, etc) continuam vindo do Mac mini
        // via Tailscale — o iPad consome ambos em paralelo.
        // Potência de recarga AC derivada (V × A / 1000) quando carregando
        val chargePowerKw = if (m.latestChargingState == 1)
            (m.latestBatteryVoltageV * m.latestChargeCurrentA) / 1000f else 0f
        val data = linkedMapOf<String, Any?>(
            "source"            to "havalobd-apk-local",
            "ts"                to System.currentTimeMillis(),
            // ── Telemetria movimento ──
            "speed_kmh"         to m.latestSpeedKmh,
            "motor_power_kw"    to m.latestMotorPowerKw,
            "engine_rpm"        to m.latestEngineRpm,
            "batt_power_pct"    to m.latestBattPowerPct,
            "steering_angle"    to m.latestSteeringAngle,
            "gear"              to m.latestGear,
            "odometer_km"       to m.latestOdometerKm,
            "driving_ready"     to m.latestDrivingReadyState,
            // ── Bateria de tração / elétrico ──
            "soc_pct"           to (if (m.latestSocPct > 0f) m.latestSocPct.toInt() else null),
            "battery_current_a" to m.latestBatteryCurrentA,
            "pack_voltage_v"    to m.latestBatteryVoltageV,
            "batt_12v_pct"      to m.latestBatt12vPct,
            // ── Uplink de internet (roteamento do head unit: Starlink vs 4G) ──
            "uplink"            to UplinkManager.current(),   // WLAN(Starlink)/4G/OFF/?
            // ── Recarga ──
            "charging_state"    to m.latestChargingState,
            "charge_current_a"  to m.latestChargeCurrentA,
            "charge_power_kw"   to chargePowerKw,
            "charge_remaining_min" to m.latestChargeRemainingMin,
            // ── Clima / HVAC ──
            "outside_temp"      to m.latestOutsideTemp,
            "inside_temp"       to m.latestInsideTemp,
            "ac_state"          to m.latestHvacAcEnable,
            "hvac_driver_temp"  to m.latestHvacDriverTemp,
            "hvac_passenger_temp" to m.latestHvacPassengerTemp,
            "hvac_fan_speed"    to m.latestHvacFanSpeed,
            "hvac_sync_enable"  to m.latestHvacSyncEnable,
            "hvac_auto_enable"  to m.latestHvacAutoEnable,
            "hvac_cycle_mode"   to m.latestHvacCycleMode,
            "hvac_acmax"        to m.latestHvacAcMax,
            "hvac_anion"        to m.latestHvacAnion,
            "hvac_aqs"          to m.latestHvacAqs,
            "hvac_heating"      to m.latestHvacHeating,
            "hvac_front_defrost" to m.latestHvacFrontDefrost,
            "hvac_rear_defrost" to m.latestHvacRearDefrost,
            "hvac_auto_defrost" to m.latestHvacAutoDefrost,
            "hvac_pm25"         to m.latestHvacPm25,
            "hvac_blower_mode"  to m.latestHvacBlowerMode,
            "hvac_power_mode"   to m.latestHvacPowerMode,
            "seat_vent_drv"     to m.latestDriverSeatVent,
            "seat_vent_pass"    to m.latestPassengerSeatVent,
            // Aberturas (leitura ativa, throttled 1s) — reflexo rápido em LAN
            "shade_level"       to cachedShade(),     // cortina: 0..100
            "skylight_level"    to cachedSkylight(),  // teto: 0=fechado·200=vent·1..100=%
            "fuel_remain_km"    to cachedFuelRemain(),// autonomia ICE real do CAN (painel)
            "ev_remain_km"      to cachedEvRemain(),  // autonomia EV real do CAN
            "fuel_pct_can"      to cachedFuelPct(),   // % combustível no tanque (CAN)
            // ── Estados dos controles drive (confirmação visual rápida) ──
            // -1 = ainda não lido do carro → null pra não sobrescrever.
            "drive_mode"        to m.lastPublishedDriveMode.takeIf { it >= 0 },
            "power_reserve"     to m.lastPublishedPowerReserve.takeIf { it >= 0 },   // 1=intel., 2=prior.
            "charge_soc_target" to m.lastPublishedSocTarget.takeIf { it >= 0 },      // % a preservar
            "terrain_mode"      to m.lastPublishedTerrainMode.takeIf { it >= 0 },
            "regen_level"       to m.lastPublishedRegenLevel.takeIf { it >= 0 },
            "steer_mode"        to m.lastPublishedSteerMode.takeIf { it >= 0 },
            "one_pedal"         to m.lastPublishedOnePedal.takeIf { it >= 0 },
            "esp_enable"        to m.lastPublishedEsp.takeIf { it >= 0 },
            // ── Chaves CRUAS do barramento, no nome do próprio CarConstants ──
            //
            // Pro viewer 3D (Haval-H6-3D), que fala esse vocabulário nativamente.
            // Mandar o valor CRU e não o nosso normalizado 'on'/'off' evita um
            // round-trip que perde informação: `door_status` e `window_status` são
            // vetores por slot (o porta-malas é o slot 5, não o 4) e vidro tem
            // quatro estados (0=movendo 1=fechado 2=aberto 3=parcial), não dois.
            // Traduzir pra booleano e traduzir de volta erra nos dois sentidos.
            //
            // Sub-objeto separado de propósito: o `state` de cima é o contrato do
            // iPad e não muda: quem não conhece `car` simplesmente ignora.
            // Chaves que o viewer pede e que não têm campo normalizado nosso —
            // luzes, EPB, auto-hold, espelhos, médias de consumo. Saem do mapa CRU
            // do CarDataManager, então basta a chave existir no CarConstants: não
            // precisa de campo nem de case novo aqui quando o viewer pedir mais.
            "car_raw" to CarDataManager.getInstance().rawCarValues,
            "car" to linkedMapOf<String, Any?>(
                "car.basic.door_status"          to m.latestDoorStatusRaw.ifEmpty { null },
                "car.basic.window_status"        to m.latestWindowStatusRaw.ifEmpty { null },
                "car.basic.door_lock_status"     to m.latestLockStatus,
                // Teto e cortina já vêm em percentual do CAN (0=fechado, 200=vent,
                // 1..100=%), que é exatamente a escala que o viewer desenha.
                "car.basic.sunroof_status"       to cachedSkylight(),
                "car.basic.sunshade_status"      to cachedShade(),
                "car.basic.vehicle_speed"        to m.latestSpeedKmh,
                // CRU (0=N 2=D 3=P 4=R), não a letra: este bloco é contrato de
                // chave crua, e o viewer 3D faz parseInt — "R" virava NaN.
                "car.basic.gear_status"          to m.latestGearRaw.ifEmpty { null },
                "car.basic.driving_ready_state"  to m.latestDrivingReadyState,
                "car.basic.steering_wheel_angle" to m.latestSteeringAngle,
                "car.basic.seat_belt_warning"    to m.latestSeatBeltWarning,
                "car.basic.tpms_warning"         to m.latestTpmsWarning.takeIf { it >= 0 },
                "car.basic.low_beam_light_status" to m.latestFrontLight,
            ),
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
            "power_reserve", "charge_soc_target",   // sub-modo HEV (iPad)
            "hazard",   // pisca-alerta (4 setas) — alterna car.light_setting.sport_mode_light
            // Controles físicos com valor único (iPad): cortina 0..100, teto 0/200/10..100,
            // vidros (todos) 1=fechado/3=entreaberto/0=aberto.
            // (porta usa payload-objeto e segue só por MQTT, fora da via LAN.)
            "vehicle/shade", "vehicle/skylight", "vehicle/window_all",
        )
    }
}

private val ALLOWED_COMMANDS = LocalApiServer.ALLOWED_COMMANDS_HOLDER.SET
