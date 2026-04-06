package expo.modules.mpv

import android.view.Surface

object MPVLib {
    init {
        System.loadLibrary("c++_shared")
        System.loadLibrary("mpv")
        System.loadLibrary("expo-mpv-jni")
    }

    // MPV format constants (must match mpv/client.h)
    const val FORMAT_NONE = 0
    const val FORMAT_STRING = 1
    const val FORMAT_FLAG = 3
    const val FORMAT_INT64 = 4
    const val FORMAT_DOUBLE = 5

    // MPV event IDs (from mpv/client.h)
    const val EVENT_LOG_MESSAGE = 1
    const val EVENT_START_FILE = 6
    const val EVENT_END_FILE = 7
    const val EVENT_FILE_LOADED = 8
    const val EVENT_SHUTDOWN = 12
    const val EVENT_SEEK = 20
    const val EVENT_PLAYBACK_RESTART = 21
    const val EVENT_PROPERTY_CHANGE = 22

    // ---- Lifecycle ----

    external fun nativeCreate(): Long
    external fun nativeSetCallback(ptr: Long, callback: Any)
    external fun nativeInitialize(ptr: Long): Int
    external fun nativeDestroy(ptr: Long)

    // ---- Surface ----

    external fun nativeAttachSurface(ptr: Long, surface: Surface)
    external fun nativeReattachSurface(ptr: Long, surface: Surface)
    external fun nativeDetachSurface(ptr: Long)

    // ---- Command ----

    external fun nativeCommand(ptr: Long, args: Array<String>): Int

    // ---- Options (before init) ----

    external fun nativeSetOptionString(ptr: Long, name: String, value: String): Int

    // ---- Property set ----

    external fun nativeSetPropertyLong(ptr: Long, name: String, value: Long): Int
    external fun nativeSetPropertyDouble(ptr: Long, name: String, value: Double): Int
    external fun nativeSetPropertyBoolean(ptr: Long, name: String, value: Boolean): Int
    external fun nativeSetPropertyString(ptr: Long, name: String, value: String): Int

    // ---- Property get ----

    external fun nativeGetPropertyLong(ptr: Long, name: String): Long
    external fun nativeGetPropertyDouble(ptr: Long, name: String): Double
    external fun nativeGetPropertyBoolean(ptr: Long, name: String): Boolean
    external fun nativeGetPropertyString(ptr: Long, name: String): String?

    // ---- Observation ----

    external fun nativeObserveProperty(ptr: Long, name: String, format: Int)
}
