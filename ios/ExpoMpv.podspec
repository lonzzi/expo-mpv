require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

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

  # Download MPVKit xcframeworks if not present
  s.script_phase = {
    :name => 'Download MPVKit XCFrameworks',
    :script => 'bash "${PODS_TARGET_SRCROOT}/download-mpvkit.sh"',
    :execution_position => :before_compile,
  }

  # System frameworks required by MPVKit
  s.frameworks = [
    'Metal',
    'AVFoundation',
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

  # Vendored xcframeworks from download-mpvkit.sh
  s.vendored_frameworks = 'Frameworks/*.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }

  s.source_files = "*.{h,m,mm,swift,hpp,cpp}"
end
