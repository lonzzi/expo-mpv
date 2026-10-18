#include <jni.h>
#include "FontDecoder.h"
#include <codecvt>
#include <locale>

extern "C" JNIEXPORT jobjectArray JNICALL
Java_expo_modules_mpv_ExpoMpvFontDecoder_families(JNIEnv *env, jobject, jstring input) {
  const char *source = env->GetStringUTFChars(input, nullptr);
  if (!source) return nullptr;
  jobjectArray result = nullptr;
  try {
    const auto families = expo_mpv::fontFamilies(source);
    result = env->NewObjectArray(families.size(), env->FindClass("java/lang/String"), nullptr);
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
    for (size_t index = 0; index < families.size() && result; index++) {
      const auto value = converter.from_bytes(families[index]);
      const auto text = env->NewString(reinterpret_cast<const jchar *>(value.data()), value.size());
      env->SetObjectArrayElement(result, index, text);
      env->DeleteLocalRef(text);
    }
  } catch (const std::exception &exception) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), exception.what());
  }
  env->ReleaseStringUTFChars(input, source);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_expo_modules_mpv_ExpoMpvFontDecoder_decode(
    JNIEnv *env, jobject, jstring input, jstring output) {
  const char *source = env->GetStringUTFChars(input, nullptr);
  if (!source) return;
  const char *destination = env->GetStringUTFChars(output, nullptr);
  if (!destination) { env->ReleaseStringUTFChars(input, source); return; }
  try {
    expo_mpv::decodeWoff2(source, destination);
  } catch (const std::exception &exception) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), exception.what());
  }
  env->ReleaseStringUTFChars(input, source);
  env->ReleaseStringUTFChars(output, destination);
}
