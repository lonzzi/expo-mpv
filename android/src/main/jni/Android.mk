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
