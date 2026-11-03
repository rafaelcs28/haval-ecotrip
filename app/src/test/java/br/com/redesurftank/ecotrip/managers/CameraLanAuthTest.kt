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
    fun serverProof(device: String, nonce: String, expires: Long, key: String = "synthetic-paired-secret"): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key.toByteArray(), "HmacSHA256"))
        return mac.doFinal("haval-camera-lan-server-v1|$device|$nonce|$expires".toByteArray())
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
    @Test fun exactServerProofVectorUsesSeparateDomain() {
        val nonce = "000102030405060708090a0b0c0d0e0f"
        val expected = "74827a55d7d59155958cbf202ea29b7a9ea99213953e6831f1ee9a8ff46dd8de"
        assertEquals(expected, LanTest.serverProof("car-1", nonce, 31_000))
        assertEquals(expected, LanTest.call(auth(), "serverProof", "car-1", nonce, 31_000L))
        assertNotEquals(LanTest.proof("car-1", nonce, 31_000), expected)
    }
    @Test fun serverProofBindsDeviceNonceExpiryAndCurrentToken() {
        val a = auth()
        val nonce = "000102030405060708090a0b0c0d0e0f"
        val baseline = LanTest.call(a, "serverProof", "car-1", nonce, 31_000L)
        assertNotEquals(baseline, LanTest.call(a, "serverProof", "car-2", nonce, 31_000L))
        assertNotEquals(baseline, LanTest.call(a, "serverProof", "car-1", "100102030405060708090a0b0c0d0e0f", 31_000L))
        assertNotEquals(baseline, LanTest.call(a, "serverProof", "car-1", nonce, 31_001L))
        token = "rotated-synthetic-secret"
        assertNotEquals(baseline, LanTest.call(a, "serverProof", "car-1", nonce, 31_000L))
    }
    @Test fun challengeEmitsExactServerProofJsonWithoutSecret() {
        val a = auth()
        val c = challenge(a)
        assertEquals(linkedSetOf("deviceId", "nonce", "expiresAt", "serverProof"), c.keys)
        val nonce = c.getValue("nonce") as String
        val expires = c.getValue("expiresAt") as Long
        val proof = c.getValue("serverProof") as String
        assertTrue(proof.matches(Regex("[0-9a-f]{64}")))
        assertEquals(LanTest.serverProof("car-1", nonce, expires), proof)
        assertEquals(
            "{\"deviceId\":\"car-1\",\"nonce\":\"$nonce\",\"expiresAt\":$expires,\"serverProof\":\"$proof\"}",
            com.google.gson.Gson().toJson(c),
        )
        assertFalse(c.toString().contains(token))
        assertFalse(a.toString().contains(token))
    }
    @Test fun challengeUsesFreshSafelyPublishedTokenAfterRotation() {
        val current = java.util.concurrent.atomic.AtomicReference("synthetic-paired-secret")
        val a = LanTest.create("CameraLanAuth", "car-1", { current.get() }, { now })
        val before = challenge(a)
        val rotated = "rotated-synthetic-secret"
        kotlin.concurrent.thread { current.set(rotated) }.join(5_000)
        val after = challenge(a)
        assertEquals(
            LanTest.serverProof("car-1", before["nonce"] as String, before["expiresAt"] as Long),
            before["serverProof"],
        )
        assertEquals(
            LanTest.serverProof("car-1", after["nonce"] as String, after["expiresAt"] as Long, rotated),
            after["serverProof"],
        )
        assertNotEquals(before["serverProof"], after["serverProof"])
        assertFalse(after.toString().contains(rotated))
    }
    @Test fun absentTokenStillRefusesChallenge() {
        token = ""
        assertNull(LanTest.call(auth(), "challenge"))
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
    @Test fun mqttBridgeTokenHasVolatileJvmContractAndRotationUsesFreshProof() {
        val field = MqttManager::class.java.getDeclaredField("bridgeToken")
        assertEquals(String::class.java, field.type)
        assertTrue("Pairing must publish the existing token field across threads",
            java.lang.reflect.Modifier.isVolatile(field.modifiers))
        val current = java.util.concurrent.atomic.AtomicReference("synthetic-paired-secret")
        val a = LanTest.create("CameraLanAuth", "car-1", { current.get() }, { now })
        val before = challenge(a)
        val next = challenge(a)
        val rotated = "rotated-synthetic-secret"
        val setter = kotlin.concurrent.thread { current.set(rotated) }
        setter.join(5_000)
        assertFalse(setter.isAlive)
        assertNull(session(a, before))
        val fresh = session(a, next, proof = LanTest.proof("car-1", next["nonce"] as String, next["expiresAt"] as Long, rotated))
        assertNotNull(fresh)
        assertFalse(fresh.toString().contains(rotated))
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
    @Test fun authenticatedDeleteIsIdempotentOnlyForTheOriginalControlTokenThroughExpiry() {
        val a = auth(); val s = session(a, challenge(a), "download")!!
        val id = s["sessionId"] as String
        val control = s["controlToken"] as String
        assertEquals(false, LanTest.call(a, "authorizeAndRevoke", id, "00".repeat(32)))
        assertEquals(true, LanTest.call(a, "authorize", id, "download", s["downloadToken"]))
        assertEquals(true, LanTest.call(a, "authorizeAndRevoke", id, control))
        assertEquals(false, LanTest.call(a, "authorize", id, "download", s["downloadToken"]))
        assertEquals(true, LanTest.call(a, "authorizeAndRevoke", id, control))
        assertEquals(false, LanTest.call(a, "authorizeAndRevoke", id, "11".repeat(32)))
        assertEquals(false, LanTest.call(a, "authorizeAndRevoke", "f".repeat(32), control))
        now = s["expiresAt"] as Long
        assertEquals(false, LanTest.call(a, "authorizeAndRevoke", id, control))
    }
    @Test fun deleteTombstonesAreBoundedPrunedAndZeroed() {
        val a = auth()
        val first = session(a, challenge(a), "download")!!
        assertEquals(true, LanTest.call(a, "authorizeAndRevoke", first["sessionId"], first["controlToken"]))
        val field = a.javaClass.getDeclaredField("tombstones").apply { isAccessible = true }
        val firstTombstone = (field.get(a) as Map<*, *>).values.single()!!
        val digestField = firstTombstone.javaClass.getDeclaredField("controlDigest").apply { isAccessible = true }
        val evictedDigest = digestField.get(firstTombstone) as ByteArray
        repeat(128) {
            val s = session(a, challenge(a), "download")!!
            assertEquals(true, LanTest.call(a, "authorizeAndRevoke", s["sessionId"], s["controlToken"]))
        }
        @Suppress("UNCHECKED_CAST")
        val tombstones = field.get(a) as Map<String, Any>
        assertEquals("revocation replay state must be bounded", 128, tombstones.size)
        assertTrue(evictedDigest.all { it == 0.toByte() })
        val retained = tombstones.values.first()
        val retainedDigest = digestField.get(retained) as ByteArray
        now += 300_000L
        LanTest.call(a, "active", "missing")
        assertTrue(retainedDigest.all { it == 0.toByte() })
        assertTrue((field.get(a) as Map<*, *>).isEmpty())

        val fresh = session(a, challenge(a), "download")!!
        LanTest.call(a, "authorizeAndRevoke", fresh["sessionId"], fresh["controlToken"])
        val clearDigest = digestField.get((field.get(a) as Map<*, *>).values.single()) as ByteArray
        LanTest.call(a, "clear")
        assertTrue(clearDigest.all { it == 0.toByte() })
    }
    @Test fun deleteRouteContractReturnsNoContentOnlyForAuthenticatedLiveOrTombstonedSession() {
        val a = auth(); val s = session(a, challenge(a), "download")!!
        val id = s["sessionId"] as String
        val control = s["controlToken"] as String
        assertEquals(401, LocalApiServer.deleteSessionStatus(a as CameraLanAuth, id, "00".repeat(32)))
        assertEquals(204, LocalApiServer.deleteSessionStatus(a, id, control))
        assertEquals(204, LocalApiServer.deleteSessionStatus(a, id, control))
    }
    @Test fun handshakeAdmissionIsBoundToCapturedLiveSessionAfterReplacement() {
        val a = auth(); val old = session(a, challenge(a))!!
        LanTest.call(a, "revoke", old["sessionId"])
        val next = session(a, challenge(a))!!
        assertEquals(false, LanTest.call(a, "admit", old["sessionId"], next["sessionId"], "viewer", old["viewerToken"]))
        assertEquals(false, LanTest.call(a, "admit", old["sessionId"], next["sessionId"], "viewer", next["viewerToken"]))
        assertEquals(true, LanTest.call(a, "admit", next["sessionId"], next["sessionId"], "viewer", next["viewerToken"]))
        assertEquals(false, LanTest.call(a, "admit", next["sessionId"], next["sessionId"], "viewer", next["viewerToken"]))
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
