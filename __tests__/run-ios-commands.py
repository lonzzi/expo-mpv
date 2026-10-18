#!/usr/bin/env python3
"""Exercise the actual ExpoMpvView on Simulator with deterministic slow HTTP tracks.

Only the Expo base view/event bridge is stubbed; UIKit, libmpv, rendering, network,
track commands, and the production Swift view/lifecycle code are real.
Requires a booted iOS Simulator, downloaded iOS frameworks, Xcode, and ffmpeg.
"""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import os
import plistlib
import struct
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'expo.modules.mpv.command-regression'
SCENARIOS = ['subtitle', 'pgs', 'audio', 'reload', 'replace', 'back', 'destroy', 'error']
SUBTITLE = b'1\n00:00:00,000 --> 00:00:19,000\nExternal subtitle loaded\n'


def pgs_subtitle():
    """Generate empty PGS display sets with an original, nonzero timeline."""
    def packet(pts, kind, payload):
        return b'PG' + struct.pack('>IIBH', pts, 0, kind, len(payload)) + payload
    return b''.join(packet(second * 90000, 0x16,
                          struct.pack('>HHBHBBBB', 1920, 1080, 0x10, second, 0x80, 0, 0, 0)) +
                    packet(second * 90000, 0x80, b'') for second in range(1, 20))


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def build(work):
    sdk = command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    env = {**os.environ, 'SDKROOT': sdk}
    base = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-sdk', sdk, '-target',
            'arm64-apple-ios17.5-simulator', '-swift-version', '5', '-g', '-Onone']
    sources = ROOT / '__tests__/ios-commands'
    app = work / 'CommandRegression.app'
    app.mkdir()
    with (work / 'build.log').open('w') as log:
        subprocess.run(base + ['-emit-library', '-static', '-emit-module', '-module-name',
            'ExpoModulesCore', str(sources / 'ExpoModulesCore.swift'), '-emit-module-path',
            str(work / 'ExpoModulesCore.swiftmodule'), '-o', str(work / 'libExpoModulesCore.a')],
            check=True, env=env, stdout=log, stderr=log)
        args = base + ['-module-name', 'CommandRegression', '-I', str(work),
                      str(sources / 'App.swift'), str(ROOT / 'ios/ExpoMpvView.swift')]
        args.append(str(work / 'libExpoModulesCore.a'))
        for framework in (ROOT / 'ios/Frameworks').glob('*.xcframework'):
            info = plistlib.loads((framework / 'Info.plist').read_bytes())
            lib = next((entry for entry in info['AvailableLibraries']
                if entry.get('SupportedPlatform') == 'ios'
                and entry.get('SupportedPlatformVariant') == 'simulator'
                and 'arm64' in entry['SupportedArchitectures']), None)
            if not lib:
                continue
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
                 '-o', str(app / 'CommandRegression')]
        subprocess.run(args, check=True, env=env, stdout=log, stderr=log)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE, 'CFBundleExecutable': 'CommandRegression',
        'CFBundleName': 'MPV Command Regression', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.5',
        'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    }))
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
        'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
        '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30', '-c:a', 'aac',
        '-movflags', '+faststart', str(app / 'fixture.mp4')], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    return app


