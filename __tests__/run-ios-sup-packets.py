#!/usr/bin/env python3
"""Check the shipped iOS SUP demuxer using generated PGS display sets."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("commands", ROOT / "__tests__/run-ios-commands.py")
commands = importlib.util.module_from_spec(spec)
spec.loader.exec_module(commands)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', help='An already booted iOS Simulator')
    args = parser.parse_args()
    devices = json.loads(commands.command('xcrun', 'simctl', 'list', 'devices', 'booted', '--json'))
    simulator = args.simulator or next(device['udid'] for runtime, group in devices['devices'].items()
        if 'iOS' in runtime for device in group if device['state'] == 'Booted')
    with tempfile.TemporaryDirectory(prefix='expo-mpv-sup-test-') as temporary:
        work = Path(temporary)
        fixture = work / 'fixture.sup'
        fixture.write_bytes(commands.pgs_subtitle())
        sdk = commands.command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
        binary = work / 'sup-packets'
        flags = ['xcrun', 'clang', '-target', 'arm64-apple-ios17.5-simulator', '-isysroot', sdk,
                 str(ROOT / '__tests__/ios-commands/SupPackets.c')]
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
                flags += ['-F', str(directory), '-framework', framework.stem]
            else:
                flags.append(str(directory / lib['LibraryPath']))
        for name in ['UIKit', 'Foundation', 'Metal', 'AVFoundation', 'CoreAudio', 'AudioToolbox',
                     'CoreVideo', 'CoreMedia', 'VideoToolbox', 'QuartzCore', 'CoreFoundation',
                     'IOSurface', 'CoreGraphics', 'CoreText', 'Security', 'SystemConfiguration',
                     'Accelerate']:
            flags += ['-framework', name]
        flags += ['-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2', '-lz', '-lc++',
                  '-o', str(binary)]
        subprocess.run(flags, check=True)
        subprocess.run(['xcrun', 'simctl', 'spawn', simulator, str(binary), str(fixture)], check=True)


if __name__ == '__main__':
    main()
