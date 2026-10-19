#!/usr/bin/env python3
"""Pixel and lifetime regression tests for the native libass repair.

Build an unmodified reference and the patched renderer from the same revision,
with ASan/UBSan, then compare holes, disconnected paths, fades, moves, clipping,
transforms and ordinary styled text at multiple output sizes. Optional real ASS
files remain outside the repository. All generated results go to --work.
"""
import argparse
import io
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
REVISION = 'bbb3c7f1570a4a021e52683f3fbdf74fe492ae84'


def run(*args, cwd=None, env=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, env=env, text=True)


def build(repository, work, patched):
    destination = work / ('patched' if patched else 'reference')
    destination.mkdir()
    data = subprocess.check_output(['git', '-C', str(repository), 'archive', REVISION])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(destination, filter='data')
    if patched:
        run('git', 'apply', ROOT / 'native/libass-sparse-drawings.patch', cwd=destination)
    binary_dir = destination / 'build'
    meson = ['meson'] if shutil.which('meson') else ['uvx', 'meson']
    run(*meson, 'setup', binary_dir, destination, '-Dbuildtype=release', '-Db_sanitize=address,undefined', '-Db_lundef=false', '-Dfontconfig=disabled', '-Dtest=disabled', '-Dcheckasm=disabled', '-Dcompare=disabled')
    run(*meson, 'compile', '-C', binary_dir, '-j', '4')
    includes = destination / 'include'
    includes.mkdir()
    (includes / 'ass').symlink_to(destination / 'libass', target_is_directory=True)
    dependencies = shlex.split(run('pkg-config', '--cflags', '--libs', 'freetype2', 'fribidi', 'harfbuzz', 'libunibreak'))
    binary = destination / 'render'
    command = ['cc', '-O2', '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', includes, ROOT / '__tests__/libass/render-regression.c', binary_dir / 'libass/libass.a', *dependencies, '-lm']
    if platform.system() == 'Darwin':
        command += ['-liconv', '-framework', 'CoreText', '-framework', 'CoreFoundation', '-framework', 'CoreGraphics']
    run(*command, '-o', binary)
    return binary


def fixture(path):
    drawing = 'm 70 70 l 250 70 250 230 70 230 m 110 110 l 110 190 210 190 210 110 m 1500 760 l 1710 760 1710 950 1500 950 m 650 430 b 700 330 850 530 900 430 l 900 550 650 550'
    header = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 2
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans CJK SC,34,&H002060E0,&H0000FFFF,&H00000000,&H40000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
'''
    tags = [r'\pos(0,0)', r'\move(0,100,0,-500)\fad(400,500)', r'\pos(0,0)\clip(40,90,1600,800)', r'\pos(0,0)\iclip(100,100,900,600)', r'\pos(0,0)\clip(m 0 0 l 1900 0 1800 900 0 800)', r'\pos(0,0)\fscx50\fscy50', r'\pos(0,0)\fscx25\fscy25', r'\pos(0,0)\frz12', r'\pos(0,0)\frx15\fry8', r'\pos(0,0)\fax0.15\fay0.1', r'\pos(0,0)\bord3\shad2\blur1.5', r'\pos(0,0)\be1', r'\pos(0,0)\alpha&H60&\t(0,4000,\1c&H00FF00&)', r'\pos(-2200,-1500)', r'\pos(0,0)\t(0,4000,\frz30)']
    # Give each variation its own time span to exercise both fast and fallback paths.
    events = []
    for index, tag in enumerate(tags):
        start, end = index * 5, index * 5 + 5
        timestamp = lambda second: f'0:{second//60:02d}:{second%60:02d}.00'
        events.append(f'Dialogue: 0,{timestamp(start)},{timestamp(end)},Default,,0,0,0,,{{\\an7{tag}\\p1}}{drawing}')
        events.append(f'Dialogue: 1,{timestamp(start)},{timestamp(end)},Default,,0,0,0,,{{\\an7\\pos(200,900)\\bord2\\shad1}}Ordinary text {{\\i1}}italics{{\\i0}} 中文')
    path.write_text(header + '\n'.join(events) + '\n')
    return [index * 5000 + offset for index in range(len(tags)) for offset in (1, 500, 2450, 4800)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Local libass Git repository containing 0.17.4')
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--ass', type=Path, action='append', default=[])
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=False)
    binaries = [build(args.source.resolve(), work, patched) for patched in (False, True)]
    ass = work / 'synthetic.ass'
    times = fixture(ass)
    tests = [(ass, times)] + [(p.resolve(), [2819200, 2824000, 2826500, 2835000, 2848000, 2859500, 2860200]) for p in args.ass]
    font = ROOT / 'ios/Fonts/NotoSansCJKsc-Regular.otf'
    env = {**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0', 'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'}
    results = []
    for index, (subtitle, timestamps) in enumerate(tests):
        for width, height in [(960, 540), (1920, 1080), (2670, 1200)]:
            prefixes = []
            for variant, binary in enumerate(binaries):
                prefix = work / f'test-{index}-{width}-{variant}'
                prefixes.append(prefix)
                run(binary, subtitle, font, prefix, width, height, ','.join(map(str, timestamps)), env=env)
            maximum, differing = 0, 0
            for frame in range(len(timestamps)):
                a = Path(f'{prefixes[0]}-{frame}.rgb')
                b = Path(f'{prefixes[1]}-{frame}.rgb')
                left, right = a.read_bytes(), b.read_bytes()
                if len(left) != len(right):
                    raise RuntimeError('Different image dimensions')
                delta = [abs(x-y) for x, y in zip(left, right)]
                maximum = max(maximum, max(delta, default=0))
                differing += sum(value != 0 for value in delta)
                # Independent raster surfaces can round edge coverage slightly
                # differently. Bound both the largest error and total image error.
                if max(delta, default=0) > 4 or sum(delta) / len(delta) > 0.01:
                    raise RuntimeError(f'Pixel mismatch: test {index}, size {width}, frame {frame}: max={max(delta)}, mean={sum(delta)/len(delta)}')
                a.unlink()
                b.unlink()
            result = {'test': index, 'size': [width, height], 'frames': len(timestamps), 'max_channel_error': maximum, 'different_channels': differing, 'retained_frames': 'pass', 'sanitizers': 'pass'}
            results.append(result)
            print(json.dumps(result), flush=True)
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
