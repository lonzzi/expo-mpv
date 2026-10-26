#!/usr/bin/env python3
"""Exercise the installed expo-mpv Android view through real Activity/Surface cycles.

Requires adb, ffmpeg, and a running Metro server for an Expo development host
containing expo-mpv, expo-splash-screen and expo-screen-orientation. The host must
already be compiled with the native module under test. Generated entry files are removed on exit;
all media, screenshots, logs and results stay in --output or a temporary folder.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle-id', default='com.lonzzi.nekofin.dev')
    parser.add_argument('--scheme', default='exp+nekofin')
    parser.add_argument('--adb-port', type=int, default=5037)
    parser.add_argument('--metro-port', type=int, default=8081)
    parser.add_argument('--port', type=int, default=8770)
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--seconds', type=float, default=15)
    parser.add_argument('--hwdec', default='no')
    parser.add_argument('--rotation', action='store_true', help='Test playing/paused rotations instead of background cycles')
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.cycles < 1 or args.seconds < 0:
        parser.error('cycles must be positive and seconds must be nonnegative')
    work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='mpv-background-'))
    work.mkdir(parents=True, exist_ok=True)
    adb = ['adb', '-P', str(args.adb_port), '-s', args.device]

    def command(*parts, binary=False):
        result = subprocess.check_output([str(part) for part in parts], text=not binary)
        return result if binary else result.strip()

    def device(*parts, binary=False):
        return command(*adb, *parts, binary=binary)

    request = urllib.request.Request(f'http://127.0.0.1:{args.metro_port}/', headers={
        'expo-platform': 'android', 'accept': 'application/expo+json',
    })
    manifest = json.load(urllib.request.urlopen(request, timeout=30))
    test_id = uuid.uuid4().hex[:12]
    entry_name = f'.expo/expo-mpv-background-{test_id}'
    entry = args.project.resolve() / f'{entry_name}.tsx'
    if entry.exists():
        raise RuntimeError(f'Refusing to overwrite {entry}')
    fixture_name = f'expo-mpv-background-{test_id}.mp4'
    source = f'/data/user/0/{args.bundle_id}/files/{fixture_name}'
    endpoint = f'http://127.0.0.1:{args.port}'
    manifest['id'] = str(uuid.uuid4())
    manifest['launchAsset']['url'] = f'{endpoint}/{entry_name}.bundle?platform=android&dev=true&hot=false'
    manifest['extra']['expoClient']['hostUri'] = f'127.0.0.1:{args.port}'
    manifest['extra']['expoGo'].update({
        'debuggerHost': f'127.0.0.1:{args.port}', 'mainModuleName': entry_name,
    })
    events = []
    lock = threading.Lock()
    control = {'paused': False, 'orientation': 'portrait' if args.rotation else None}
    log = (work / 'events.jsonl').open('w')

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ('/', '/control'):
                data = json.dumps(manifest if self.path == '/' else control).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/expo+json' if self.path == '/' else 'application/json')
                self.send_header('expo-protocol-version', '0')
                self.end_headers()
                self.wfile.write(data)
                return
            path = self.path
            for original in ('/index.bundle', '/.expo/.virtual-metro-entry.bundle', '/node_modules/expo-router/entry.bundle'):
                if path.startswith(original + '?') or path == original:
                    path = path.replace(original, f'/{entry_name}.bundle', 1)
                    break
            try:
                response = urllib.request.urlopen(f'http://127.0.0.1:{args.metro_port}{path}', timeout=120)
                data = response.read()
                self.send_response(response.status)
                self.send_header('Content-Type', response.headers.get('Content-Type', 'text/plain'))
                self.end_headers()
                self.wfile.write(data)
            except (urllib.error.URLError, BrokenPipeError, ConnectionResetError) as error:
                if not isinstance(error, (BrokenPipeError, ConnectionResetError)):
                    self.send_error(502, str(error))

        def do_POST(self):
            event = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            with lock:
                events.append(event)
                log.write(json.dumps(event) + '\n')
                log.flush()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')

        def log_message(self, *parts):
            pass

    def snapshot():
        with lock:
            return list(events)

    def wait(predicate, label, after=0, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for event in reversed(snapshot()[after:]):
                if predicate(event):
                    return event
            time.sleep(.1)
        raise AssertionError(f'Timed out: {label}; last events={snapshot()[-3:]}')

    def telemetry(predicate, label, after=0, timeout=30):
        return wait(lambda event: event['event'] == 'telemetry' and predicate(event['data']), label, after, timeout)['data']

    def foreground(after):
        device('shell', 'am', 'start', '-W', '-n', f'{args.bundle_id}/.MainActivity')
        wait(lambda event: event['event'] == 'appState' and event['data'] == 'active', 'foreground', after)
        assert device('shell', 'pidof', args.bundle_id) == pid, 'The process was recreated'

    def frame(name):
        path = work / f'{name}.png'
        path.write_bytes(device('exec-out', 'screencap', '-p', binary=True))
        pixels = command('ffmpeg', '-v', 'error', '-i', path, '-vf',
                         'crop=iw*0.6:ih*0.2:iw*0.2:ih*0.4,scale=32:32',
                         '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-', binary=True)
        assert statistics.pstdev(pixels) > 30, f'Video area is blank: {path}'
        return pixels

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f'Artifacts: {work}', flush=True)
    provenance = {
        'device': args.device,
        'nativeAsset': json.loads((ROOT / 'native/android-ass.json').read_text()),
        'workingTreeSources': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (ROOT / 'android/src/main/java/expo/modules/mpv').glob('*.kt')},
    }
    if args.apk:
        provenance['apkSha256'] = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    (work / 'source.json').write_text(json.dumps(provenance, indent=2) + '\n')
    try:
        fixture = work / 'fixture.mp4'
        if args.rotation:
            pixels = bytearray()
            for y in range(360):
                for x in range(640):
                    pixels.extend((0, 255, 0) if (x - 320) ** 2 + (y - 180) ** 2 <= 72 ** 2
                                  else ((110, 110, 110) if x % 64 == 0 or y % 60 == 0 else (24, 24, 32)))
            pattern = work / 'circle.ppm'
            pattern.write_bytes(b'P6\n640 360\n255\n' + pixels)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-loop', '1', '-i', str(pattern),
                            '-t', '60', '-r', '60', '-c:v', 'libx264', '-preset', 'ultrafast',
                            '-crf', '18', '-pix_fmt', 'yuv420p', str(fixture)], check=True)
        else:
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
                        '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000', '-t', '60',
                        '-vf', 'hue=h=12*t', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30',
                        '-c:a', 'aac', '-movflags', '+faststart', str(fixture)], check=True)
        if args.apk:
            device('install', '-r', args.apk.resolve())
        remote = f'/data/local/tmp/{fixture_name}'
        device('push', fixture, remote)
        device('shell', 'run-as', args.bundle_id, 'mkdir', '-p', 'files')
        device('shell', 'run-as', args.bundle_id, 'cp', remote, f'files/{fixture_name}')
        device('shell', 'rm', remote)
        source_text = (ROOT / '__tests__/android-background/App.tsx').read_text()
        config = {'endpoint': endpoint, 'source': source, 'hwdec': args.hwdec}
        entry.parent.mkdir(exist_ok=True)
        entry.write_text(source_text.replace("'__CONFIG_JSON__'", json.dumps(json.dumps(config))))
        device('reverse', f'tcp:{args.port}', f'tcp:{args.port}')
        device('shell', 'am', 'force-stop', args.bundle_id)
        url = f'{args.scheme}://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A{args.port}'
        device('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', url,
               '-n', f'{args.bundle_id}/.MainActivity')
        wait(lambda event: event['event'] == 'load', 'fixture load', timeout=120)
        telemetry(lambda data: data.get('playback', {}).get('position', 0) > 5, 'initial playback')
        pid = device('shell', 'pidof', args.bundle_id)
        frame('initial')
        results = []
        if args.rotation:
            import numpy as np
            from PIL import Image
            paused_position = None
            for index, orientation in enumerate(['landscape', 'portrait', 'landscape', 'portrait']):
                mark = len(snapshot())
                control.update(paused=index >= 2, orientation=orientation)
                layout = wait(lambda event: event['event'] == 'layout' and
                              ((event['data']['width'] > event['data']['height']) == (orientation == 'landscape')),
                              'rotated viewport', mark)
                current = telemetry(lambda data: data.get('playback', {}).get('isPlaying') == (index < 2),
                          'rotation playback state', mark)
                if index == 2:
                    paused_position = current['playback']['position']
                if index == 3:
                    assert abs(current['playback']['position'] - paused_position) < .5, current
                time.sleep(1)
                path = work / f'rotation-{index}.png'
                path.write_bytes(device('exec-out', 'screencap', '-p', binary=True))
                image = np.array(Image.open(path).convert('RGB'))
                y, x = np.where((image[:, :, 1] > 150) & (image[:, :, 0] < 65) & (image[:, :, 2] < 65))
                assert len(x) > 1000, f'Video circle missing after rotation: {path}'
                eigenvalues = np.linalg.eigvalsh(np.cov(np.stack([x, y]), bias=True))
                ratio = float(np.sqrt(eigenvalues[1] / eigenvalues[0]))
                assert ratio < 1.08, f'Video stretched after rotation: {ratio}, {path}'
                height, width = image.shape[:2]
                assert abs(x.mean() / width - .5) < .05 and abs(y.mean() / height - .5) < .05, path
                results.append({'orientation': orientation, 'paused': index >= 2,
                                'layout': layout['data'], 'aspectRatio': ratio})
            loads = [event for event in snapshot() if event['event'] == 'load']
            errors = [event for event in snapshot() if event['event'] == 'error']
            assert len(loads) == 1 and not errors, (loads, errors)
            assert device('shell', 'pidof', args.bundle_id) == pid, 'Process recreated during rotation'
            native_log = device('logcat', '-d', f'--pid={pid}')
            assert not re.search(r'Missing surface pointer|Error opening/initializing.*VO|EGL_BAD_SURFACE', native_log), 'Native surface error'
            (work / 'result.json').write_text(json.dumps({'passed': True, 'rotations': results,
                                                       'sourceLoadCount': len(loads)}, indent=2) + '\n')
            print('PASS: four playing/paused rotations; centered, proportional video, one source load', flush=True)
            return
        for cycle in range(args.cycles):
            mark = len(snapshot())
            control['paused'] = True
            before = telemetry(lambda data: not data.get('playback', {}).get('isPlaying', True), 'native pause', mark)
            position = before['playback']['position']
            mark = len(snapshot())
            device('shell', 'input', 'keyevent', '3')
            wait(lambda event: event['event'] == 'appState' and event['data'] == 'background', 'background', mark)
            time.sleep(args.seconds)
            mark = len(snapshot())
            foreground(mark)
            restored = telemetry(lambda data: data.get('appState') == 'active'
                                 and data.get('tracks', {}).get('vid', 0) > 0
                                 and data.get('media', {}).get('width', 0) == 640
                                 and not data.get('playback', {}).get('isPlaying', True), 'paused video restored', mark)
            assert abs(restored['playback']['position'] - position) < .5, (before, restored)
            control['paused'] = False
            telemetry(lambda data: data.get('playback', {}).get('isPlaying')
                      and data['playback']['position'] > position + .5, 'resumed progress', mark)
            first = frame(f'cycle-{cycle + 1}-a')
            time.sleep(1)
            second = frame(f'cycle-{cycle + 1}-b')
            assert sum(abs(a - b) for a, b in zip(first, second)) / len(first) > 1, 'Video frame is frozen'
            results.append({'cycle': cycle + 1, 'positionBefore': position,
                            'positionAfter': restored['playback']['position']})
            print(f'PASS: paused background cycle {cycle + 1}/{args.cycles}, video restored and moving', flush=True)
        mark = len(snapshot())
        device('shell', 'input', 'keyevent', '3')
        wait(lambda event: event['event'] == 'appState' and event['data'] == 'background', 'playing background', mark)
        time.sleep(min(args.seconds, 15))
        mark = len(snapshot())
        foreground(mark)
        telemetry(lambda data: data.get('tracks', {}).get('vid', 0) > 0
                  and data.get('playback', {}).get('isPlaying'), 'playing video restored', mark)
        frame('playing-return')
        loads = [event for event in snapshot() if event['event'] == 'load']
        errors = [event for event in snapshot() if event['event'] == 'error']
        assert len(loads) == 1 and not errors, (loads, errors)
        native_log = device('logcat', '-d', f'--pid={pid}')
        (work / 'native.log').write_text(native_log)
        assert not re.search(r'Missing surface pointer|Error opening/initializing.*VO|EGL_BAD_SURFACE', native_log), 'Native surface error'
        result = {'passed': True, 'pid': pid, 'hwdec': args.hwdec, 'cycles': results,
                  'playingBackground': True, 'sourceLoadCount': len(loads)}
        (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('PASS: playing background, unchanged process/source, no native Surface errors', flush=True)
    finally:
        try:
            (work / 'events-final.json').write_text(json.dumps(snapshot(), indent=2) + '\n')
            running_pid = subprocess.run(adb + ['shell', 'pidof', args.bundle_id],
                                         capture_output=True, text=True).stdout.strip()
            if running_pid:
                (work / 'native.log').write_text(device('logcat', '-d', f'--pid={running_pid}'))
            device('shell', 'am', 'force-stop', args.bundle_id)
            device('reverse', '--remove', f'tcp:{args.port}')
            device('shell', 'run-as', args.bundle_id, 'rm', '-f', f'files/{fixture_name}')
        finally:
            entry.unlink(missing_ok=True)
            server.shutdown()
            log.close()


if __name__ == '__main__':
    main()
