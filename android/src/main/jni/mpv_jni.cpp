#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <atomic>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <dlfcn.h>

extern "C" {
#include <mpv/client.h>
}

#define TAG "ExpoMpv"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)

// Per-instance player context
struct PlayerContext {
    mpv_handle *mpv;
    JavaVM *jvm;
    jobject callback;
    pthread_t eventThread;
    std::atomic<bool> running;
    jobject surface; // Java Surface global ref

    // Cached callback method IDs
    jmethodID onEventMethod;
    jmethodID onPropertyChangeMethod;
    jmethodID onEndFileMethod;
    jmethodID onLogMessageMethod;

    PlayerContext()
        : mpv(nullptr), jvm(nullptr), callback(nullptr), running(false),
          surface(nullptr), onEventMethod(nullptr), onPropertyChangeMethod(nullptr),
          onEndFileMethod(nullptr), onLogMessageMethod(nullptr) {}
};

// ---- Helpers ----

static jobject boxBoolean(JNIEnv *env, bool value) {
    jclass cls = env->FindClass("java/lang/Boolean");
    jmethodID mid = env->GetStaticMethodID(cls, "valueOf", "(Z)Ljava/lang/Boolean;");
    return env->CallStaticObjectMethod(cls, mid, (jboolean)value);
}

static jobject boxLong(JNIEnv *env, int64_t value) {
    jclass cls = env->FindClass("java/lang/Long");
    jmethodID mid = env->GetStaticMethodID(cls, "valueOf", "(J)Ljava/lang/Long;");
    return env->CallStaticObjectMethod(cls, mid, (jlong)value);
}

static jobject boxDouble(JNIEnv *env, double value) {
    jclass cls = env->FindClass("java/lang/Double");
    jmethodID mid = env->GetStaticMethodID(cls, "valueOf", "(D)Ljava/lang/Double;");
    return env->CallStaticObjectMethod(cls, mid, (jdouble)value);
}

static jobject propertyValueToJavaObject(JNIEnv *env, mpv_event_property *prop) {
    if (!prop->data) return nullptr;
    switch (prop->format) {
    case MPV_FORMAT_FLAG:
        return boxBoolean(env, *(int *)prop->data != 0);
    case MPV_FORMAT_INT64:
        return boxLong(env, *(int64_t *)prop->data);
    case MPV_FORMAT_DOUBLE:
        return boxDouble(env, *(double *)prop->data);
    case MPV_FORMAT_STRING: {
        const char *str = *(const char **)prop->data;
        return str ? env->NewStringUTF(str) : nullptr;
    }
    default:
        return nullptr;
    }
}

// ---- Event Thread ----

static void *eventThreadFunc(void *arg) {
    PlayerContext *ctx = (PlayerContext *)arg;
    JNIEnv *env = nullptr;

    ctx->jvm->AttachCurrentThread(&env, nullptr);
    if (!env) {
        LOGE("Failed to attach event thread to JVM");
        return nullptr;
    }
    LOGI("Event thread running");

    while (ctx->running) {
        mpv_event *event = mpv_wait_event(ctx->mpv, -1.0);

        if (!ctx->running) break;
        if (!event || event->event_id == MPV_EVENT_NONE) continue;

        LOGD("mpv event: %s (%d)", mpv_event_name(event->event_id), event->event_id);

        switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE: {
            mpv_event_property *prop = (mpv_event_property *)event->data;
            if (prop && ctx->callback && ctx->onPropertyChangeMethod) {
                jstring name = env->NewStringUTF(prop->name ? prop->name : "");
                jobject value = propertyValueToJavaObject(env, prop);
                env->CallVoidMethod(ctx->callback, ctx->onPropertyChangeMethod, name, value);
                if (env->ExceptionCheck()) {
                    LOGE("JNI Exception in onPropertyChange");
                    env->ExceptionClear();
                }
                if (name) env->DeleteLocalRef(name);
                if (value) env->DeleteLocalRef(value);
            }
            break;
        }
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *ef = (mpv_event_end_file *)event->data;
            if (ctx->callback && ctx->onEndFileMethod) {
                const char *reason = "unknown";
                switch (ef->reason) {
                case MPV_END_FILE_REASON_EOF: reason = "ended"; break;
                case MPV_END_FILE_REASON_STOP: reason = "stopped"; break;
                case MPV_END_FILE_REASON_ERROR: reason = "error"; break;
                default: break;
                }
                const char *errorStr = (ef->reason == MPV_END_FILE_REASON_ERROR && ef->error < 0)
                    ? mpv_error_string(ef->error) : "";
                jstring jreason = env->NewStringUTF(reason);
                jstring jerror = env->NewStringUTF(errorStr);
                env->CallVoidMethod(ctx->callback, ctx->onEndFileMethod, jreason, jerror);
                env->DeleteLocalRef(jreason);
                env->DeleteLocalRef(jerror);
            }
            break;
        }
        case MPV_EVENT_LOG_MESSAGE: {
            mpv_event_log_message *msg = (mpv_event_log_message *)event->data;
            if (msg) {
                LOGD("[%s] [%s] %s", msg->prefix ? msg->prefix : "",
                     msg->level ? msg->level : "", msg->text ? msg->text : "");
            }
            if (msg && ctx->callback && ctx->onLogMessageMethod) {
                jstring prefix = env->NewStringUTF(msg->prefix ? msg->prefix : "");
                jstring level = env->NewStringUTF(msg->level ? msg->level : "");
                jstring text = env->NewStringUTF(msg->text ? msg->text : "");
                env->CallVoidMethod(ctx->callback, ctx->onLogMessageMethod, prefix, level, text);
                if (env->ExceptionCheck()) {
                    env->ExceptionClear();
                }
                env->DeleteLocalRef(prefix);
                env->DeleteLocalRef(level);
                env->DeleteLocalRef(text);
            }
            break;
        }
        case MPV_EVENT_SHUTDOWN:
            if (ctx->callback && ctx->onEventMethod)
                env->CallVoidMethod(ctx->callback, ctx->onEventMethod, (jint)event->event_id);
            ctx->running = false;
            break;
        default:
            if (ctx->callback && ctx->onEventMethod)
                env->CallVoidMethod(ctx->callback, ctx->onEventMethod, (jint)event->event_id);
            break;
        }

        if (!ctx->running) break;
    }

    ctx->jvm->DetachCurrentThread();
    return nullptr;
}

