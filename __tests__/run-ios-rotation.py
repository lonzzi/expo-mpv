#!/usr/bin/env python3
"""Check real Metal playback through playing/paused UIKit rotations.

Requires Xcode, ffmpeg, NumPy, Pillow, downloaded MPVKit frameworks and a booted
simulator. Only the Expo bridge is stubbed; artifacts stay outside the repository.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'expo.modules.mpv.rotation-regression'
spec = importlib.util.spec_from_file_location('lifecycle', ROOT / '__tests__/run-ios-lifecycle.py')
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
command = lifecycle.command


def fixture(work, app):
    width, height = 640, 360
    y, x = np.indices((height, width))
    pixels = np.full((height, width, 3), (24, 24, 32), dtype=np.uint8)
    pixels[(x % 64 == 0) | (y % 60 == 0)] = (110, 110, 110)
    pixels[(x - 320) ** 2 + (y - 180) ** 2 <= 72 ** 2] = (0, 255, 0)
    Image.fromarray(pixels).save(work / 'circle.png')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-loop', '1', '-i',
                    str(work / 'circle.png'), '-t', '12', '-r', '60', '-c:v',
                    'libx264', '-preset', 'ultrafast', '-crf', '18', '-pix_fmt',
                    'yuv420p', str(app / 'fixture.mp4')], check=True)


def analyze(directory):
    width, height = 402, 874
    process = subprocess.Popen([
        'ffmpeg', '-v', 'error', '-i', str(directory / 'rotation.mp4'), '-vf',
        f'scale={width}:{height}:force_original_aspect_ratio=decrease,'
        f'pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=60',
        '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], stdout=subprocess.PIPE)
    samples, clipped, index, started = [], 0, 0, False
    try:
        while data := process.stdout.read(width * height * 3):
            frame = np.frombuffer(data, dtype=np.uint8).reshape(height, width, 3)
            mask = (frame[:, :, 1] > 150) & (frame[:, :, 0] < 65) & (frame[:, :, 2] < 65)
            y, x = np.where(mask)
            if len(x) > 250:
                interior = mask.copy()
                for axis in (0, 1):
                    for delta in (-1, 1):
                        interior &= np.roll(mask, delta, axis)
                edge = mask & ~interior
                black = frame.max(axis=2) < 12
                nearby = black.copy()
                for axis in (0, 1):
                    for delta in (-1, 1):
                        nearby |= np.roll(black, delta, axis)
                cropped = (x.min() <= 1 or x.max() >= width - 2 or y.min() <= 1 or
                           y.max() >= height - 2 or np.count_nonzero(edge & nearby) > 3)
                covariance = np.cov(np.stack([x, y]), bias=True)
                eigenvalues = np.linalg.eigvalsh(covariance)
                ratio = float(np.sqrt(eigenvalues[1] / eigenvalues[0]))
                by, bx = np.where(edge)
                boundary = np.stack([bx - x.mean(), by - y.mean()], axis=1)
                radial = np.sqrt(np.einsum('ij,jk,ik->i', boundary,
                                          np.linalg.inv(covariance) / 4, boundary))
                # A clipped cap has a straight edge and is not an entire ellipse.
                # Its aspect ratio is meaningless. Count these frames separately.
                cropped |= np.percentile(np.abs(radial - 1), 95) > 0.08
                if cropped:
                    clipped += 1
                else:
                    # Exclude launch animation before the first fully drawn frame.
                    started |= ratio < 1.05
                    if started:
                        samples.append({'frame': index, 'seconds': index / 60, 'ratio': ratio})
            index += 1
        assert process.wait() == 0
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    result = {'frames': index, 'clippedFrames': clipped, 'samples': samples,
              'maxRatio': max((sample['ratio'] for sample in samples), default=0)}
    (directory / 'pixels.json').write_text(json.dumps(result, indent=2) + '\n')
    assert len(samples) > 200, 'Insufficient fully visible video frames'
    assert result['maxRatio'] < 1.08, result['maxRatio']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', default=os.environ.get('SIMULATOR_UDID'))
    parser.add_argument('--module', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    devices = json.loads(command('xcrun', 'simctl', 'list', 'devices', 'booted', '-j'))['devices']
    booted = [device['udid'] for runtime, group in devices.items() if 'iOS' in runtime
              for device in group if device['state'] == 'Booted']
    simulator = args.simulator or next(iter(booted), None)
    if simulator not in booted:
        parser.error('Select a booted iOS simulator with --simulator or SIMULATOR_UDID')
    work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='expo-mpv-rotation-'))
    work.mkdir(parents=True, exist_ok=True)
    (work / 'source.json').write_text(json.dumps({
        'sha256': hashlib.sha256((args.module / 'ios/ExpoMpvView.swift').read_bytes()).hexdigest(),
        'simulator': simulator,
    }, indent=2) + '\n')
    print(f'Artifacts: {work}', flush=True)
    recording = None
    try:
        app = lifecycle.build(work, args.module, ROOT / '__tests__/ios-rotation/App.swift', BUNDLE)
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        info['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        fixture(work, app)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        command('xcrun', 'simctl', 'install', simulator, str(app))
        container = Path(command('xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'))
        result = container / 'Documents/rotation.json'
        result.unlink(missing_ok=True)
        with (work / 'record.log').open('w') as log:
            recording = subprocess.Popen(['xcrun', 'simctl', 'io', simulator, 'recordVideo',
                '--codec=h264', '--force', str(work / 'rotation.mp4')], stdout=log, stderr=log)
            time.sleep(0.5)
            command('xcrun', 'simctl', 'launch', simulator, BUNDLE)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not result.exists():
                time.sleep(0.25)
            assert result.exists(), 'Native rotation did not finish'
            metrics = json.loads(result.read_text())
            (work / 'rotation.json').write_text(json.dumps(metrics, indent=2) + '\n')
            recording.send_signal(signal.SIGINT)
            recording.wait(timeout=20)
            recording = None
        assert metrics['loads'] == 1 and not metrics['errors'], metrics
        assert sum(event['kind'] == 'end' for event in metrics['events']) == 4, metrics['events']
        assert all(sample['gravity'] == 'resizeAspect' for sample in metrics['samples'])
        pixels = analyze(work)
        print(f"PASS: 4 playing/paused rotations, one load, {len(pixels['samples'])} full circle frames; "
              f"maximum aspect error {(pixels['maxRatio'] - 1) * 100:.2f}%")
    finally:
        if recording is not None and recording.poll() is None:
            recording.send_signal(signal.SIGINT)
            recording.wait(timeout=20)
        subprocess.run(['xcrun', 'simctl', 'terminate', simulator, BUNDLE], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'uninstall', simulator, BUNDLE], capture_output=True)


if __name__ == '__main__':
    main()
