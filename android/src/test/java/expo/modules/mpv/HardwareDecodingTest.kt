package expo.modules.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HardwareDecodingTest {
    private val sony = AndroidDeviceEnvironment(
        bootQemu = "", kernelQemu = "", hardware = "qcom",
        board = "pineapple", host = "firmware-builder",
        fingerprint = "Sony/XQ-EC72/XQ-EC72:16/release-keys",
        model = "XQ-EC72", manufacturer = "Sony", product = "XQ-EC72",
    )

    @Test
    fun sonyFirmwareBuiltOnBuildHostKeepsHardwareDecoding() {
        val device = sony.copy(host = "BuildHost01")
        assertEquals("mediacodec", device.defaultHwdec)
        assertNull(device.emulatorReason)
    }

    @Test
    fun physicalQualcommReferenceBoardKeepsHardwareDecoding() {
        assertEquals("mediacodec", sony.copy(board = "QC_Reference_Phone").defaultHwdec)
    }

    @Test
    fun customFirmwareDoesNotDisableHardwareDecoding() {
        assertEquals("mediacodec", sony.copy(fingerprint = "generic/unknown", model = "Emulator edition").defaultHwdec)
    }

    @Test
    fun bootQemuDetectsEmulatorEvenWithPhysicalDeviceBranding() {
        val device = sony.copy(bootQemu = "1")
        assertEquals("no", device.defaultHwdec)
        assertEquals("ro.boot.qemu", device.emulatorReason)
    }

    @Test
    fun legacyQemuFlagSupportsOlderEmulators() {
        assertEquals("no", sony.copy(kernelQemu = "1").defaultHwdec)
    }

    @Test
    fun zeroQemuFlagsDoNotDisableHardwareDecoding() {
        assertEquals("mediacodec", sony.copy(bootQemu = "0", kernelQemu = "0").defaultHwdec)
    }

    @Test
    fun exactVirtualHardwareIdentifiersAreRecognizedWithoutQemuFlags() {
        for (hardware in listOf("ranchu", "goldfish", "vbox86", "VBOX86_64")) {
            assertEquals("no", sony.copy(hardware = hardware).defaultHwdec)
        }
        assertEquals("mediacodec", sony.copy(hardware = "ranchu-custom-qcom").defaultHwdec)
    }

    @Test
    fun explicitHardwareChoiceOverridesEmulatorSafeguardAndAutoRestoresIt() {
        val emulator = sony.copy(bootQemu = "1")
        assertEquals("mediacodec", emulator.resolveHwdec("mediacodec"))
        assertEquals("no", emulator.resolveHwdec("auto"))
        assertEquals("no", sony.resolveHwdec("no"))
        assertEquals("mediacodec", sony.resolveHwdec("auto"))
    }

    @Test
    fun diagnosticsExposeWhyDecodingWasDisabled() {
        val result = sony.copy(bootQemu = "1").diagnostics()
        assertEquals(true, result["isEmulator"])
        assertEquals("ro.boot.qemu", result["emulatorReason"])
        assertEquals("no", result["defaultHwdec"])
    }
}
