package expo.modules.mpv

import org.junit.Assert.assertEquals
import org.junit.Test

class HardwareDecodingConfigurationTest {
    @Test
    fun hardwareChoiceBeforeInitializationUpdatesNativeOptions() {
        val options = mutableListOf<Pair<String, String>>()
        configureHardwareDecoding("mediacodec", false, { k, v -> options.add(k to v) }, { _, _ -> error("Player not initialized") })
        assertEquals(listOf("hwdec-codecs", "hwdec"), options.map { it.first })
        assertEquals("mediacodec", options.last().second)
    }

    @Test
    fun softwareChoiceBeforeInitializationReplacesHardwareDefault() {
        val options = mutableMapOf("hwdec" to "mediacodec")
        configureHardwareDecoding("no", false, { k, v -> options[k] = v }, { _, _ -> error("Player not initialized") })
        assertEquals(mapOf("hwdec" to "no"), options)
    }

    @Test
    fun initializedPlayerUsesRuntimeProperties() {
        val properties = mutableMapOf<String, String>()
        configureHardwareDecoding("mediacodec-copy", true, { _, _ -> error("Already initialized") }, { k, v -> properties[k] = v })
        assertEquals("mediacodec-copy", properties["hwdec"])
    }

    @Test
    fun runtimeSoftwareSelectionDoesNotChangeCodecRestrictions() {
        val properties = mutableMapOf<String, String>()
        configureHardwareDecoding("no", true, { _, _ -> error("Already initialized") }, { k, v -> properties[k] = v })
        assertEquals(mapOf("hwdec" to "no"), properties)
    }
}
