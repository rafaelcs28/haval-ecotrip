package br.com.redesurftank.ecotrip.managers

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Motor de automações que roda DENTRO do carro, de forma autônoma (sem telefone
 * nem internet). As regras são criadas no iPhone/iPad, entregues pelo bridge via
 * MQTT retido (cmd/rules/set) e persistidas localmente. A avaliação se pendura
 * nos eventos que o APK já processa — mudança de estado (CarDataManager) e GPS
 * (TripManager) — mais um tick leve de 3s pra geofence/horário. Sem polling pesado.
 *
 * Gatilhos:  geofence(enter|exit) · time(hhmm + dias) · state(campo muda)
 * Condições: AND/OR de comparações sobre o estado do carro (chave do bus)
 * Ações:     window · skylight · shade · door · request(chave do bus = valor)
 *
 * Sem guardrails implícitos: a regra do usuário é a única trava (decisão dele).
 */
object AutomationManager {
    private const val TAG = "AutomationManager"
    private const val FILE = "automations.json"

    private lateinit var appContext: Context
    private val tick = Executors.newSingleThreadScheduledExecutor()
    private val lock = Any()
    @Volatile private var initialized = false

    private var rules: List<Rule> = emptyList()
    private val state = HashMap<String, String>()          // chave do bus → último valor
    private val inside = HashMap<String, Boolean>()         // ruleId → dentro do geofence?
    private val lastFiredMs = HashMap<String, Long>()       // ruleId → último disparo
    private val lastFiredMinute = HashMap<String, Int>()    // ruleId → minuto do dia já disparado (time)
    private val geofenceLastInside = HashMap<String, Long>() // coordKey → última vez dentro (ms) — p/ condição "visited"
    private val lastSatisfiedMs = HashMap<String, Long>()    // "field|cmp|value" → última vez que o predicado foi verdadeiro (p/ condição "recent")

