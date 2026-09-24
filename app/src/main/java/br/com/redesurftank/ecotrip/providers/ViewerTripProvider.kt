package br.com.redesurftank.ecotrip.providers

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.managers.AutoTripEntry
import br.com.redesurftank.ecotrip.managers.TelemetrySample
import br.com.redesurftank.ecotrip.managers.TripManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * Viagens do EcoTrip para o Haval H6 3D (`com.havalh6.viewer`), SÓ LEITURA.
 *
 * O 3D deixou de contabilizar viagens: a viagem em curso, o histórico, as
 * amostras (rota do mapa), abastecimentos e recargas vêm daqui. A retomada de
 * uma viagem em até 60 min (banner "continuar" do ConsumptionScreen) aparece
 * sozinha do outro lado: a viagem retomada volta a ser a viagem em curso com o
 * MESMO startMs e sai do histórico.
 *
 * Contrato: `ContentResolver.call(content://<applicationId>.trips, método, arg, extras)`
 * → Bundle { ok: Boolean, json: String }. Métodos:
 *   info                              → {api, version, tankL, ready, liveStartMs}
 *   rev                               → assinatura barata do estado; muda quando algo muda
 *   trips   extras{offset,limit}      → {total, trips:[...]} mais nova primeiro
 *   live                              → {trip: {...} | null}
 *   samples extras{startMs,afterT,max}→ {startMs, fields, samples:[[...]]}; afterT em ms absolutos
 *   stops                             → {tankL, priceGasolinePerL, priceEnergyPerKwh,
 *                                          refuels:[{..., pricePerLiter}], charges:[...]}
 *                                        preços = os do EcoTrip (padrões + por abastecimento);
 *                                        o 3D deixa de perguntar preço quando isto existe
 *
 * Acesso: só o pacote do 3D (e o próprio EcoTrip). Nenhum método escreve nada.
 */
class ViewerTripProvider : ContentProvider() {