// ---- JNI Native Functions ----

static jlong nativeCreate(JNIEnv *env, jobject /*thiz*/) {
    PlayerContext *ctx = new PlayerContext();
    ctx->mpv = mpv_create();
    if (!ctx->mpv) {
        LOGE("Failed to create mpv instance");
        delete ctx;
        return 0;
    }
    env->GetJavaVM(&ctx->jvm);
    mpv_request_log_messages(ctx->mpv, "v");
    return (jlong)ctx;
}

static void nativeSetCallback(JNIEnv *env, jobject /*thiz*/, jlong ptr, jobject callback) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx) return;
    if (ctx->callback) env->DeleteGlobalRef(ctx->callback);
    ctx->callback = callback ? env->NewGlobalRef(callback) : nullptr;
    if (callback) {
        jclass cls = env->GetObjectClass(callback);
        ctx->onEventMethod = env->GetMethodID(cls, "onEvent", "(I)V");
        ctx->onPropertyChangeMethod = env->GetMethodID(cls, "onPropertyChange", "(Ljava/lang/String;Ljava/lang/Object;)V");
        ctx->onEndFileMethod = env->GetMethodID(cls, "onEndFile", "(Ljava/lang/String;Ljava/lang/String;)V");
        ctx->onLogMessageMethod = env->GetMethodID(cls, "onLogMessage", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
    }
}

// Attach surface BEFORE mpv_initialize — uses mpv_set_option
static void nativeAttachSurface(JNIEnv *env, jobject /*thiz*/, jlong ptr, jobject surface) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return;

    if (ctx->surface) {
        env->DeleteGlobalRef(ctx->surface);
        ctx->surface = nullptr;
    }
    if (surface) {
        ctx->surface = env->NewGlobalRef(surface);
        int64_t wid = (int64_t)(intptr_t)ctx->surface;
        int ret = mpv_set_option(ctx->mpv, "wid", MPV_FORMAT_INT64, &wid);
        if (ret < 0)
            LOGE("mpv_set_option(wid) failed: %s", mpv_error_string(ret));
        else
            LOGI("Surface attached (pre-init), wid=%lld", (long long)wid);
    }
}

// Reattach surface AFTER mpv_initialize — uses mpv_set_property
static void nativeReattachSurface(JNIEnv *env, jobject /*thiz*/, jlong ptr, jobject surface) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return;

    if (ctx->surface) {
        env->DeleteGlobalRef(ctx->surface);
        ctx->surface = nullptr;
    }
    if (surface) {
        ctx->surface = env->NewGlobalRef(surface);
        int64_t wid = (int64_t)(intptr_t)ctx->surface;
        int ret = mpv_set_property(ctx->mpv, "wid", MPV_FORMAT_INT64, &wid);
        if (ret < 0)
            LOGE("mpv_set_property(wid) failed: %s", mpv_error_string(ret));
        else
            LOGI("Surface reattached (post-init), wid=%lld", (long long)wid);
    }
}

