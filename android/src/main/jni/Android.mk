LOCAL_PATH := $(call my-dir)

# Prebuilt libmpv — resolves from jniLibs (populated by Gradle download task)
include $(CLEAR_VARS)
LOCAL_MODULE := mpv
LOCAL_SRC_FILES := ../jniLibs/$(TARGET_ARCH_ABI)/libmpv.so
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/include
include $(PREBUILT_SHARED_LIBRARY)

# Our JNI bridge
include $(CLEAR_VARS)
LOCAL_MODULE := expo-mpv-jni
LOCAL_SRC_FILES := mpv_jni.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/include
LOCAL_SHARED_LIBRARIES := mpv
LOCAL_LDLIBS := -llog -ldl
include $(BUILD_SHARED_LIBRARY)

# Font utilities do not initialize or link the playback engine.
include $(CLEAR_VARS)
FONT_ROOT := $(LOCAL_PATH)/../../../../cpp/fonts
LOCAL_MODULE := expo-mpv-fonts
LOCAL_SRC_FILES := font_jni.cpp \
  ../../../../cpp/fonts/FontDecoder.cpp \
  ../../../../cpp/fonts/FontMetadata.cpp
LOCAL_SRC_FILES += $(patsubst $(LOCAL_PATH)/%,%,$(wildcard $(FONT_ROOT)/vendor/woff2/src/*.cc))
LOCAL_SRC_FILES += $(patsubst $(LOCAL_PATH)/%,%,$(wildcard $(FONT_ROOT)/vendor/brotli/c/common/*.c))
LOCAL_SRC_FILES += $(patsubst $(LOCAL_PATH)/%,%,$(wildcard $(FONT_ROOT)/vendor/brotli/c/dec/*.c))
LOCAL_C_INCLUDES := $(FONT_ROOT) $(FONT_ROOT)/vendor/woff2/include $(FONT_ROOT)/vendor/brotli/c/include
LOCAL_CPPFLAGS := -std=c++17
LOCAL_CPP_FEATURES := exceptions
LOCAL_CFLAGS := -DBROTLI_BUILD_PORTABLE
LOCAL_LDLIBS := -lz
LOCAL_LDFLAGS := -Wl,-z,max-page-size=16384
include $(BUILD_SHARED_LIBRARY)