    companion object {
        private const val TAG = "ViewerTripProvider"
        const val API = 1
        private val ALLOWED = setOf("com.havalh6.viewer")
        private const val MAX_TRIPS_PAGE = 200
        private const val MAX_SAMPLES = 2000
        val SAMPLE_FIELDS = listOf("t", "lat", "lng", "spd", "rpm", "rpmOk", "evKw", "soc", "altM")
    }

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        if (!callerAllowed()) {
            AppLogger.w(TAG, "chamada recusada: uid=${Binder.getCallingUid()} método=$method")
            throw SecurityException("EcoTrip trips: caller not allowed")
        }
        val out = Bundle()
        try {
            val tm = TripManager.getInstance()
            if (!tm.isReadyForViewer()) {
                out.putBoolean("ok", false)
                out.putString("json", JSONObject().put("ready", false).toString())
                return out
            }
            val json = when (method) {
                "info" -> info(tm)
                "rev" -> rev(tm)
                "trips" -> trips(tm, extras?.getInt("offset", 0) ?: 0, extras?.getInt("limit", 50) ?: 50)
                "live" -> live(tm)
                "samples" -> samples(
                    tm,
                    extras?.getLong("startMs", 0L) ?: 0L,
                    extras?.getLong("afterT", 0L) ?: 0L,
                    extras?.getInt("max", MAX_SAMPLES) ?: MAX_SAMPLES,
                )
                "stops" -> stops(tm)
                else -> null
            }
            out.putBoolean("ok", json != null)
            out.putString("json", json?.toString() ?: "")
        } catch (e: Exception) {
            AppLogger.w(TAG, "$method falhou: ${e.message}")
            out.putBoolean("ok", false)
            out.putString("json", "")
        }
        return out
    }

    private fun callerAllowed(): Boolean {
        val uid = Binder.getCallingUid()
        if (uid == Process.myUid()) return true
        val pkgs = context?.packageManager?.getPackagesForUid(uid) ?: return false
        return pkgs.any { it in ALLOWED }
    }

    // ── métodos ─────────────────────────────────────────────────────────────

    private fun info(tm: TripManager): JSONObject = JSONObject()
        .put("api", API)
        .put("version", BuildConfig.VERSION_NAME)
        .put("versionCode", BuildConfig.VERSION_CODE)
        .put("ready", true)
        .put("tankL", tm.getTankCapacityForViewer().toDouble())
        .put("liveStartMs", tm.getInProgressAutoTrip()?.startMs ?: 0L)

    /**
     * Muda quando o histórico, a viagem em curso (início), abastecimentos ou
     * recargas mudam. O 3D só relê o histórico quando isto muda.
     */
    private fun rev(tm: TripManager): JSONObject {
        val hist = tm.getAutoTripHistory()
        var h = 17L
        for (t in hist) {
            h = h * 31 + t.startMs
            h = h * 31 + t.endMs
            h = h * 31 + (t.distKm * 100).toLong()
            h = h * 31 + t.name.hashCode()
        }
        val refuels = tm.getRefuelHistory()
        val charges = tm.getChargeHistory()
        return JSONObject()
            .put("count", hist.size)
            .put("hash", java.lang.Long.toHexString(h))
            .put("liveStartMs", tm.getInProgressAutoTrip()?.startMs ?: 0L)
            .put("refuels", refuels.size)
            .put("lastRefuelMs", refuels.maxOfOrNull { it.timestampMs } ?: 0L)
            .put("charges", charges.size)
            .put("lastChargeMs", charges.maxOfOrNull { it.timestampMs } ?: 0L)
    }

    private fun trips(tm: TripManager, offset: Int, limit: Int): JSONObject {
        val hist = tm.getAutoTripHistory().sortedByDescending { it.startMs }
        val from = offset.coerceAtLeast(0)
        val to = (from + limit.coerceIn(1, MAX_TRIPS_PAGE)).coerceAtMost(hist.size)
        val arr = JSONArray()
        if (from < to) for (t in hist.subList(from, to)) arr.put(tripJson(tm, t, null))
        return JSONObject().put("total", hist.size).put("trips", arr)
    }

    private fun live(tm: TripManager): JSONObject {
        val t = tm.getInProgressAutoTrip() ?: return JSONObject().put("trip", JSONObject.NULL)
        val ls = tm.getLiveSamplesForViewer()
        val samples = if (ls != null && ls.first == t.startMs) ls.second else emptyList()
        return JSONObject().put("trip", tripJson(tm, t, samples))
    }

    private fun samples(tm: TripManager, startMs: Long, afterT: Long, max: Int): JSONObject {
        val ls = tm.getLiveSamplesForViewer()
        val list = if (ls != null && ls.first == startMs) ls.second else tm.getTripSamplesForViewer(startMs)
        val cutSec = if (afterT > startMs) (afterT - startMs) / 1000L else -1L
        val picked = list.filter { it.t > cutSec }
        val cap = max.coerceIn(1, MAX_SAMPLES)
        val stride = kotlin.math.max(1, kotlin.math.ceil(picked.size / cap.toDouble()).toInt())
        val arr = JSONArray()
        picked.forEachIndexed { i, s ->
            if (i % stride != 0 && i != picked.lastIndex) return@forEachIndexed
            arr.put(JSONArray()
                .put(startMs + s.t * 1000L)
                .put(s.lat).put(s.lng)
                .put(s.spd.toDouble())
                .put(s.rpm).put(if (s.rpmOk) 1 else 0)
                .put(s.evKw.toDouble())
                .put(s.soc).put(s.altM))
        }
        return JSONObject()
            .put("startMs", startMs)
            .put("fields", JSONArray(SAMPLE_FIELDS))
            .put("samples", arr)
    }

    private fun stops(tm: TripManager): JSONObject {
        val refuels = JSONArray()
        for (r in tm.getRefuelHistory().sortedBy { it.timestampMs }) {
            refuels.put(JSONObject()
                .put("t", r.timestampMs)
                .put("beforeL", r.fuelLBefore.toDouble())
                .put("afterL", r.fuelLAfter.toDouble())
                .put("liters", r.litersAdded.toDouble())
                .put("odometerKm", r.odometerKm.toDouble())
                // 0 = pendente (o EcoTrip preenche depois); o 3D usa o padrão nesse caso.
                .put("pricePerLiter", r.pricePerLiter.toDouble()))
        }
        val charges = JSONArray()
        for (c in tm.getChargeHistory().sortedBy { it.timestampMs }) {
            charges.put(JSONObject()
                .put("t", c.timestampMs)
                .put("durationSec", c.durationSec)
                .put("kwh", c.energyKwh.toDouble())
                .put("startSoc", c.startSocPct.toDouble())
                .put("endSoc", c.endSocPct.toDouble()))
        }
        return JSONObject()
            .put("tankL", tm.getTankCapacityForViewer().toDouble())
            .put("priceGasolinePerL", tm.getPriceGasoline().toDouble())
            .put("priceEnergyPerKwh", tm.getPriceEnergy().toDouble())
            .put("refuels", refuels)
            .put("charges", charges)
    }

    // ── conversão ───────────────────────────────────────────────────────────

    /**
     * Uma viagem no formato do 3D. `evKm` = km com o motor a combustão
     * desligado: pelos trechos (segments.engineDistKm) quando existem, senão
     * pelas amostras (rpm==0 com rpm conhecido); -1 quando não dá pra saber.
     */
    private fun tripJson(tm: TripManager, t: AutoTripEntry, liveSamples: List<TelemetrySample>?): JSONObject {
        val o = JSONObject()
            .put("startMs", t.startMs)
            .put("endMs", t.endMs)
            .put("name", t.name)
            .put("distKm", t.distKm.toDouble())
            .put("distIntegKm", t.distIntegKm.toDouble())
            .put("timeSec", t.timeSec)
            .put("parkedInPSec", t.parkedInPSec)
            .put("engineOffSec", t.engineOffSec)
            .put("energyKwh", t.energyKwh.toDouble())
            .put("regenKwh", t.regenKwh.toDouble())
            .put("netKwh", t.netKwh.toDouble())
            .put("fuelL", t.fuelL.toDouble())
            .put("startSocPct", t.startSocPct.toDouble())
            .put("endSocPct", t.endSocPct.toDouble())
            .put("startFuelPct", t.startFuelPct.toDouble())
            .put("endFuelPct", t.endFuelPct.toDouble())
            .put("maxSpeedKmh", t.maxSpeedKmh.toDouble())
            .put("elevGainM", t.elevGainM.toDouble())
            .put("elevLossM", t.elevLossM.toDouble())
            .put("odoJumps", t.odoJumps)
        var sLat = t.startLat; var sLng = t.startLng; var eLat = t.endLat; var eLng = t.endLng
        var evKm = -1.0
        val segDist = t.segments.sumOf { it.distKm.toDouble() }
        if (segDist > 0.1) {
            val engine = t.segments.sumOf { it.engineDistKm.toDouble() }
            evKm = (t.distKm * (1.0 - engine / segDist)).coerceIn(0.0, t.distKm.toDouble())
        }
        val samples = liveSamples ?: if (evKm < 0 || sLat == 0.0) tm.getTripSamplesForViewer(t.startMs) else emptyList()
        if (samples.isNotEmpty()) {
            val fix = samples.filter { it.lat != 0.0 && it.lng != 0.0 }
            if (sLat == 0.0 && fix.isNotEmpty()) { sLat = fix.first().lat; sLng = fix.first().lng }
            if ((eLat == 0.0 || liveSamples != null) && fix.isNotEmpty()) { eLat = fix.last().lat; eLng = fix.last().lng }
            if (evKm < 0) {
                var ev = 0.0; var known = 0.0
                for (i in 1 until samples.size) {
                    val a = samples[i - 1]; val b = samples[i]
                    val dt = (b.t - a.t).coerceIn(0, 30)
                    val km = a.spd * dt / 3600.0
                    if (!a.rpmOk) continue
                    known += km
                    if (a.rpm == 0) ev += km
                }
                if (known > 0.05) evKm = (ev / known * t.distKm).coerceIn(0.0, t.distKm.toDouble())
            }
        }
        return o.put("startLat", sLat).put("startLng", sLng).put("endLat", eLat).put("endLng", eLng)
            .put("evKm", evKm)
    }

    // ContentProvider CRUD: não usado (só call()).
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?): Int = 0
}
