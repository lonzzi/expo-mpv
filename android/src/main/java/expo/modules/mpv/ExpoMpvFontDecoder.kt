package expo.modules.mpv

import android.net.Uri

internal object ExpoMpvFontDecoder {
  init { System.loadLibrary("expo-mpv-fonts") }
  private external fun decode(input: String, output: String)
  private external fun families(input: String): Array<String>

  private fun localPath(uri: String): String {
    val file = Uri.parse(uri)
    require(file.scheme == "file") { "Font paths must be local files" }
    return requireNotNull(file.path)
  }

  fun fontFamilies(uri: String): List<String> = families(localPath(uri)).toList()

  fun decodeWoff2(input: String, output: String) {
    decode(localPath(input), localPath(output))
  }
}
