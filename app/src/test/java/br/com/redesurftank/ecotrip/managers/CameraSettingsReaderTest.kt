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
            CameraSettingsReader.validatePatch(mapOf("quality" to "ultra"))
        }.isSuccess)
    }

    @Test fun confirmedResponseKeepsTypedSnapshotAndConflict() {
        val snapshot = linkedMapOf<String, Any>("automaticRecording" to true, "reserveGb" to 5)
        val confirmed = CameraSettingsReader.ConfirmedSettings(4, false, snapshot)

        assertFalse(confirmed.applied)
        assertTrue(confirmed.snapshot["automaticRecording"] is Boolean)
        assertTrue(confirmed.snapshot["reserveGb"] is Int)
    }
}