def serve():
    audio = io.BytesIO()
    with wave.open(audio, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(8000)
        out.writeframes(b''.join(struct.pack('<h', int(4000 * math.sin(i * 2 * math.pi * 330 / 8000)))
                                for i in range(8000 * 20)))
    counts = {}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == '/missing.srt':
                self.send_error(404)
                return
            with lock:
                counts[self.path] = counts.get(self.path, 0) + 1
                count = counts[self.path]
            if path in ['/slow.srt', '/slow.sup'] or path == '/slow.wav' and count == 1 or path == '/reload.srt' and count > 1:
                time.sleep(4)
            body = (audio.getvalue() if path.endswith('.wav') else
                    pgs_subtitle() if path.endswith('.sup') else SUBTITLE)
            start, end = 0, len(body) - 1
            ranged = self.headers.get('Range', '').startswith('bytes=')
            if ranged:
                a, b = self.headers['Range'][6:].split('-')
                start, end = int(a or 0), min(int(b), end) if b else end
            if start > end:
                self.send_error(416)
                return
            self.send_response(206 if ranged else 200)
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Accept-Ranges', 'bytes')
            if ranged:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
            self.end_headers()
            try:
                self.wfile.write(body[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass  # Expected when a view aborts an in-flight track request.

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def validate(data):
    assert not data.get('preparationFailed'), 'Initial subtitle was not loaded'
    assert data['commandReturnSeconds'] < 0.35, 'Track command blocked its caller'
    assert data['maxMainThreadGapSeconds'] < 0.35, 'UI main queue stalled'
    events = {entry['event']: entry for entry in data['events']}
    assert data['completionCount'] == 1, 'Completion was lost or called more than once'
    assert events['pause-handler']['elapsed'] < 0.6, 'Pause input was delayed'
    assert events['pause-return']['elapsed'] < 0.6 and data['paused'], 'Pause failed'
    errors = [entry for entry in data['events'] if entry['event'] == 'error']
    mode = data['scenario']
    completion = events['load-completion']['elapsed']
    if mode in ['subtitle', 'pgs', 'audio', 'reload']:
        assert 3.9 <= completion < 5.5, 'Awaiters must wait for the real command result'
    else:
        assert completion < 1.1, 'Cancellation or failure left an awaiting caller pending'
    if mode == 'error':
        assert len(errors) == 1 and errors[0]['data']['error'].startswith("Command 'sub-add' failed:"), errors
    else:
        assert not errors, errors
    if mode in ['back', 'destroy']:
        assert events['back-return']['elapsed'] < 1.05, 'Leaving the player was delayed'
        assert events['back-return']['elapsed'] - events['back-handler']['elapsed'] < 0.35
        assert data['viewReleased'], 'In-flight requests retained the detached native view'
        return
    assert data['playback']['duration'] == 20
    assert data['playback']['speed'] == 1.25 and data['playback']['volume'] == 55
    assert data['muted'] and not data['playback']['muted']
    external = [track for track in data['tracks'] if track['isExternal']]
    if mode == 'replace':
        assert events['replace-return']['elapsed'] < 1.05, 'Source replacement was delayed'
        assert not external, 'Old request attached a track to the replacement source'
        assert len([event for event in data['events'] if event['event'] == 'loaded']) >= 2
    else:
        assert data['resumed'] and events['resume-return']['elapsed'] < 0.85
        assert events['seek-return']['elapsed'] < 1.1 and 7.5 <= data['seekPosition'] < 10
        if mode != 'error':
            assert len(external) == 1, external
            assert external[0]['type'] == ('audio' if mode == 'audio' else 'sub')
            if mode == 'pgs':
                assert external[0]['codec'] == 'hdmv_pgs_subtitle', external
            assert data['selectedExternalID'] == external[0]['id']
            assert not any(track['isExternal'] for track in data['tracksAfterRemoval'])
            if mode != 'audio':
                assert data['subtitleOffID'] == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', help='Booted Simulator UDID (defaults to first booted iOS device)')
    parser.add_argument('--output', type=Path, help='Keep build logs and per-scenario JSON in this new directory')
    parser.add_argument('--scenarios', nargs='+', choices=SCENARIOS, default=SCENARIOS)
    args = parser.parse_args()
    devices = json.loads(command('xcrun', 'simctl', 'list', 'devices', 'booted', '--json'))['devices']
    simulator = args.simulator or next(device['udid'] for runtime, group in devices.items()
        if 'iOS' in runtime for device in group if device['state'] == 'Booted')
    temporary = tempfile.TemporaryDirectory(prefix='expo-mpv-command-regression-')
    work = args.output.resolve() if args.output else Path(temporary.name)
    work.mkdir(parents=True, exist_ok=True)
    server = None
    try:
        app = build(work)
        command('xcrun', 'simctl', 'install', simulator, str(app))
        container = Path(command('xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'))
        server = serve()
        for mode in args.scenarios:
            subprocess.run(['xcrun', 'simctl', 'terminate', simulator, BUNDLE], capture_output=True)
            result = container / 'Documents' / (mode + '.json')
            result.unlink(missing_ok=True)
            command('xcrun', 'simctl', 'launch', simulator, BUNDLE, '--scenario', mode,
                    '--port', str(server.server_port), '--run', str(uuid.uuid4()))
            deadline = time.monotonic() + 16
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert result.exists(), f'{mode}: no result (startup failure, crash, or stalled UI)'
            data = json.loads(result.read_text())
            (work / (mode + '.json')).write_text(json.dumps(data, indent=2) + '\n')
            validate(data)
            print(f"PASS {mode}: command={data['commandReturnSeconds']:.3f}s, max UI gap={data['maxMainThreadGapSeconds']:.3f}s", flush=True)
        source = ROOT / 'ios/ExpoMpvView.swift'
        (work / 'source.json').write_text(json.dumps({'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'simulator': simulator, 'scenarios': args.scenarios}, indent=2) + '\n')
    except Exception:
        log = work / 'build.log'
        if log.exists():
            print(log.read_text()[-4000:])
        raise
    finally:
        if server:
            server.shutdown()
            server.server_close()
        subprocess.run(['xcrun', 'simctl', 'terminate', simulator, BUNDLE], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'uninstall', simulator, BUNDLE], capture_output=True)
        temporary.cleanup()


if __name__ == '__main__':
    main()
