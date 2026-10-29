#!/usr/bin/env python3
"""Build production mpv sources into an isolated Android media-session probe.

Requires a booted adb device, the example Gradle wrapper, and native libraries
already built by the example host. All generated files stay outside the repo.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'expo.modules.mpv.mediaregression'
ACTIVITY = f'{PACKAGE}/expo.modules.mpv.ProbeActivity'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--adb-port', type=int, default=5037)
    parser.add_argument('--cycles', type=int, default=5)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='mpv-media-android-'))
    work.mkdir(parents=True, exist_ok=True)
    project = work / 'project'
    project.mkdir(exist_ok=True)
    print(f'Artifacts: {work}', flush=True)
    adb = ['adb', '-P', str(args.adb_port), '-s', args.device]

    def command(*parts, binary=False):
        return subprocess.check_output([str(part) for part in parts], text=not binary).strip()

    def device(*parts, binary=False):
        return command(*adb, *parts, binary=binary)

    def state():
        try:
            return json.loads(device('exec-out', 'run-as', PACKAGE, 'cat', 'files/state.json'))
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            return {}

    def wait(predicate, label, timeout=20):
        deadline = time.monotonic() + timeout
        latest = {}
        while time.monotonic() < deadline:
            latest = state()
            if predicate(latest):
                assert not latest.get('errors'), latest
                return latest
            time.sleep(.2)
        raise AssertionError(f'{label}: {latest}')

    wrapper = ROOT / 'example/android'
    shutil.copytree(wrapper / 'gradle', project / 'gradle', dirs_exist_ok=True)
    shutil.copy2(wrapper / 'gradlew', project / 'gradlew')
    sources = project / 'src/main/java/expo/modules/mpv'
    sources.mkdir(parents=True, exist_ok=True)
    production = ROOT / 'android/src/main/java/expo/modules/mpv'
    source_hashes = {}
    for name in ['MPVLib.kt', 'MpvPlayer.kt', 'ExpoMpvPlaybackService.kt']:
        shutil.copy2(production / name, sources / name)
        source_hashes[name] = hashlib.sha256((sources / name).read_bytes()).hexdigest()
    shutil.copy2(ROOT / '__tests__/android-media-session/ProbeActivity.kt', sources / 'ProbeActivity.kt')
    (work / 'source.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
    (project / 'settings.gradle').write_text('''pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = 'MpvMediaRegression'
''')
    libs = ROOT / 'android/build/intermediates/library_jni/debug/copyDebugJniLibsProjectOnly/jni'
    if not (libs / 'arm64-v8a/libexpo-mpv-jni.so').exists():
        raise RuntimeError('Build the example Android host first to generate production JNI libraries')
    (project / 'build.gradle').write_text(f'''plugins {{ id 'com.android.application' version '8.12.0'; id 'org.jetbrains.kotlin.android' version '2.1.20' }}
android {{
    namespace '{PACKAGE}'
    compileSdk 36
    compileOptions {{ sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }}
    kotlinOptions {{ jvmTarget = '17' }}
    defaultConfig {{ applicationId '{PACKAGE}'; minSdk 24; targetSdk 36; versionCode 1; versionName '1.0' }}
    sourceSets.main.jniLibs.srcDirs = ['{libs}']
}}
''')
    sdk = os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))
    (project / 'local.properties').write_text(f'sdk.dir={sdk}\n')
    (project / 'src/main/AndroidManifest.xml').write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<application android:label="MPV Media Regression" android:theme="@android:style/Theme.Material.NoActionBar">
<activity android:name="expo.modules.mpv.ProbeActivity" android:exported="true" android:configChanges="orientation|screenSize">
<intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
</activity>
<service android:name="expo.modules.mpv.ExpoMpvPlaybackService" android:exported="false" android:foregroundServiceType="mediaPlayback"/>
</application></manifest>''')
    with (work / 'build.log').open('w') as log:
        subprocess.run([str(project / 'gradlew'), 'assembleDebug', '--console=plain'], cwd=project,
                       stdout=log, stderr=log, check=True)
    apk, = (project / 'build/outputs/apk/debug').glob('*.apk')
    device('install', '-r', apk)
    fixture = work / 'fixture.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
                    '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000', '-t', '30', '-c:v',
                    'libx264', '-preset', 'ultrafast', '-crf', '30', '-c:a', 'aac', str(fixture)], check=True)
    device('push', fixture, '/data/local/tmp/mpv-media-fixture.mp4')
    device('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files')
    device('shell', 'run-as', PACKAGE, 'cp', '/data/local/tmp/mpv-media-fixture.mp4', 'files/fixture.mp4')
    device('shell', 'am', 'force-stop', PACKAGE)
    device('shell', 'am', 'start', '-W', '-n', ACTIVITY)
    wait(lambda data: data.get('loads') == 1 and data.get('playing') and data.get('position', 0) > 2200, 'initial load')
    pid = device('shell', 'pidof', PACKAGE)

    def session():
        dump = device('shell', 'dumpsys', 'media_session')
        assert PACKAGE in dump and 'ExpoMpv' in dump, dump
        services = device('shell', 'dumpsys', 'activity', 'services', PACKAGE)
        assert 'isForeground=true' in services, services
        return dump

    def remote(key):
        device('shell', 'cmd', 'media_session', 'dispatch', key)

    def control(key):
        device('shell', 'am', 'broadcast', '-a', 'expo.modules.mpv.TEST_CONTROL', '--es', 'command', key, '-p', PACKAGE)

    session()
    results = []
    for index in range(args.cycles):
        device('shell', 'input', 'keyevent', '3')
        before = wait(lambda data: not data.get('foreground', True), 'background')
        time.sleep(2)
        advanced = wait(lambda data: data.get('position', 0) > before['position'] + 1000, 'background audio advances')
        session()
        remote('pause')
        paused = wait(lambda data: not data.get('playing', True), 'native remote pause')
        time.sleep(1)
        assert abs(state()['position'] - paused['position']) < 200, state()
        remote('play')
        wait(lambda data: data.get('playing') and data.get('position', 0) > paused['position'] + 400, 'native remote play')
        device('shell', 'am', 'start', '-W', '-n', ACTIVITY)
        wait(lambda data: data.get('foreground') and data.get('playing'), 'foreground resume')
        time.sleep(.5)
        screenshot = work / f'foreground-{index}.png'
        screenshot.write_bytes(device('exec-out', 'screencap', '-p', binary=True))
        pixels = command('ffmpeg', '-v', 'error', '-i', screenshot, '-vf',
                         'crop=iw*0.6:ih*0.2:iw*0.2:ih*0.4,scale=32:32', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-', binary=True)
        assert statistics.pstdev(pixels) > 30, f'Blank video: {screenshot}'
        assert device('shell', 'pidof', PACKAGE) == pid, 'Process recreated'
        results.append({'cycle': index, 'backgroundPosition': advanced['position'], 'remotePause': paused['position']})
    control('replace')
    wait(lambda data: data.get('loads') == 2 and data.get('position', 0) >= 7000, 'source replacement')
    assert 'Episode 2' in session(), 'Retiring player cleared its successor media session'
    control('end')
    wait(lambda data: data.get('ended') and not data.get('playing'), 'keep-open EOF')
    control('replay')
    wait(lambda data: not data.get('ended', True) and data.get('playing')
         and 5000 <= data.get('position', 0) < 8000, 'resume after EOF seek')
    preparations = []

    def prepared(count, label):
        current = wait(lambda data: data.get('exitCallbacks') == count and not data.get('playing'), label)
        assert current['exitCallbackOnMain'], current
        assert current['exitDispatchMs'] < 100, f'Exit request blocked the main thread: {current}'
        assert current['exitDetachMs'] < 100, f'Prepared surface detach blocked the main thread: {current}'
        preparations.append({'case': label, 'dispatchMs': current['exitDispatchMs'],
                             'detachMs': current['exitDetachMs']})

    control('prepareExit')
    prepared(1, 'prepare playing exit')
    control('prepareExit')
    prepared(2, 'repeated exit preparation')
    control('stop')
    time.sleep(1)
    services = device('shell', 'dumpsys', 'activity', 'services', PACKAGE)
    assert 'isForeground=true' not in services, services
    control('releaseAndPrepare')
    prepared(3, 'release racing exit preparation')
    time.sleep(.3)
    control('prepareExit')
    prepared(4, 'preparation after player thread exits')
    final = state()
    assert not final['errors'] and final['loads'] == 2, final
    (work / 'result.json').write_text(json.dumps({'passed': True, 'cycles': results,
                                                'exitPreparations': preparations, 'final': final}, indent=2) + '\n')
    print(f'PASS: {args.cycles} real background/foreground cycles, native remote play/pause, video frames, source handoff, EOF, service cleanup and four exit preparation cases', flush=True)


if __name__ == '__main__':
    main()
