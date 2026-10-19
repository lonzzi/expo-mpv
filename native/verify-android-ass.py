#!/usr/bin/env python3
"""Verify the Android renderer asset before publishing or installing a release."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path, nargs='?')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    config = json.loads((root / 'android-ass.json').read_text())
    if args.archive:
        data = args.archive.read_bytes()
    else:
        url = f'https://github.com/lonzzi/expo-mpv/releases/download/v{config["version"]}/{config["asset"]}'
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != config['sha256']:
        raise RuntimeError('Native archive checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        if manifest['patch_sha256'] != hashlib.sha256((root / 'libass-sparse-drawings.patch').read_bytes()).hexdigest():
            raise RuntimeError('Native asset was built from a different libass patch')
        machines = {'armeabi-v7a': 40, 'arm64-v8a': 183, 'x86': 3, 'x86_64': 62}
        expected = {'manifest.json'}
        for abi, machine in machines.items():
            for name in ('libmpv.so', 'libmpb.so'):
                path = abi + '/' + name
                expected.add(path)
                library = archive.read(path)
                if hashlib.sha256(library).hexdigest() != manifest['libraries'][abi][name]:
                    raise RuntimeError('Library checksum mismatch: ' + path)
                if library[:4] != b'\x7fELF' or library[5] != 1 or int.from_bytes(library[18:20], 'little') != machine:
                    raise RuntimeError('Wrong ELF architecture: ' + path)
        if set(archive.namelist()) != expected or len(archive.namelist()) != len(expected):
            raise RuntimeError('Unexpected or duplicate archive entries')
    print('Verified optimized libass asset and all four Android ABIs.')


if __name__ == '__main__':
    main()
