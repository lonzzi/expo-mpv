package expo.modules.mpv

internal fun configureHardwareDecoding(
    mode: String,
    initialized: Boolean,
    setOption: (String, String) -> Unit,
    setProperty: (String, String) -> Unit,
) {
    val apply = if (initialized) setProperty else setOption
    if (mode != "no") {
        apply("hwdec-codecs", "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
    }
    apply("hwdec", mode)
}
