require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoMpv'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = {
    :ios => '16.0'
  }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/lonzzi/expo-mpv' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # System frameworks required by MPVKit
  s.frameworks = [
    'Metal',
    'AVFoundation',
    'MediaPlayer',
    'CoreAudio',
    'AudioToolbox',
    'CoreVideo',
    'CoreMedia',
    'VideoToolbox',
    'QuartzCore',
    'CoreFoundation',
    'IOSurface',
    'CoreGraphics',
    'CoreText',
  ]

  s.libraries = ['bz2', 'iconv', 'expat', 'resolv', 'xml2', 'z', 'c++']

  # Vendored XCFrameworks downloaded by the Expo config plugin during prebuild
  s.vendored_frameworks = 'ios/Frameworks/*.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/cpp/fonts/vendor/woff2/include" "$(PODS_TARGET_SRCROOT)/cpp/fonts/vendor/brotli/c/include"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) BROTLI_BUILD_PORTABLE',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/ios/Frameworks" "${PODS_XCFRAMEWORKS_BUILD_DIR}/ExpoMpv"',
    'SWIFT_INCLUDE_PATHS' => '$(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/ExpoMpv"',
  }

  s.source_files = 'ios/*.{h,m,mm,swift,hpp,cpp}', 'cpp/fonts/*.{h,cpp}',
    'cpp/fonts/vendor/woff2/src/*.{h,cc}', 'cpp/fonts/vendor/woff2/include/**/*.h',
    'cpp/fonts/vendor/brotli/c/{common,dec}/*.{h,c}',
    'cpp/fonts/vendor/brotli/c/include/**/*.h'
  s.public_header_files = 'ios/ExpoMpvFontDecoder.h'

  # Bundle the CJK font for subtitle rendering
  # iOS 18+ system fonts use HVGL format which FreeType/libass cannot parse
  # Keep libass from treating the app executable, assets and frameworks as fonts.
  s.resource_bundles = { 'ExpoMpvFonts' => ['ios/Fonts/*.otf', 'ios/Fonts/*.ttf'] }
end
