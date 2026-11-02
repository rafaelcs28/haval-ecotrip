package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSettingsReaderTest {
    @Test fun acceptsCompleteBoundedPatchTypes() {
        val patch = mapOf<String, Any>(
            "automaticRecording" to true,
            "quality" to "standard",
            "reserveGb" to 10,
            "overlayPosition" to "bottom_left",
        )

        assertEquals(patch, CameraSettingsReader.validatePatch(patch))
    }

    @Test fun rejectsUnknownKeyAndInvalidValue() {
        assertFalse(runCatching {
            CameraSettingsReader.validatePatch(mapOf("location" to true))
        }.isSuccess)
        assertFalse(runCatching {
            CameraSettingsReader.validatePatch(mapOf("reserveGb" to 7))
        }.isSuccess)
        assertFalse(runCatching {
            CameraSettingsReader.validatePatch(mapOf("reserveGb" to 5.5))
        }.isSuccess)
        assertFalse(runCatching {
            CameraSettingsReader.validatePatch(mapOf("quality" to "ultra"))
        }.isSuccess)
    }

    @Test fun staleProviderUpdateReturnsRequeriedSnapshotAsConflict() {
        val current = CameraSettingsReader.ConfirmedSettings(
            5, true, linkedMapOf("automaticRecording" to false, "reserveGb" to 10),
        )

        val confirmed = CameraSettingsReader.confirmProviderUpdate(updateApplied = false, queried = current)
        val fields = CameraSettingsReader.responseFields(confirmed)

        assertEquals(5L, fields["revision"])
        assertEquals(false, fields["applied"])
        assertEquals(true, fields["conflict"])
        assertEquals(current.snapshot, fields["settings"])
        assertTrue((fields["settings"] as Map<*, *>)["reserveGb"] is Int)
    }
}