static void nativeDetachSurface(JNIEnv *env, jobject /*thiz*/, jlong ptr) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return;

    int64_t wid = 0;
    mpv_set_property(ctx->mpv, "wid", MPV_FORMAT_INT64, &wid);
    if (ctx->surface) {
        env->DeleteGlobalRef(ctx->surface);
        ctx->surface = nullptr;
    }
}

static jint nativeInitialize(JNIEnv *env, jobject /*thiz*/, jlong ptr) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;

    int ret = mpv_initialize(ctx->mpv);
    if (ret < 0) {
        LOGE("mpv_initialize failed: %s", mpv_error_string(ret));
        return ret;
    }

    ctx->running = true;
    int thread_ret = pthread_create(&ctx->eventThread, nullptr, eventThreadFunc, ctx);
    if (thread_ret != 0) {
        LOGE("pthread_create failed: %d", thread_ret);
        ctx->running = false;
        return -1;
    }
    LOGI("mpv initialized, event thread started");
    return 0;
}

static void nativeDestroy(JNIEnv *env, jobject /*thiz*/, jlong ptr) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx) return;

    if (ctx->running) {
        ctx->running = false;
        mpv_wakeup(ctx->mpv);
        pthread_join(ctx->eventThread, nullptr);
    }
    if (ctx->mpv) {
        mpv_terminate_destroy(ctx->mpv);
        ctx->mpv = nullptr;
    }
    if (ctx->callback) {
        env->DeleteGlobalRef(ctx->callback);
        ctx->callback = nullptr;
    }
    if (ctx->surface) {
        env->DeleteGlobalRef(ctx->surface);
        ctx->surface = nullptr;
    }
    delete ctx;
}

static jint nativeCommand(JNIEnv *env, jobject /*thiz*/, jlong ptr, jobjectArray jargs) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;

    int len = env->GetArrayLength(jargs);
    std::vector<const char *> args;
    std::vector<jstring> refs;
    for (int i = 0; i < len; i++) {
        auto s = (jstring)env->GetObjectArrayElement(jargs, i);
        refs.push_back(s);
        args.push_back(s ? env->GetStringUTFChars(s, nullptr) : nullptr);
    }
    args.push_back(nullptr);

    int ret = mpv_command(ctx->mpv, args.data());

    for (int i = 0; i < len; i++) {
        if (refs[i] && args[i]) env->ReleaseStringUTFChars(refs[i], args[i]);
        if (refs[i]) env->DeleteLocalRef(refs[i]);
    }
    return ret;
}

static jint nativeSetOptionString(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name, jstring value) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    const char *cvalue = env->GetStringUTFChars(value, nullptr);
    int ret = mpv_set_option_string(ctx->mpv, cname, cvalue);
    if (ret < 0) LOGE("mpv_set_option_string(%s, %s) failed: %s", cname, cvalue, mpv_error_string(ret));
    env->ReleaseStringUTFChars(name, cname);
    env->ReleaseStringUTFChars(value, cvalue);
    return ret;
}

static jint nativeSetPropertyLong(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name, jlong value) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    int64_t v = (int64_t)value;
    int ret = mpv_set_property(ctx->mpv, cname, MPV_FORMAT_INT64, &v);
    env->ReleaseStringUTFChars(name, cname);
    return ret;
}

static jint nativeSetPropertyDouble(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name, jdouble value) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    double v = (double)value;
    int ret = mpv_set_property(ctx->mpv, cname, MPV_FORMAT_DOUBLE, &v);
    env->ReleaseStringUTFChars(name, cname);
    return ret;
}

static jint nativeSetPropertyBoolean(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name, jboolean value) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    int v = value ? 1 : 0;
    int ret = mpv_set_property(ctx->mpv, cname, MPV_FORMAT_FLAG, &v);
    env->ReleaseStringUTFChars(name, cname);
    return ret;
}

static jint nativeSetPropertyString(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name, jstring value) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return -1;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    const char *cvalue = env->GetStringUTFChars(value, nullptr);
    int ret = mpv_set_property_string(ctx->mpv, cname, cvalue);
    env->ReleaseStringUTFChars(name, cname);
    env->ReleaseStringUTFChars(value, cvalue);
    return ret;
}

static jlong nativeGetPropertyLong(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return 0;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    int64_t value = 0;
    mpv_get_property(ctx->mpv, cname, MPV_FORMAT_INT64, &value);
    env->ReleaseStringUTFChars(name, cname);
    return (jlong)value;
}

