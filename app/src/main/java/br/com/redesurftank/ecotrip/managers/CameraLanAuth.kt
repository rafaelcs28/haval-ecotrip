package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.ComponentName
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Ephemeral LAN authority. The paired secret is read only while verifying a challenge. */
class CameraLanAuth(
    private val deviceId: String,
    private val bridgeToken: () -> String,
    private val clock: () -> Long,
) {
    private class Session(val expires: Long, val scope: String, val credentials: MutableMap<String, ByteArray>)
    private class Tombstone(val expires: Long, val controlDigest: ByteArray)
    private val random = SecureRandom()
    private val challenges = linkedMapOf<String, Long>()
    private val sessions = linkedMapOf<String, Session>()
    private val tombstones = linkedMapOf<String, Tombstone>()

    @Synchronized fun challenge(): Map<String, Any>? {
        prune()
        val secret = bridgeToken()
        if (deviceId.isBlank() || secret.isBlank()) return null
        if (challenges.size >= 128) challenges.remove(challenges.keys.first())
        val nonce = randomHex(16)
        val expires = deadline(clock(), 30_000L)
        challenges[nonce] = expires
        return linkedMapOf(
            "deviceId" to deviceId,
            "nonce" to nonce,
            "expiresAt" to expires,
            "serverProof" to hmacHex(SERVER_DOMAIN, deviceId, nonce, expires, secret),
        )
    }

    fun serverProof(device: String, nonce: String, expires: Long): String? {
        val secret = bridgeToken()
        return if (secret.isBlank()) null else hmacHex(SERVER_DOMAIN, device, nonce, expires, secret)
    }

    @Synchronized fun createSession(device: String, nonce: String, expires: Long, proof: String, scope: String): Map<String, Any>? {
        prune()
        val expectedExpiry = challenges.remove(nonce) ?: return null
        val secret = bridgeToken()
        if (secret.isBlank() || device != deviceId || expires != expectedExpiry || clock() >= expires ||
            scope !in setOf("live", "download")) return null
        val expected = hmac(CLIENT_DOMAIN, deviceId, nonce, expires, secret)
        val supplied = if (proof.matches(Regex("[0-9a-f]{64}"))) {
            proof.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        } else ByteArray(32)
        val matches = MessageDigest.isEqual(expected, supplied)
        expected.fill(0); supplied.fill(0)
        if (!matches || sessions.size >= 16 || (scope == "live" && sessions.values.any { it.scope == "live" })) return null
        val id = randomHex(16)
        val expiry = deadline(clock(), 5 * 60_000L)
        val roles = if (scope == "live") listOf("producer", "viewer", "control") else listOf("download", "control")
        val credentials = roles.associateWith { randomHex(32) }
        sessions[id] = Session(expiry, scope, credentials.mapValues { digest(it.value) }.toMutableMap())
        return linkedMapOf<String, Any>("sessionId" to id, "expiresAt" to expiry, "scope" to scope).apply {
            credentials.forEach { (role, token) -> put("${role}Token", token) }
        }
    }

    @Synchronized fun admit(requestedSession: String, capturedSession: String, role: String, token: String): Boolean =
        requestedSession == capturedSession && consume(capturedSession, role, token)

    @Synchronized fun consume(id: String, role: String, token: String): Boolean {
        if (role !in setOf("producer", "viewer") || !authorize(id, role, token)) return false
        sessions[id]?.credentials?.remove(role)
        return true
    }

    @Synchronized fun authorize(id: String, role: String, token: String): Boolean {
        prune()
        val expected = sessions[id]?.credentials?.get(role) ?: return false
        return matches(expected, token)
    }

    @Synchronized fun authorizeAndRevoke(id: String, token: String): Boolean {
        prune()
        tombstones[id]?.let { return matches(it.controlDigest, token) }
        val session = sessions[id] ?: return false
        val control = session.credentials["control"] ?: return false
        if (!matches(control, token)) return false
        sessions.remove(id)
        retainControlTombstone(id, session)
        return true
    }

    @Synchronized fun active(id: String): Boolean { prune(); return sessions.containsKey(id) }
    @Synchronized fun revoke(id: String) { sessions.remove(id)?.let { retainControlTombstone(id, it) } }
    @Synchronized fun clear() {
        sessions.keys.toList().forEach(::revoke)
        tombstones.keys.toList().forEach(::removeTombstone)
        challenges.clear()
    }

    fun capabilities(installed: Boolean, authorized: Boolean): Map<String, Int> = capabilityFields(installed && authorized)
    private fun prune() {
        val now = clock()
        challenges.entries.removeAll { it.value <= now }
        sessions.filterValues { it.expires <= now }.keys.toList().forEach(::revoke)
        tombstones.filterValues { it.expires <= now }.keys.toList().forEach(::removeTombstone)
    }
    private fun removeTombstone(id: String) { tombstones.remove(id)?.controlDigest?.fill(0) }
    private fun retainControlTombstone(id: String, session: Session) {
        val retained = session.credentials["control"]?.copyOf()
        session.credentials.values.forEach { it.fill(0) }
        if (retained == null || session.expires <= clock()) { retained?.fill(0); return }
        if (tombstones.size >= MAX_TOMBSTONES) removeTombstone(tombstones.keys.first())
        tombstones[id] = Tombstone(session.expires, retained)
    }
    private fun matches(expected: ByteArray, token: String): Boolean {
        val supplied = if (token.length == 64) digest(token) else ByteArray(expected.size)
        return try { MessageDigest.isEqual(expected, supplied) && token.length == 64 }
        finally { supplied.fill(0) }
    }
    private fun deadline(start: Long, duration: Long): Long =
        if (start > Long.MAX_VALUE - duration) Long.MAX_VALUE else start + duration
    private fun randomHex(bytes: Int) = ByteArray(bytes).also(random::nextBytes).joinToString("") { "%02x".format(it) }
    private fun digest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
    private fun hmacHex(domain: String, device: String, nonce: String, expires: Long, secret: String): String {
        val proof = hmac(domain, device, nonce, expires, secret)
        return try { proof.joinToString("") { "%02x".format(it) } } finally { proof.fill(0) }
    }
    private fun hmac(domain: String, device: String, nonce: String, expires: Long, secret: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        val key = secret.toByteArray(Charsets.UTF_8)
        return try {
            mac.init(SecretKeySpec(key, "HmacSHA256"))
            mac.doFinal("$domain|$device|$nonce|$expires".toByteArray(Charsets.UTF_8))
        } finally { key.fill(0) }
    }

    companion object {
        private const val CLIENT_DOMAIN = "haval-camera-lan-v1"
        private const val SERVER_DOMAIN = "haval-camera-lan-server-v1"
        private const val MAX_TOMBSTONES = 128

        fun capabilityFields(available: Boolean): Map<String, Int> = mapOf(
            "cameraLiveLan" to if (available) 1 else 0,
            "cameraDownloadLan" to if (available) 1 else 0,
            "hvcVersion" to 1, "hvtVersion" to 1,
        )

        fun cameraAvailable(context: Context?): Boolean = context != null && runCatching {
            val pm = context.packageManager
            val app = pm.getApplicationInfo(CameraVideoContract.PACKAGE, 0)
            val service = pm.getServiceInfo(ComponentName(CameraVideoContract.PACKAGE, CameraVideoContract.SERVICE), 0)
            val provider = pm.resolveContentProvider(CameraVideoContract.AUTHORITY, 0)
            app.enabled && service.enabled && service.exported &&
                service.permission == CameraVideoContract.CONTROL_PERMISSION &&
                provider != null && provider.enabled && provider.exported &&
                provider.packageName == CameraVideoContract.PACKAGE &&
                provider.readPermission == null && provider.writePermission == null
        }.getOrDefault(false)
    }
}
