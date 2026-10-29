#!/usr/bin/env python3
"""Prepare or verify real iOS background audio and Now Playing regression.

After --prepare, use Simulator controls to go Home and reopen the app a few
times, then run --verify against the same output folder. Requires a booted
simulator; this runner does not start or control the user's Simulator UI.
Artwork fixtures require ffmpeg and cwebp. To test HTTP loading, launch with
EXPO_MPV_ARTWORK_BASE_URL pointing to a local server serving the app's fixtures.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'expo.modules.mpv.media-session-regression'
spec = importlib.util.spec_from_file_location('lifecycle', ROOT / '__tests__/run-ios-lifecycle.py')
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--output', type=Path, required=True)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--prepare', action='store_true')
    action.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    work = args.output.resolve()
    work.mkdir(parents=True, exist_ok=True)
    command = lifecycle.command
    if args.prepare:
        app = lifecycle.build(work, ROOT, ROOT / '__tests__/ios-media-session/App.swift', BUNDLE)
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        info['UIBackgroundModes'] = ['audio']
        info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        for name, size in [('artwork', '1200x600'), ('artwork-next', '600x1200')]:
            png = work / f'{name}.png'
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
                            f'testsrc2=size={size}', '-frames:v', '1', str(png)], check=True)
            subprocess.run(['cwebp', '-quiet', str(png), '-o', str(app / f'{name}.webp')], check=True)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
                        '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000', '-t', '120', '-c:v',
                        'libx264', '-preset', 'ultrafast', '-crf', '30', '-c:a', 'aac', str(app / 'fixture.mp4')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        command('xcrun', 'simctl', 'install', args.simulator, str(app))
        command('xcrun', 'simctl', 'launch', args.simulator, BUNDLE)
        print(f'Prepared {BUNDLE}; use Home and reopen it before --verify. Artifacts: {work}')
        return
    container = Path(command('xcrun', 'simctl', 'get_app_container', args.simulator, BUNDLE, 'data'))
    deadline = time.monotonic() + 5
    while True:
        data = json.loads((container / 'Documents/media-session.json').read_text())
        if data.get('samples') and data['samples'][-1]['state'] == 0:
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(.25)
    (work / 'media-session.json').write_text(json.dumps(data, indent=2) + '\n')
    assert data['loads'] == 1 and not data['errors'] and data['interruptionChecked'] and data['artworkChecked'], data
    samples = data['samples']
    runs = []
    for sample in samples:
        if sample['state'] != 2:
            continue
        if not runs or sample['time'] - runs[-1][-1]['time'] > 1:
            runs.append([])
        runs[-1].append(sample)
    runs = [run for run in runs if run[-1]['time'] - run[0]['time'] >= 2]
    assert runs, 'No real background audio samples (go Home for at least three seconds)'
    for run in runs:
        # The fixture loops; a background run may cross the end of its timeline.
        advanced = sum(max(0, b['position'] - a['position']) for a, b in zip(run, run[1:]))
        assert advanced > 1, run
        assert all(sample['playing'] and sample['title'] == 'Background episode' and sample['rate'] == 1 for sample in run), run
        assert all(sample['audioOptions'] & 1 == 0 for sample in run), 'Background media owner uses a mixing audio session'
    last = samples[-1]
    assert last['state'] == 0 and last['playing'] and last['title'] == 'Background episode', last
    result = {'passed': True, 'backgroundRuns': len(runs), 'singleSourceLoad': data['loads'],
              'syntheticInterruptionResume': data['interruptionChecked'],
              'artworkLoadedResizedAndReplaced': data['artworkChecked'], 'last': last}
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