static jdouble nativeGetPropertyDouble(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return 0.0;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    double value = 0.0;
    mpv_get_property(ctx->mpv, cname, MPV_FORMAT_DOUBLE, &value);
    env->ReleaseStringUTFChars(name, cname);
    return (jdouble)value;
}

static jboolean nativeGetPropertyBoolean(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return JNI_FALSE;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    int value = 0;
    mpv_get_property(ctx->mpv, cname, MPV_FORMAT_FLAG, &value);
    env->ReleaseStringUTFChars(name, cname);
    return value ? JNI_TRUE : JNI_FALSE;
}

static jstring nativeGetPropertyString(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return nullptr;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    char *value = mpv_get_property_string(ctx->mpv, cname);
    env->ReleaseStringUTFChars(name, cname);
    if (!value) return nullptr;
    jstring result = env->NewStringUTF(value);
    mpv_free(value);
    return result;
}

static void nativeObserveProperty(JNIEnv *env, jobject /*thiz*/, jlong ptr, jstring name, jint format) {
    PlayerContext *ctx = (PlayerContext *)ptr;
    if (!ctx || !ctx->mpv) return;
    const char *cname = env->GetStringUTFChars(name, nullptr);
    mpv_observe_property(ctx->mpv, 0, cname, (mpv_format)format);
    env->ReleaseStringUTFChars(name, cname);
}

// ---- JNI Registration ----

static JNINativeMethod methods[] = {
    {"nativeCreate", "()J", (void *)nativeCreate},
    {"nativeSetCallback", "(JLjava/lang/Object;)V", (void *)nativeSetCallback},
    {"nativeInitialize", "(J)I", (void *)nativeInitialize},
    {"nativeDestroy", "(J)V", (void *)nativeDestroy},
    {"nativeAttachSurface", "(JLandroid/view/Surface;)V", (void *)nativeAttachSurface},
    {"nativeReattachSurface", "(JLandroid/view/Surface;)V", (void *)nativeReattachSurface},
    {"nativeDetachSurface", "(J)V", (void *)nativeDetachSurface},
    {"nativeCommand", "(J[Ljava/lang/String;)I", (void *)nativeCommand},
    {"nativeSetOptionString", "(JLjava/lang/String;Ljava/lang/String;)I", (void *)nativeSetOptionString},
    {"nativeSetPropertyLong", "(JLjava/lang/String;J)I", (void *)nativeSetPropertyLong},
    {"nativeSetPropertyDouble", "(JLjava/lang/String;D)I", (void *)nativeSetPropertyDouble},
    {"nativeSetPropertyBoolean", "(JLjava/lang/String;Z)I", (void *)nativeSetPropertyBoolean},
    {"nativeSetPropertyString", "(JLjava/lang/String;Ljava/lang/String;)I", (void *)nativeSetPropertyString},
    {"nativeGetPropertyLong", "(JLjava/lang/String;)J", (void *)nativeGetPropertyLong},
    {"nativeGetPropertyDouble", "(JLjava/lang/String;)D", (void *)nativeGetPropertyDouble},
    {"nativeGetPropertyBoolean", "(JLjava/lang/String;)Z", (void *)nativeGetPropertyBoolean},
    {"nativeGetPropertyString", "(JLjava/lang/String;)Ljava/lang/String;", (void *)nativeGetPropertyString},
    {"nativeObserveProperty", "(JLjava/lang/String;I)V", (void *)nativeObserveProperty},
};

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void * /*reserved*/) {
    JNIEnv *env;
    if (vm->GetEnv((void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        LOGE("GetEnv failed");
        return JNI_ERR;
    }

    // Set up FFmpeg JNI context for hardware decoding (mediacodec)
    void *avcodec = dlopen("libavcodec.so", RTLD_NOLOAD);
    if (!avcodec) avcodec = dlopen("libavcodec.so", RTLD_LAZY);
    if (avcodec) {
        typedef int (*av_jni_set_java_vm_fn)(void *, void *);
        auto fn = (av_jni_set_java_vm_fn)dlsym(avcodec, "av_jni_set_java_vm");
        if (fn) {
            fn(vm, nullptr);
            LOGI("av_jni_set_java_vm set");
        }
    }

    jclass cls = env->FindClass("expo/modules/mpv/MPVLib");
    if (!cls) {
        LOGE("Failed to find MPVLib class");
        return JNI_ERR;
    }

    int count = sizeof(methods) / sizeof(methods[0]);
    if (env->RegisterNatives(cls, methods, count) < 0) {
        LOGE("Failed to register native methods");
        return JNI_ERR;
    }

    LOGI("Native methods registered (%d methods)", count);
    return JNI_VERSION_1_6;
}
