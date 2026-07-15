package br.com.redesurftank.ecotrip.managers

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
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
    private const val FILE_TRIG = "automation_trig_state.json"   // estado das bordas (gatilho "state") entre sessões
    private const val FILE_GEO  = "automation_geo_state.json"    // estado dentro/fora do geofence entre sessões

    // Geofence só confia em fix GPS recente. Fix NETWORK (até 150m de erro) ou stale
    // alimentando um raio pequeno dava "dentro" aleatório → às vezes abria, às vezes não.
    private const val GEO_MAX_AGE_MS = 15_000L
    // Piso do raio efetivo: GPS bom ainda oscila ~5-20m. A trava de qualidade acima
    // (só fix não-NETWORK e ≤15s) já cobre o grosso da oscilação; 40m disparava cedo
    // demais e ignorava raios reduzidos, então segura só um piso mínimo.
    private const val GEO_MIN_RADIUS_M = 15.0
    // Histerese de re-arme: só considera "saiu" ao passar do raio + esta margem.
    // Evita flicker perto da borda e só rearma numa saída de verdade.
    private const val GEO_EXIT_MARGIN_M = 30.0

    // Trigger "time": se o carro estava desligado no minuto exato, ao ligar dentro
    // dessa janela pra trás dispara ainda hoje (catch-up). ex.: rule às 10:00,
    // carro liga 10:45 → fira; 12:30 → passa (fora da janela). Uma vez por dia.
    private const val CATCHUP_WINDOW_MIN = 90

    private lateinit var appContext: Context
    private val tick = Executors.newSingleThreadScheduledExecutor()
    private val lock = Any()
    @Volatile private var initialized = false

    private var rules: List<Rule> = emptyList()
    private val state = HashMap<String, String>()          // chave do bus → último valor
    private val inside = HashMap<String, Boolean>()         // ruleId → dentro do geofence?
    private val firedVisit = HashMap<String, Boolean>()     // ruleId → já disparou nesta visita (nível, persistido)
    private val lastFiredMs = HashMap<String, Long>()       // ruleId → último disparo
    private val lastFiredMinute = HashMap<String, Int>()    // ruleId → minuto do dia já disparado (time)
    private val lastFiredDay = HashMap<String, String>()    // ruleId → "yyyy-MM-dd" já disparado (time, persistido)
    private val intervalLastMs = HashMap<String, Long>()    // ruleId → último check do "interval" (não persiste; sobrevive ao tick)
    private val geofenceLastInside = HashMap<String, Long>() // coordKey → última vez dentro (ms) — p/ condição "visited"
    private val lastSatisfiedMs = HashMap<String, Long>()    // "field|cmp|value" → última vez que o predicado foi verdadeiro (p/ condição "recent")
    private val condPrevPass = HashMap<String, Boolean>()    // ruleId → conditionsPass no tick anterior (detecta re-arme)
    private val firedThisWindow = HashMap<String, Boolean>() // ruleId → já disparou nesta janela de condições satisfeitas
    private val armedWatch = HashMap<String, Long>()         // encadeada armada → deadline (ms) p/ observar condições
    private val repeatTasks = HashMap<String, ScheduledFuture<*>>() // ruleId → loop de reexecução (repeat_s)

    /** Callback pra publicar disparos (MqttManager seta isto). */
    @Volatile var onFired: ((ruleId: String, name: String, ok: Boolean) -> Unit)? = null

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        appContext = context.applicationContext
        loadFromDisk()
        loadTrigState()
        loadGeoState()
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
                firedVisit.keys.retainAll(ids)
                lastFiredMs.keys.retainAll(ids)
                lastFiredMinute.keys.retainAll(ids)
                lastFiredDay.keys.retainAll(ids)
                intervalLastMs.keys.retainAll(ids)
                condPrevPass.keys.retainAll(ids)
                firedThisWindow.keys.retainAll(ids)
                stateTrigSatisfied.keys.retainAll(ids)
            }
            cancelAllRepeats()   // regras mudaram → encerra loops antigos (reiniciam ao disparar de novo)
            saveToDisk(json)
            saveTrigState()
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
        processArmedWatch(now)                                  // encadeadas observando a janela
        val (lat, lng) = TripManager.getInstance().getLastGps()
        val hasGps = !(lat == 0.0 && lng == 0.0)
        // Geofence exige fix GPS (não NETWORK) e recente. Se o fix não presta, NÃO
        // chamamos checkGeofence — assim o mapa `inside` preserva o estado anterior
        // em vez de ser corrompido por uma posição ruidosa.
        val geoGps = hasGps &&
            TripManager.getInstance().getLastGpsProvider() == "gps" &&
            TripManager.getInstance().getLastGpsAgeMs() < GEO_MAX_AGE_MS
        if (hasGps) updateVisits(snapshot, lat, lng, now)      // rastreia passagem por pontos (p/ condição "visited")
        refreshDynamicFields(snapshot)                          // popula chaves "sob demanda" (ex: rain_intensity)
        trackRecent(snapshot, now)                              // rastreia "última vez que o predicado foi verdade" (p/ "recent")
        for (r in snapshot) {
            if (!r.enabled) continue
            try {
                // Edge nas CONDIÇÕES: a regra com condições dispara uma única vez
                // enquanto elas seguem satisfeitas; só re-arma quando deixam de ser
                // satisfeitas e voltam (ex: re-visitar o ponto). Sem isso, um gatilho
                // repetível (cruzar 8 km/h) re-disparava a cada vez dentro da janela
                // "visited". Regras SEM condições não são afetadas (gatilho já é borda).
                val hasConds = r.conditions?.items?.isNotEmpty() == true
                val condNow = conditionsPass(r.conditions, now)
                if (hasConds && !condNow) firedThisWindow[r.id] = false   // re-arma
                val fire = when (r.trigger.type) {
                    "geofence" -> if (geoGps) checkGeofence(r, lat, lng) else false
                    "time"     -> if (stateKey == null) checkTime(r, now) else false
                    "interval" -> if (stateKey == null) checkInterval(r, now) else false
                    "state"    -> {
                        if (stateKey == null) {
                            // Tick: lê o valor fresco do barramento e checa a borda — assim o
                            // disparo (ex: fechar vidro ao atingir X km/h) não fica preso à
                            // cadência de publish do MQTT.
                            val bk = r.trigger.field.substringBefore('[')
                            CarDataManager.getInstance().fetchCurrent(bk)?.let { v ->
                                synchronized(lock) { state[bk] = v }
                            }
                            checkStateEdge(r, now)
                        } else if (stateKey == r.trigger.field.substringBefore('[')) checkStateEdge(r, now) else false
                    }
                    else       -> false
                }
                if (!fire) continue
                if (!condNow) continue
                if (hasConds && firedThisWindow[r.id] == true) continue   // já disparou nesta janela
                val last = lastFiredMs[r.id] ?: 0L
                if (r.debounceS > 0 && now - last < r.debounceS * 1000L) continue
                lastFiredMs[r.id] = now
                if (hasConds) firedThisWindow[r.id] = true
                markGeofenceFired(r)   // nível: uma vez por visita, só após o disparo real
                fireRule(r)
            } catch (e: Exception) {
                AppLogger.w(TAG, "avaliar '${r.name}': ${e.message}")
            }
        }
    }

    // Executa a regra: respeita delayS (espera + re-checa condições) e, ao concluir,
    // encadeia regras cujo gatilho é "depois desta". Chamado pelo tick e por encadeamento.
    private fun fireRule(rule: Rule) {
        if (rule.delayS > 0) {
            AppLogger.i(TAG, "Regra '${rule.name}' disparou → aguardando ${rule.delayS}s antes de ${rule.action.type}")
            tick.schedule({
                try {
                    val stillOk = conditionsPass(rule.conditions, System.currentTimeMillis())
                    if (stillOk) {
                        val ok = runAction(rule.action)
                        AppLogger.i(TAG, "Regra '${rule.name}' (após ${rule.delayS}s) → ${rule.action.type} (ok=$ok)")
                        onFired?.invoke(rule.id, rule.name, ok)
                        startRepeat(rule); fireChained(rule.id, ok); runSteps(rule, 0)
                    } else {
                        AppLogger.i(TAG, "Regra '${rule.name}': condição não persistiu após ${rule.delayS}s — não executou")
                    }
                } catch (e: Exception) { AppLogger.w(TAG, "ação atrasada '${rule.name}': ${e.message}") }
            }, rule.delayS.toLong(), TimeUnit.SECONDS)
        } else {
            // Sem atraso: garante que as condições valem no instante (necessário p/ encadeadas).
            if (!conditionsPass(rule.conditions, System.currentTimeMillis())) return
            val ok = runAction(rule.action)
            AppLogger.i(TAG, "Regra '${rule.name}' disparou → ${rule.action.type} (ok=$ok)")
            onFired?.invoke(rule.id, rule.name, ok)
            startRepeat(rule); fireChained(rule.id, ok); runSteps(rule, 0)
        }
    }

    // Executa os passos extras em sequência: cada um espera delayS, observa as condições
    // por watchS s (lendo o estado fresco) e executa a ação; aí passa pro próximo.
    private fun runSteps(rule: Rule, fromIndex: Int) {
        if (fromIndex >= rule.steps.size) return
        val step = rule.steps[fromIndex]
        tick.schedule({
            observeStep(rule, fromIndex, System.currentTimeMillis() + step.watchS * 1000L)
        }, step.delayS.toLong(), TimeUnit.SECONDS)
    }
    private fun observeStep(rule: Rule, i: Int, deadline: Long) {
        val step = rule.steps[i]
        try {
            step.conditions?.items?.forEach { c ->
                if (c.type == "compare" && c.field.isNotEmpty()) {
                    val bk = c.field.substringBefore('[')
                    CarDataManager.getInstance().fetchCurrent(bk)?.let { v -> synchronized(lock) { state[bk] = v } }
                }
            }
            val now = System.currentTimeMillis()
            if (conditionsPass(step.conditions, now)) {
                val ok = runAction(step.action)
                AppLogger.i(TAG, "Passo ${i + 1} de '${rule.name}' → ${step.action.type} (ok=$ok)")
                runSteps(rule, i + 1)
            } else if (step.watchS <= 0 || now > deadline) {
                AppLogger.i(TAG, "Passo ${i + 1} de '${rule.name}': condição não satisfeita — sequência interrompida")
            } else {
                tick.schedule({ observeStep(rule, i, deadline) }, 1, TimeUnit.SECONDS)
            }
        } catch (e: Exception) { AppLogger.w(TAG, "passo '${rule.name}': ${e.message}") }
    }

    // Dispara regras encadeadas (gatilho "automation") após a regra de origem executar.
    private fun fireChained(firedRuleId: String, firedOk: Boolean) {
        val snapshot = synchronized(lock) { rules }
        val now = System.currentTimeMillis()
        for (b in snapshot) {
            if (!b.enabled || b.trigger.type != "automation") continue
            if (b.trigger.afterRuleId != firedRuleId) continue
            if (b.trigger.onlyIfSuccess && !firedOk) continue
            val last = lastFiredMs[b.id] ?: 0L
            if (b.debounceS > 0 && now - last < b.debounceS * 1000L) continue
            AppLogger.i(TAG, "Encadeada: '${b.name}' após '$firedRuleId' (ok=$firedOk)")
            scheduleChained(b)
        }
    }

    // Após o atraso da encadeada: se as condições já valem, executa; senão, se watchS>0,
    // fica observando (armedWatch) até valerem OU a janela expirar.
    private fun scheduleChained(b: Rule) {
        val act = Runnable {
            try {
                val now = System.currentTimeMillis()
                if (conditionsPass(b.conditions, now)) {
                    lastFiredMs[b.id] = now; runChainedAction(b)
                } else if (b.watchS > 0) {
                    synchronized(lock) { armedWatch[b.id] = now + b.watchS * 1000L }
                    AppLogger.i(TAG, "Encadeada '${b.name}': observando condições por ${b.watchS}s")
                } else {
                    AppLogger.i(TAG, "Encadeada '${b.name}': condição não satisfeita (sem janela) — não executou")
                }
            } catch (e: Exception) { AppLogger.w(TAG, "encadeada '${b.name}': ${e.message}") }
        }
        if (b.delayS > 0) tick.schedule(act, b.delayS.toLong(), TimeUnit.SECONDS) else act.run()
    }

    private fun runChainedAction(b: Rule) {
        val ok = runAction(b.action)
        AppLogger.i(TAG, "Encadeada '${b.name}' → ${b.action.type} (ok=$ok)")
        onFired?.invoke(b.id, b.name, ok)
        startRepeat(b); fireChained(b.id, ok); runSteps(b, 0)
    }

    // Cada tick: encadeadas armadas leem o estado fresco e executam quando as condições
    // passam; desarmam quando a janela expira.
    private fun processArmedWatch(now: Long) {
        val armed = synchronized(lock) { armedWatch.toMap() }
        if (armed.isEmpty()) return
        for ((bId, deadline) in armed) {
            val b = synchronized(lock) { rules.find { it.id == bId } }
            if (b == null || now > deadline) {
                synchronized(lock) { armedWatch.remove(bId) }
                if (b != null) AppLogger.i(TAG, "Encadeada '${b.name}': janela expirou — não executou")
                continue
            }
            b.conditions?.items?.forEach { c ->
                if (c.type == "compare" && c.field.isNotEmpty()) {
                    val bk = c.field.substringBefore('[')
                    CarDataManager.getInstance().fetchCurrent(bk)?.let { v -> synchronized(lock) { state[bk] = v } }
                }
            }
            if (conditionsPass(b.conditions, now)) {
                synchronized(lock) { armedWatch.remove(bId) }
                lastFiredMs[bId] = now
                runChainedAction(b)
            }
        }
    }

    // Loop de reexecução (repeat_s): após disparar, reexecuta a ação a cada repeat_s
    // ENQUANTO as condições seguem satisfeitas; para sozinho quando deixam de valer.
    // (ex: manter ventilação enquanto a temperatura interna estiver alta.)
    private fun startRepeat(r: Rule) {
        if (r.repeatS <= 0) return
        synchronized(lock) {
            repeatTasks.remove(r.id)?.cancel(false)
            repeatTasks[r.id] = tick.scheduleWithFixedDelay({
                try {
                    if (!conditionsPass(r.conditions, System.currentTimeMillis())) {
                        synchronized(lock) { repeatTasks.remove(r.id)?.cancel(false) }
                        return@scheduleWithFixedDelay
                    }
                    val ok = runAction(r.action)
                    AppLogger.i(TAG, "Regra '${r.name}' (loop ${r.repeatS}s) → ${r.action.type} (ok=$ok)")
                } catch (e: Exception) { AppLogger.w(TAG, "loop '${r.name}': ${e.message}") }
            }, r.repeatS.toLong(), r.repeatS.toLong(), TimeUnit.SECONDS)
        }
    }
    private fun cancelAllRepeats() {
        synchronized(lock) { repeatTasks.values.forEach { it.cancel(false) }; repeatTasks.clear() }
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

    // Level-trigger com re-arme (não borda): dispara enquanto ESTÁ na condição-alvo
    // (dentro p/ "enter", fora p/ "exit") e ainda não disparou nesta visita; re-arma
    // só ao cruzar claramente pro lado oposto (raio + margem). Robusto a reinício do
    // app perto/dentro da zona — a borda antiga exigia prev==false e perdia o disparo.
    private fun checkGeofence(r: Rule, lat: Double, lng: Double): Boolean {
        val d = haversine(lat, lng, r.trigger.lat, r.trigger.lng)
        val radius = maxOf(r.trigger.radiusM, GEO_MIN_RADIUS_M)   // piso: raio pequeno oscilava
        val nowInside = d <= radius
        val clearlyOutside = d > radius + GEO_EXIT_MARGIN_M
        if (inside[r.id] != nowInside) { inside[r.id] = nowInside }

        // "alvo" = estado que deve disparar; "rearm" = estado oposto claro que re-arma.
        val (target, rearm) = when (r.trigger.edge) {
            "exit" -> Pair(clearlyOutside, nowInside)
            else   -> Pair(nowInside, clearlyOutside)   // "enter" (default)
        }
        if (rearm) {
            if (firedVisit[r.id] == true) { firedVisit[r.id] = false; saveGeoState() }
            return false
        }
        // NÃO marca firedVisit aqui: quem marca é o evaluate, DEPOIS do fireRule real
        // (senão condições/debounce bloqueiam o disparo mas a visita já ficava "usada").
        return target && firedVisit[r.id] != true
    }

    // Marca a visita como disparada após o fireRule de uma regra de geofence executar.
    private fun markGeofenceFired(r: Rule) {
        if (r.trigger.type != "geofence") return
        firedVisit[r.id] = true; saveGeoState()
    }

    private fun checkTime(r: Rule, now: Long): Boolean {
        val cal = java.util.Calendar.getInstance()
        val minuteOfDay = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        // Dia da semana: Calendar DOM 1=Dom..7=Sáb → 0..6
        val dow = cal.get(java.util.Calendar.DAY_OF_WEEK) - 1
        if (r.trigger.days.isNotEmpty() && !r.trigger.days.contains(dow)) return false
        val today = String.format("%04d-%02d-%02d",
            cal.get(java.util.Calendar.YEAR),
            cal.get(java.util.Calendar.MONTH) + 1,
            cal.get(java.util.Calendar.DAY_OF_MONTH))
        if (lastFiredDay[r.id] == today) return false            // já disparou hoje (respeita override manual: se fechou às 10h e o dono abriu, não fecha de novo)
        val delta = minuteOfDay - r.trigger.hhmm
        if (delta < 0) return false                              // ainda não chegou a hora hoje
        // Janela: se `until_hhmm` vier na regra, usa essa faixa (ex.: 10:00-16:00 = 360min).
        // Senão cai no default 90min (compat com regras antigas sem até).
        val window = if (r.trigger.untilHhmm > r.trigger.hhmm) (r.trigger.untilHhmm - r.trigger.hhmm) else CATCHUP_WINDOW_MIN
        if (delta > window) return false                         // fora da janela — não fira mais hoje
        lastFiredDay[r.id] = today; saveTrigState()
        lastFiredMinute[r.id] = minuteOfDay
        return true
    }

    // Gatilho "interval": dispara a cada N min dentro da janela [hhmm..until_hhmm]
    // em todos os dias listados (ou todos se days vazio). Diferente do "time", NÃO
    // guarda 1x/dia — reavalia condições em cada janelinha. Ideal p/ "manter
    // cortina fechada enquanto sol/temp alta durante a direção": se você reabriu
    // manual, na próxima batida ele fecha de novo se ainda estiver quente.
    // Se a regra usa `shade`, faz leitura ATIVA do nível atual da cortina via
    // VehicleControlManager (a chave não vem pelo CAN listener) e injeta em `state`
    // como `shade_level` pra o conditionsPass ter dado fresco.
    private fun checkInterval(r: Rule, now: Long): Boolean {
        val cal = java.util.Calendar.getInstance()
        val minuteOfDay = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        val dow = cal.get(java.util.Calendar.DAY_OF_WEEK) - 1
        if (r.trigger.days.isNotEmpty() && !r.trigger.days.contains(dow)) return false
        val start = if (r.trigger.hhmm >= 0) r.trigger.hhmm else 0
        val end = if (r.trigger.untilHhmm > start) r.trigger.untilHhmm else 1439
        if (minuteOfDay < start || minuteOfDay > end) return false
        val everyMs = maxOf(1, r.trigger.everyMin) * 60_000L
        val lastMs = intervalLastMs[r.id] ?: 0L
        if (now - lastMs < everyMs) return false
        // Leitura ativa do shade se a regra depende dele (só chave que não chega no CAN).
        try {
            val usesShade = r.conditions?.items?.any { it.type == "compare" && it.field == "shade_level" } == true
            if (usesShade) {
                val lvl = VehicleControlManager.getShadeScreensLevel()
                if (lvl != null) synchronized(lock) { state["shade_level"] = lvl.toString() }
            }
        } catch (e: Exception) { AppLogger.w(TAG, "interval: leitura shade falhou: ${e.message}") }
        intervalLastMs[r.id] = now
        return true
    }

    // Gatilho "state": dispara quando o valor da chave passa a satisfazer cmp/value
    // (borda de subida — não estava satisfazendo antes desta mudança).
    private val stateTrigSatisfied = HashMap<String, Boolean>()
    private val stateTrigSince = HashMap<String, Long>()    // quando o predicado virou verdadeiro (p/ stable_s)
    private val stateTrigFired = HashMap<String, Boolean>() // já disparou nesta subida (p/ stable_s)
    private fun checkStateEdge(r: Rule, now: Long): Boolean {
        val cur = compareField(r.trigger.field, r.trigger.cmp, r.trigger.value)
        val prev = stateTrigSatisfied[r.id] ?: false
        // Persiste a borda entre sessões: ao desligar (true→false) grava false;
        // então ligar de novo com o app já aberto conta como borda real e dispara,
        // mas um reinício do app com o carro já ligado (prev=true salvo) NÃO dispara.
        if (cur != prev) {
            stateTrigSatisfied[r.id] = cur; saveTrigState()
            if (cur) { stateTrigSince[r.id] = now; stateTrigFired[r.id] = false }
        }
        if (r.stableS <= 0) return cur && !prev   // sem estabilidade: borda simples (comportamento original)
        // Com estabilidade: dispara uma vez por subida, só depois do predicado ficar
        // verdadeiro por stable_s contínuos (filtra picos momentâneos).
        if (!cur) return false
        if (stateTrigFired[r.id] == true) return false
        if (now - (stateTrigSince[r.id] ?: now) < r.stableS * 1000L) return false
        stateTrigFired[r.id] = true
        return true
    }

    private fun loadTrigState() {
        try {
            val f = File(appContext.filesDir, FILE_TRIG)
            if (!f.exists()) return
            val o = JSONObject(f.readText())
            val st = o.optJSONObject("state")
            if (st != null) {
                st.keys().forEach { k -> stateTrigSatisfied[k] = st.getBoolean(k) }
                o.optJSONObject("day")?.let { dy -> dy.keys().forEach { k -> lastFiredDay[k] = dy.getString(k) } }
            } else {
                // Legado (pré-catchup): arquivo flat só com booleanos = stateTrigSatisfied.
                o.keys().forEach { k -> stateTrigSatisfied[k] = o.getBoolean(k) }
            }
        } catch (e: Exception) { AppLogger.w(TAG, "loadTrigState: ${e.message}") }
    }
    private fun saveTrigState() {
        try {
            val st = JSONObject(); val dy = JSONObject()
            synchronized(lock) {
                stateTrigSatisfied.forEach { (k, v) -> st.put(k, v) }
                lastFiredDay.forEach { (k, v) -> dy.put(k, v) }
            }
            val out = JSONObject().put("state", st).put("day", dy)
            File(appContext.filesDir, FILE_TRIG).writeText(out.toString())
        } catch (e: Exception) { AppLogger.w(TAG, "saveTrigState: ${e.message}") }
    }

    // Persiste dentro/fora do geofence entre sessões. Sem isso, reinício do app perto
    // ou dentro da zona zerava a borda (prev=null) e a regra de vidro nunca disparava.
    private fun loadGeoState() {
        try {
            val f = File(appContext.filesDir, FILE_GEO)
            if (!f.exists()) return
            val o = JSONObject(f.readText())
            val ins = o.optJSONObject("inside")
            if (ins != null) {
                ins.keys().forEach { inside[it] = ins.getBoolean(it) }
                o.optJSONObject("fired")?.let { fv -> fv.keys().forEach { firedVisit[it] = fv.getBoolean(it) } }
            } else {
                // Legado (v6.117): JSON flat era só o mapa `inside`.
                o.keys().forEach { inside[it] = o.getBoolean(it) }
            }
        } catch (e: Exception) { AppLogger.w(TAG, "loadGeoState: ${e.message}") }
    }
    private fun saveGeoState() {
        try {
            val ins = JSONObject(); val fv = JSONObject()
            synchronized(lock) {
                inside.forEach { (k, v) -> ins.put(k, v) }
                firedVisit.forEach { (k, v) -> fv.put(k, v) }
            }
            val o = JSONObject().put("inside", ins).put("fired", fv)
            File(appContext.filesDir, FILE_GEO).writeText(o.toString())
        } catch (e: Exception) { AppLogger.w(TAG, "saveGeoState: ${e.message}") }
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
                "time" -> {
                    // Janela de horário (+ dias opcionais): passa se AGORA está dentro da
                    // faixa from..to e o dia da semana bate. Faixa que cruza meia-noite
                    // (ex: 22:00→06:00) é tratada. negate=true inverte (FORA da janela).
                    val cal = java.util.Calendar.getInstance()
                    val mod = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
                    val dow = cal.get(java.util.Calendar.DAY_OF_WEEK) - 1   // 0=Dom..6=Sáb
                    val dayOk = c.days.isEmpty() || c.days.contains(dow)
                    val timeOk = when {
                        c.fromHHMM < 0 || c.toHHMM < 0 -> true
                        c.fromHHMM <= c.toHHMM         -> mod in c.fromHHMM..c.toHHMM
                        else                           -> mod >= c.fromHHMM || mod <= c.toHHMM
                    }
                    val pass = dayOk && timeOk
                    if (c.negate) !pass else pass
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
        // Suporte a ÍNDICE de CSV: "car.basic.seated_state[1]" lê a 2ª posição do CSV
        // "(0,1,0,0,0)" (cada slot 0/1). Serve p/ seated_state, door_status, window_status…
        val br = field.indexOf('[')
        val baseField = if (br > 0) field.substring(0, br) else field
        val csvIdx = if (br > 0) field.substring(br + 1).trimEnd(']').trim().toIntOrNull() else null
        var cur = synchronized(lock) { state[baseField] }
            ?: CarDataManager.getInstance().fetchCurrent(baseField)?.also { synchronized(lock) { state[baseField] = it } }
            ?: return false
        if (csvIdx != null) {
            val parts = cur.replace(Regex("[^0-9,\\-]"), "").split(",")
            cur = parts.getOrNull(csvIdx)?.trim() ?: return false
        }
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
        "notify"   -> true    // execução real fica no bridge (recebe rules/fired e roteia ntfy/WhatsApp)
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
                afterRuleId = t.optString("after_rule_id", ""),
                onlyIfSuccess = t.optBoolean("only_if_success", true),
                untilHhmm = t.optInt("until_hhmm", -1),
                everyMin = t.optInt("every_min", 0),
            )
            // Passos extras (sequência numa regra só): cada passo = atraso + condição
            // (observada por watch_s) + ação. Executados em ordem após a ação principal.
            val steps = o.optJSONArray("steps")?.let { sa ->
                (0 until sa.length()).map { si ->
                    val so = sa.getJSONObject(si)
                    Step(
                        delayS = so.optInt("delay_s", 0), watchS = so.optInt("watch_s", 0),
                        conditions = parseConditionGroup(so.optJSONObject("conditions")),
                        action = parseAction(so.getJSONObject("action")),
                    )
                }
            } ?: emptyList()
            out.add(Rule(
                id = o.getString("id"), name = o.optString("name", o.getString("id")),
                enabled = o.optBoolean("enabled", true), trigger = trigger,
                conditions = parseConditionGroup(o.optJSONObject("conditions")),
                action = parseAction(o.getJSONObject("action")), debounceS = o.optInt("debounce_s", 60),
                delayS = o.optInt("delay_s", 0), stableS = o.optInt("stable_s", 0), repeatS = o.optInt("repeat_s", 0),
                watchS = o.optInt("watch_s", 0), steps = steps,
            ))
        }
        return out
    }

    private fun parseConditionGroup(c: JSONObject?): ConditionGroup? = c?.let {
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
                        fromHHMM = ci.optInt("from_hhmm", -1), toHHMM = ci.optInt("to_hhmm", -1),
                        days = ci.optJSONArray("days")?.let { da -> (0 until da.length()).map { da.getInt(it) } } ?: emptyList(),
                    )
                }
            } ?: emptyList(),
        )
    }

    private fun parseAction(ac: JSONObject): Action = Action(
        type = ac.getString("type"),
        window = ac.optInt("window", 0), all = ac.optBoolean("all", false), status = ac.optInt("status", 1),
        level = ac.optInt("level", 0), p1 = ac.optInt("p1", 0), p2 = ac.optInt("p2", 0),
        key = ac.optString("key", ""), value = ac.optString("value", ""),
    )

    data class Rule(
        val id: String, val name: String, val enabled: Boolean,
        val trigger: Trigger, val conditions: ConditionGroup?, val action: Action, val debounceS: Int,
        val delayS: Int = 0, val stableS: Int = 0, val repeatS: Int = 0,
        val watchS: Int = 0,   // encadeada: após o atraso, observa as condições por watchS s (0 = checa 1x)
        val steps: List<Step> = emptyList(),   // passos extras (sequência) após a ação principal
    )
    // Passo de uma sequência: espera delayS, observa as condições por watchS (0 = checa 1x) e executa a ação.
    data class Step(val delayS: Int, val watchS: Int, val conditions: ConditionGroup?, val action: Action)
    data class Trigger(
        val type: String, val lat: Double, val lng: Double, val radiusM: Double, val edge: String,
        val hhmm: Int, val days: List<Int>, val field: String, val cmp: String, val value: String,
        val afterRuleId: String = "",          // type "automation": dispara após esta regra executar
        val onlyIfSuccess: Boolean = true,      // só encadeia se a regra-origem executou com sucesso
        val untilHhmm: Int = -1,                // "time": limite superior da janela de disparo (minuto do dia); -1 = default 90min
        val everyMin: Int = 0,                  // "interval": intervalo entre disparos (min) dentro da janela [hhmm..untilHhmm]
    )
    data class ConditionGroup(val op: String, val items: List<Condition>)
    data class VPoint(val lat: Double, val lng: Double, val radiusM: Double)
    data class Condition(
        val type: String = "compare",                 // "compare" | "visited" | "recent" | "time" (janela de horário/dias)
        val field: String = "", val cmp: String = "==", val value: String = "",
        val lat: Double = 0.0, val lng: Double = 0.0, val radiusM: Double = 50.0, val withinS: Int = 600,
        val negate: Boolean = false,                   // "recent": true = passa quando NÃO ocorreu na janela
        val points: List<VPoint> = emptyList(),        // "visited": se preenchido, passa se visitou QUALQUER um (OU)
        val fromHHMM: Int = -1, val toHHMM: Int = -1,  // "time": faixa de horário (minuto do dia 0..1439; -1 = sem limite)
        val days: List<Int> = emptyList(),             // "time": dias da semana (0=Dom..6=Sáb; vazio = todo dia)
    )
    data class Action(
        val type: String, val window: Int, val all: Boolean, val status: Int,
        val level: Int, val p1: Int, val p2: Int, val key: String, val value: String,
    )
}