    /** Callback pra publicar disparos (MqttManager seta isto). */
    @Volatile var onFired: ((ruleId: String, name: String, ok: Boolean) -> Unit)? = null

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        appContext = context.applicationContext
        loadFromDisk()
        // Estado do carro: reavalia regras a cada mudança (event-driven, custo ~0).
        CarDataManager.getInstance().addListener { key, value ->
            synchronized(lock) { state[key] = value }
            evaluate(stateKey = key)
        }
        // Tick leve pra geofence + horário (1s p/ disparo rápido ao chegar/sair).
        // Só matemática trivial (haversine) sobre poucas regras — custo desprezível.
        tick.scheduleWithFixedDelay({
            try { evaluate(stateKey = null) } catch (e: Exception) { AppLogger.w(TAG, "tick: ${e.message}") }
        }, 1, 1, TimeUnit.SECONDS)
        AppLogger.i(TAG, "AutomationManager iniciado (${rules.size} regras)")
    }

    // ── Regras: recebimento + persistência ─────────────────────────────────────

    /** Substitui o conjunto de regras (JSON array). Chamado pelo cmd/rules/set. */
    fun setRules(json: String) {
        try {
            val parsed = parseRules(json)
            synchronized(lock) {
                rules = parsed
                // Reseta estado transiente das regras que sumiram; mantém o resto.
                val ids = parsed.map { it.id }.toSet()
                inside.keys.retainAll(ids)
                lastFiredMs.keys.retainAll(ids)
                lastFiredMinute.keys.retainAll(ids)
            }
            saveToDisk(json)
            AppLogger.i(TAG, "Regras atualizadas: ${parsed.size}")
        } catch (e: Exception) {
            AppLogger.e(TAG, "setRules falhou: ${e.message}")
        }
    }

    private fun loadFromDisk() {
        try {
            val f = File(appContext.filesDir, FILE)
            if (f.exists()) rules = parseRules(f.readText())
        } catch (e: Exception) { AppLogger.w(TAG, "loadFromDisk: ${e.message}") }
    }

    private fun saveToDisk(json: String) {
        try { File(appContext.filesDir, FILE).writeText(json) }
        catch (e: Exception) { AppLogger.w(TAG, "saveToDisk: ${e.message}") }
    }

    // ── Avaliação ───────────────────────────────────────────────────────────────

    private fun evaluate(stateKey: String?) {
        val snapshot = synchronized(lock) { rules }
        if (snapshot.isEmpty()) return
        val now = System.currentTimeMillis()
        val (lat, lng) = TripManager.getInstance().getLastGps()
        val hasGps = !(lat == 0.0 && lng == 0.0)
        if (hasGps) updateVisits(snapshot, lat, lng, now)      // rastreia passagem por pontos (p/ condição "visited")
        refreshDynamicFields(snapshot)                          // popula chaves "sob demanda" (ex: rain_intensity)
        trackRecent(snapshot, now)                              // rastreia "última vez que o predicado foi verdade" (p/ "recent")
        for (r in snapshot) {
            if (!r.enabled) continue
            try {
                val fire = when (r.trigger.type) {
                    "geofence" -> if (hasGps) checkGeofence(r, lat, lng) else false
                    "time"     -> if (stateKey == null) checkTime(r, now) else false
                    "state"    -> {
                        if (stateKey == null) {
                            // Tick: lê o valor fresco do barramento e checa a borda — assim o
                            // disparo (ex: fechar vidro ao atingir X km/h) não fica preso à
                            // cadência de publish do MQTT.
                            CarDataManager.getInstance().fetchCurrent(r.trigger.field)?.let { v ->
                                synchronized(lock) { state[r.trigger.field] = v }
                            }
                            checkStateEdge(r)
                        } else if (stateKey == r.trigger.field) checkStateEdge(r) else false
                    }
                    else       -> false
                }
                if (!fire) continue
                if (!conditionsPass(r.conditions, now)) continue
                val last = lastFiredMs[r.id] ?: 0L
                if (r.debounceS > 0 && now - last < r.debounceS * 1000L) continue
                lastFiredMs[r.id] = now
                val ok = runAction(r.action)
                AppLogger.i(TAG, "Regra '${r.name}' disparou → ${r.action.type} (ok=$ok)")
                onFired?.invoke(r.id, r.name, ok)
            } catch (e: Exception) {
                AppLogger.w(TAG, "avaliar '${r.name}': ${e.message}")
            }
        }
    }

    private fun coordKey(lat: Double, lng: Double, radius: Double) =
        "%.5f,%.5f,%.0f".format(lat, lng, radius)

    // Marca a passagem por TODOS os pontos referenciados (gatilhos geofence +
    // condições "visited"), pra a condição "visited" saber se o carro passou lá.
    private fun updateVisits(rules: List<Rule>, lat: Double, lng: Double, now: Long) {
        for (r in rules) {
            if (r.trigger.type == "geofence")
                markVisitIfInside(lat, lng, r.trigger.lat, r.trigger.lng, r.trigger.radiusM, now)
            r.conditions?.items?.forEach { c ->
                if (c.type == "visited") {
                    if (c.points.isNotEmpty()) c.points.forEach { p -> markVisitIfInside(lat, lng, p.lat, p.lng, p.radiusM, now) }
                    else markVisitIfInside(lat, lng, c.lat, c.lng, c.radiusM, now)
                }
            }
        }
    }
    private fun markVisitIfInside(lat: Double, lng: Double, plat: Double, plng: Double, radius: Double, now: Long) {
        if (haversine(lat, lng, plat, plng) <= radius) geofenceLastInside[coordKey(plat, plng, radius)] = now
    }

    // Chaves que não são do barramento normal e precisam ser lidas via IVehicle sob
    // demanda (só quando alguma regra as referencia). Ex: rain_intensity.
    private fun refreshDynamicFields(rules: List<Rule>) {
        val refs = HashSet<String>()
        for (r in rules) {
            if (r.trigger.type == "state") refs.add(r.trigger.field)
            r.conditions?.items?.forEach { if (it.type != "visited") refs.add(it.field) }
        }
        if (refs.contains("rain_intensity")) {
            VehicleControlManager.getRainIntensity()?.let { synchronized(lock) { state["rain_intensity"] = it.toString() } }
        }
    }

    // Pra cada condição "recent", se o predicado (campo cmp valor) é verdade AGORA,
    // grava o timestamp. Depois conditionsPass checa se foi (ou não) dentro da janela.
    private fun recentKey(c: Condition) = "${c.field}|${c.cmp}|${c.value}"
    private fun trackRecent(rules: List<Rule>, now: Long) {
        for (r in rules) {
            r.conditions?.items?.forEach { c ->
                if (c.type == "recent" && compareField(c.field, c.cmp, c.value)) lastSatisfiedMs[recentKey(c)] = now
            }
        }
    }

    private fun checkGeofence(r: Rule, lat: Double, lng: Double): Boolean {
        val d = haversine(lat, lng, r.trigger.lat, r.trigger.lng)
        val nowInside = d <= r.trigger.radiusM
        val prev = inside[r.id]
        inside[r.id] = nowInside
        if (prev == null) return false                        // primeira leitura: sem borda
        return when (r.trigger.edge) {
            "enter" -> !prev && nowInside
            "exit"  -> prev && !nowInside
            else    -> false
        }
    }

    private fun checkTime(r: Rule, now: Long): Boolean {
        val cal = java.util.Calendar.getInstance()
        val minuteOfDay = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        if (minuteOfDay != r.trigger.hhmm) return false
        // Dia da semana: Calendar DOM 1=Dom..7=Sáb → 0..6
        val dow = cal.get(java.util.Calendar.DAY_OF_WEEK) - 1
        if (r.trigger.days.isNotEmpty() && !r.trigger.days.contains(dow)) return false
        if (lastFiredMinute[r.id] == minuteOfDay) return false   // já disparou neste minuto
        lastFiredMinute[r.id] = minuteOfDay
        return true
    }

    // Gatilho "state": dispara quando o valor da chave passa a satisfazer cmp/value
    // (borda de subida — não estava satisfazendo antes desta mudança).
    private val stateTrigSatisfied = HashMap<String, Boolean>()
    private fun checkStateEdge(r: Rule): Boolean {
        val cur = compareField(r.trigger.field, r.trigger.cmp, r.trigger.value)
        val prev = stateTrigSatisfied[r.id] ?: false
        stateTrigSatisfied[r.id] = cur
        return cur && !prev
    }

    private fun conditionsPass(group: ConditionGroup?, now: Long): Boolean {
        if (group == null || group.items.isEmpty()) return true
        val results = group.items.map { c ->
            when (c.type) {
                "visited" -> {
                    // Verdadeiro se passou por QUALQUER ponto nos últimos within_s (default 600s).
                    val janela = (if (c.withinS > 0) c.withinS else 600) * 1000L
                    val pts = if (c.points.isNotEmpty()) c.points else listOf(VPoint(c.lat, c.lng, c.radiusM))
                    pts.any { p ->
                        val last = geofenceLastInside[coordKey(p.lat, p.lng, p.radiusM)]
                        last != null && now - last <= janela
                    }
                }
                "recent" -> {
                    // O predicado (campo cmp valor) foi verdade nos últimos within_s?
                    // negate=true → passa quando NÃO foi (ex: limpador não acionou nos últimos 60s).
                    val last = lastSatisfiedMs[recentKey(c)]
                    val within = last != null && now - last <= (if (c.withinS > 0) c.withinS else 60) * 1000L
                    if (c.negate) !within else within
                }
                else -> compareField(c.field, c.cmp, c.value)
            }
        }
        return if (group.op == "OR") results.any { it } else results.all { it }
    }

    private fun compareField(field: String, cmp: String, value: String): Boolean {
        // Lê do cache (chaves já assinadas) e, se não tiver, busca direto no carro.
        // Assim QUALQUER chave do barramento serve de condição sem precisar atualizar
        // o APK — basta a regra referenciar a chave.
        val cur = synchronized(lock) { state[field] }
            ?: CarDataManager.getInstance().fetchCurrent(field)?.also { synchronized(lock) { state[field] = it } }
            ?: return false
        val a = cur.toDoubleOrNull()
        val b = value.toDoubleOrNull()
        return if (a != null && b != null) when (cmp) {
            "==" -> a == b; "!=" -> a != b; ">" -> a > b; "<" -> a < b; ">=" -> a >= b; "<=" -> a <= b
            else -> false
        } else when (cmp) {
            "==" -> cur == value; "!=" -> cur != value
            else -> false
        }
    }

    private fun runAction(a: Action): Boolean = when (a.type) {
        "window"   -> if (a.all) VehicleControlManager.setAllWindows(a.status)
                      else VehicleControlManager.setWindowStatus(a.window, a.status)
        "skylight" -> VehicleControlManager.setSkylightLevel(a.level)
        "shade"    -> VehicleControlManager.setShadeScreensLevel(a.level)
        "door"     -> VehicleControlManager.setDoorOpen(a.p1, a.p2)
        "request"  -> CarDataManager.getInstance().requestSetting(a.key, a.value)
        else       -> false
    }

    private fun haversine(la1: Double, lo1: Double, la2: Double, lo2: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(la2 - la1); val dLon = Math.toRadians(lo2 - lo1)
        val h = sin(dLat / 2) * sin(dLat / 2) +
                cos(Math.toRadians(la1)) * cos(Math.toRadians(la2)) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    // ── Parsing ──────────────────────────────────────────────────────────────────

    private fun parseRules(json: String): List<Rule> {
        val arr = JSONArray(json)
        val out = ArrayList<Rule>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val t = o.getJSONObject("trigger")
            val trigger = Trigger(
                type = t.getString("type"),
                lat = t.optDouble("lat", 0.0), lng = t.optDouble("lng", 0.0),
                radiusM = t.optDouble("radius_m", 50.0), edge = t.optString("edge", "enter"),
                hhmm = t.optInt("hhmm", -1),
                days = t.optJSONArray("days")?.let { d -> (0 until d.length()).map { d.getInt(it) } } ?: emptyList(),
                field = t.optString("field", ""), cmp = t.optString("cmp", "=="), value = t.optString("value", ""),
            )
            val cg = o.optJSONObject("conditions")?.let { c ->
                ConditionGroup(
                    op = c.optString("op", "AND"),
                    items = c.optJSONArray("items")?.let { it2 ->
                        (0 until it2.length()).map { idx ->
                            val ci = it2.getJSONObject(idx)
                            Condition(
                                type = ci.optString("type", "compare"),
                                field = ci.optString("field", ""), cmp = ci.optString("cmp", "=="), value = ci.optString("value", ""),
                                lat = ci.optDouble("lat", 0.0), lng = ci.optDouble("lng", 0.0),
                                radiusM = ci.optDouble("radius_m", 50.0), withinS = ci.optInt("within_s", 600),
                                negate = ci.optBoolean("negate", false),
                                points = ci.optJSONArray("points")?.let { pa ->
                                    (0 until pa.length()).map { pi ->
                                        val po = pa.getJSONObject(pi)
                                        VPoint(po.optDouble("lat", 0.0), po.optDouble("lng", 0.0), po.optDouble("radius_m", 30.0))
                                    }
                                } ?: emptyList(),
                            )
                        }
                    } ?: emptyList(),
                )
            }
            val ac = o.getJSONObject("action")
            val action = Action(
                type = ac.getString("type"),
                window = ac.optInt("window", 0), all = ac.optBoolean("all", false), status = ac.optInt("status", 1),
                level = ac.optInt("level", 0), p1 = ac.optInt("p1", 0), p2 = ac.optInt("p2", 0),
                key = ac.optString("key", ""), value = ac.optString("value", ""),
            )
            out.add(Rule(
                id = o.getString("id"), name = o.optString("name", o.getString("id")),
                enabled = o.optBoolean("enabled", true), trigger = trigger,
                conditions = cg, action = action, debounceS = o.optInt("debounce_s", 60),
            ))
        }
        return out
    }

    data class Rule(
        val id: String, val name: String, val enabled: Boolean,
        val trigger: Trigger, val conditions: ConditionGroup?, val action: Action, val debounceS: Int,
    )
    data class Trigger(
        val type: String, val lat: Double, val lng: Double, val radiusM: Double, val edge: String,
        val hhmm: Int, val days: List<Int>, val field: String, val cmp: String, val value: String,
    )
    data class ConditionGroup(val op: String, val items: List<Condition>)
    data class VPoint(val lat: Double, val lng: Double, val radiusM: Double)
    data class Condition(
        val type: String = "compare",                 // "compare" (estado agora) | "visited" (passou por ponto) | "recent" (estado nos últimos N s)
        val field: String = "", val cmp: String = "==", val value: String = "",
        val lat: Double = 0.0, val lng: Double = 0.0, val radiusM: Double = 50.0, val withinS: Int = 600,
        val negate: Boolean = false,                   // "recent": true = passa quando NÃO ocorreu na janela
        val points: List<VPoint> = emptyList(),        // "visited": se preenchido, passa se visitou QUALQUER um (OU)
    )
    data class Action(
        val type: String, val window: Int, val all: Boolean, val status: Int,
        val level: Int, val p1: Int, val p2: Int, val key: String, val value: String,
    )
}
