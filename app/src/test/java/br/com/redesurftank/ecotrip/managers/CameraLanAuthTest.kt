package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.InvocationTargetException
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

// Reflection keeps the tests-only RED commit compilable before the new classes exist.
internal object LanTest {
    fun create(name: String, vararg args: Any): Any {
        val type = runCatching { Class.forName("br.com.redesurftank.ecotrip.managers.$name") }.getOrNull()
        assertNotNull("Missing LAN component: $name", type)
        return type!!.constructors.single { it.parameterCount == args.size }.newInstance(*args)
    }
    fun call(target: Any, name: String, vararg args: Any?): Any? = try {
        val method = target.javaClass.methods.singleOrNull { it.name == name && it.parameterCount == args.size }
        assertNotNull("Missing LAN operation: $name", method)
        method!!.invoke(target, *args)
    } catch (failure: InvocationTargetException) { throw failure.targetException }
    @Suppress("UNCHECKED_CAST")
    fun map(value: Any?) = value as Map<String, Any>
    fun rejects(block: () -> Unit) {
        try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) { }
    }
    fun proof(device: String, nonce: String, expires: Long, key: String = "synthetic-paired-secret"): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key.toByteArray(), "HmacSHA256"))
        return mac.doFinal("haval-camera-lan-v1|$device|$nonce|$expires".toByteArray())
            .joinToString("") { "%02x".format(it) }
    }
}

class CameraLanAuthTest {
    private var now = 1_000L
    private var token = "synthetic-paired-secret"
    private fun auth() = LanTest.create("CameraLanAuth", "car-1", { token }, { now })
    private fun challenge(a: Any) = LanTest.map(LanTest.call(a, "challenge"))
    private fun session(a: Any, c: Map<String, Any>, scope: String = "live", device: String = "car-1", proof: String? = null): Map<String, Any>? {
        val nonce = c["nonce"] as String
        val expires = c["expiresAt"] as Long
        return LanTest.call(a, "createSession", device, nonce, expires,
            proof ?: LanTest.proof(device, nonce, expires), scope) as? Map<String, Any>
    }
    @Test fun noncesAreUnique128BitAndExpireAfterExactlyThirtySeconds() {
        val a = auth()
        val nonces = (1..32).map { challenge(a).also { assertEquals(31_000L, it["expiresAt"]) }["nonce"] as String }
        assertEquals(32, nonces.toSet().size)
        assertTrue(nonces.all { it.matches(Regex("[0-9a-f]{32}")) })
        val c = challenge(a)
        now = 31_000L
        assertNull(session(a, c))
    }
    @Test fun exactHmacVectorAndChallengeSingleUse() {
        assertEquals("2dab4d474d1e23961a2246ba4611bdfe10418e40a2c9c5a5cc24d1413766a312", LanTest.proof("car-1", "000102030405060708090a0b0c0d0e0f", 31_000))
        val a = auth(); val c = challenge(a)
        assertNotNull(session(a, c))
        assertNull(session(a, c))
    }
    @Test fun badProofWrongDeviceAndChangedExpiryConsumeChallenge() {
        for (bad in listOf("proof", "device", "expiry")) {
            val a = auth(); val c = challenge(a)
            val altered = if (bad == "expiry") c + ("expiresAt" to 30_999L) else c
            assertNull(session(a, altered, device = if (bad == "device") "car-2" else "car-1",
                proof = if (bad == "proof") "00".repeat(32) else null))
            assertNull(session(a, c))
        }
    }
    @Test fun missingAndRotatedBridgeSecretRejectOldProof() {
        val a = auth(); val c = challenge(a)
        token = "rotated-synthetic-secret"
        assertNull(session(a, c))
        token = ""
        assertNull(LanTest.call(a, "challenge"))
    }
    @Test fun credentialsAreDistinctScopedSingleUseAndNeverTheHmacOrBridgeSecret() {
        val a = auth(); val c = challenge(a); val s = session(a, c)!!
        val id = s["sessionId"] as String
        val tokens = listOf("producerToken", "viewerToken", "controlToken").map { s[it] as String }
        assertEquals(3, tokens.toSet().size)
        assertTrue(tokens.all { it.length >= 32 && it != token && it != LanTest.proof("car-1", c["nonce"] as String, c["expiresAt"] as Long) })
        assertFalse(s.toString().contains(token))
        assertFalse(a.toString().contains(token))
        assertEquals(false, LanTest.call(a, "consume", id, "producer", tokens[1]))
        assertEquals(false, LanTest.call(a, "consume", "wrong", "producer", tokens[0]))
        assertEquals(true, LanTest.call(a, "consume", id, "producer", tokens[0]))
        assertEquals(false, LanTest.call(a, "consume", id, "producer", tokens[0]))
        assertEquals(true, LanTest.call(a, "consume", id, "viewer", tokens[1]))
        assertEquals(false, LanTest.call(a, "authorize", id, "download", tokens[2]))
        assertEquals(true, LanTest.call(a, "authorize", id, "control", tokens[2]))
    }
    @Test fun expiryRevocationAndSingleLiveSession() {
        val a = auth(); val s = session(a, challenge(a))!!
        assertNull(session(a, challenge(a)))
        val expiry = s["expiresAt"] as Long
        assertTrue(expiry > now && expiry - now <= 1_800_000L)
        now = expiry
        assertEquals(false, LanTest.call(a, "authorize", s["sessionId"], "control", s["controlToken"]))
        val next = session(a, challenge(a))!!
        LanTest.call(a, "revoke", next["sessionId"])
        assertEquals(false, LanTest.call(a, "consume", next["sessionId"], "viewer", next["viewerToken"]))
    }
    @Test fun downloadCredentialsAreReusableOnlyWithinTheirSessionAndExpiry() {
        val a = auth(); val s = session(a, challenge(a), "download")!!
        repeat(2) { assertEquals(true, LanTest.call(a, "authorize", s["sessionId"], "download", s["downloadToken"])) }
        assertEquals(false, LanTest.call(a, "consume", s["sessionId"], "viewer", s["downloadToken"]))
        now = s["expiresAt"] as Long
        assertEquals(false, LanTest.call(a, "authorize", s["sessionId"], "download", s["downloadToken"]))
    }
    @Test fun capabilityFieldsRequirePresentAuthorizedCamera() {
        val a = auth()
        for (installed in listOf(false, true)) for (authorized in listOf(false, true)) {
            val cap = LanTest.map(LanTest.call(a, "capabilities", installed, authorized))
            val enabled = if (installed && authorized) 1 else 0
            assertEquals(enabled, cap["cameraLiveLan"])
            assertEquals(enabled, cap["cameraDownloadLan"])
            assertEquals(1, cap["hvcVersion"]); assertEquals(1, cap["hvtVersion"])
        }
    }
}
