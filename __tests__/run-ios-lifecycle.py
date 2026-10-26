#!/usr/bin/env python3
"""Stress the production expo-mpv view's real callbacks, rendering and teardown.

Requires Xcode, ffmpeg, the downloaded MPVKit frameworks and a booted simulator.
Only the Expo bridge is stubbed. Build output and metrics stay outside the repo.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'expo.modules.mpv.lifecycle-regression'


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def build(work, module):
    sdk = command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    arch = command('uname', '-m')
    base = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-sdk', sdk, '-target',
            f'{arch}-apple-ios17.5-simulator', '-swift-version', '5', '-g', '-Onone']
    sources = ROOT / '__tests__/ios-lifecycle'
    app = work / 'LifecycleTest.app'
    app.mkdir()
    with (work / 'build.log').open('w') as log:
        def compile_swift(args):
            subprocess.run(base + args, check=True, env={**os.environ, 'SDKROOT': sdk},
                           stdout=log, stderr=log)
        compile_swift(['-emit-library', '-static', '-emit-module', '-module-name',
                       'ExpoModulesCore', str(ROOT / '__tests__/ios-commands/ExpoModulesCore.swift'),
                       '-emit-module-path', str(work / 'ExpoModulesCore.swiftmodule'),
                       '-o', str(work / 'libExpoModulesCore.a')])
        args = ['-module-name', 'LifecycleTest', '-I', str(work), str(sources / 'App.swift'),
                str(module / 'ios/ExpoMpvView.swift'), str(work / 'libExpoModulesCore.a')]
        for framework in sorted((module / 'ios/Frameworks').glob('*.xcframework')):
            info = plistlib.loads((framework / 'Info.plist').read_bytes())
            lib = next((entry for entry in info['AvailableLibraries']
                        if entry.get('SupportedPlatform') == 'ios'
                        and entry.get('SupportedPlatformVariant') == 'simulator'
                        and arch in entry['SupportedArchitectures']), None)
            if lib:
                directory = framework / lib['LibraryIdentifier']
                if lib['LibraryPath'].endswith('.framework'):
                    args += ['-F', str(directory), '-framework', framework.stem]
                else:
                    args.append(str(directory / lib['LibraryPath']))
        for name in ['UIKit', 'Foundation', 'Metal', 'AVFoundation', 'CoreAudio',
                     'AudioToolbox', 'CoreVideo', 'CoreMedia', 'VideoToolbox', 'QuartzCore',
                     'CoreFoundation', 'IOSurface', 'CoreGraphics', 'CoreText', 'Security',
                     'SystemConfiguration', 'Accelerate']:
            args += ['-framework', name]
        args += ['-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2', '-lz', '-lc++',
                 '-o', str(app / 'LifecycleTest')]
        compile_swift(args)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'LifecycleTest',
        'CFBundleName': 'MPV Lifecycle Test', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'MinimumOSVersion': '17.5', 'LSRequiresIPhoneOS': True,
        'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
    }))
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=320x180:rate=30', '-t', '5', '-c:v', 'libx264',
                    '-preset', 'ultrafast', '-crf', '30', '-movflags', '+faststart',
                    str(app / 'fixture.mp4')], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True,
                   capture_output=True)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', default=os.environ.get('SIMULATOR_UDID'))
    parser.add_argument('--cycles', type=int, default=40)
    parser.add_argument('--module', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.cycles < 2:
        parser.error('--cycles must be at least 2')
    devices = json.loads(command('xcrun', 'simctl', 'list', 'devices', 'booted', '-j'))['devices']
    booted = [device['udid'] for runtime, group in devices.items() if 'iOS' in runtime
              for device in group if device['state'] == 'Booted']
    simulator = args.simulator or next(iter(booted), None)
    if simulator not in booted:
        parser.error('Select a booted iOS simulator with --simulator or SIMULATOR_UDID')
    work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='expo-mpv-lifecycle-'))
    work.mkdir(parents=True, exist_ok=True)
    print(f'Artifacts: {work}', flush=True)
    source = args.module / 'ios/ExpoMpvView.swift'
    (work / 'source.json').write_text(json.dumps({
        'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'simulator': simulator, 'cycles': args.cycles,
    }, indent=2) + '\n')
    try:
        app = build(work, args.module)
        command('xcrun', 'simctl', 'install', simulator, str(app))
        container = Path(command('xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'))
        result = container / 'Documents/lifecycle.json'
        result.unlink(missing_ok=True)
        launch = command('xcrun', 'simctl', 'launch', simulator, BUNDLE, '--cycles', str(args.cycles))
        pid = int(launch.rsplit(':', 1)[1].strip())
        deadline = time.monotonic() + args.cycles * 3 + 30
        data = {}
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                raise AssertionError(f'Player process exited before completion: {data}') from None
            if result.exists():
                data = json.loads(result.read_text())
                (work / 'lifecycle.json').write_text(json.dumps(data, indent=2) + '\n')
                if data['finished']:
                    break
            time.sleep(0.25)
        assert data.get('finished'), f'No final result (crash or stalled player): {data}'
        assert data['created'] == data['loaded'] == data['retired'] == args.cycles, data
        assert data['retainedViews'] == 0 and not data['errors'], data
        assert len(data['firstPositions']) == args.cycles, data
        for actual, expected in zip(data['firstPositions'], data['expectedPositions']):
            assert expected - 0.05 <= actual < expected + 1, (actual, expected)
        print(f"PASS: {args.cycles} loaded/retired players, no retained views or playback errors")
        print('PASS: first progress starts at the requested position, including paused/deferred loads')
    except Exception:
        log = work / 'build.log'
        if log.exists():
            print(log.read_text()[-4000:])
        raise
    finally:
        subprocess.run(['xcrun', 'simctl', 'terminate', simulator, BUNDLE], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'uninstall', simulator, BUNDLE], capture_output=True)


if __name__ == '__main__':
    main()
