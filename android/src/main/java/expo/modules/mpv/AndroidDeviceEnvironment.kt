package expo.modules.mpv

import android.os.Build
import java.util.Locale

internal data class AndroidDeviceEnvironment(
    val bootQemu: String,
    val kernelQemu: String,
    val hardware: String,
    val board: String,
    val host: String,
    val fingerprint: String,
    val model: String,
    val manufacturer: String,
    val product: String,
) {
    // AOSP Build.IS_EMULATOR reads ro.boot.qemu, but is a hidden Java API.
    // Firmware hosts, board names and generic fingerprints also occur on phones.
    val emulatorReason: String?
        get() = when {
            bootQemu == "1" -> "ro.boot.qemu"
            kernelQemu == "1" -> "ro.kernel.qemu"
            hardware.lowercase(Locale.ROOT) in setOf("goldfish", "ranchu", "vbox86", "vbox86_64") -> "virtual-hardware"
            else -> null
        }

    val defaultHwdec: String get() = if (emulatorReason != null) "no" else "mediacodec"

    fun resolveHwdec(requested: String): String = if (requested == "auto") defaultHwdec else requested

    fun diagnostics(): Map<String, Any> = mapOf(
        "isEmulator" to (emulatorReason != null),
        "emulatorReason" to (emulatorReason ?: "none"),
        "bootQemu" to bootQemu,
        "kernelQemu" to kernelQemu,
        "defaultHwdec" to defaultHwdec,
        "hardware" to hardware,
        "board" to board,
        "host" to host,
        "fingerprint" to fingerprint,
        "model" to model,
        "manufacturer" to manufacturer,
        "product" to product,
    )

    companion object {
        fun current(): AndroidDeviceEnvironment {
            val qemu = MPVLib.nativeGetEmulatorProperties()
            return AndroidDeviceEnvironment(
                qemu[0], qemu[1], Build.HARDWARE, Build.BOARD, Build.HOST,
                Build.FINGERPRINT, Build.MODEL, Build.MANUFACTURER, Build.PRODUCT,
            )
        }
    }
}
