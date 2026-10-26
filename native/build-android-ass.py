#!/usr/bin/env python3
"""Build mpv with patched libass while retaining mpv-android's codec/dependency ABI.

The hash-pinned original libmpv becomes libmpb (dependency bundle). The rebuilt
mpv core includes all of patched libass as an ordinary relocatable object, so
none of its calls can bind to the dependency bundle's legacy renderer. FFmpeg,
libplacebo, font providers, Lua and audio backends keep their original binaries.
Requires NDK 27.1.12297006, Python, Meson (or uv), Ninja, NASM and pkg-config
headers for FreeType, FriBidi, HarfBuzz, libunibreak and fontconfig.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile
import urllib.request

LIBASS_REVISION = 'fadc390583f24eb5cf98f16925fd3adee50bca88'
ORIGINAL = {
    'armeabi-v7a': '6aef182794a586d66891930a2e787a18fd87310d7931f5c901f75f93c761f99e',
    'arm64-v8a': 'e39e71c6dcab62b7eb9e58b483b5a32ce28738a7a7084c581173618c811af082',
    'x86': '5fc2aae083ac8de399dc593611073b4cd19e096399a09c619f8cd69812013bd0',
    'x86_64': 'd2a2a70327cab8e9b88ba6249fd7ca71d7d663846a540ad76562b2d13855172f',
}
ARCH = {
    'armeabi-v7a': ('armv7a-linux-androideabi', 'arm', 'armv7'),
    'arm64-v8a': ('aarch64-linux-android', 'aarch64', 'armv8'),
    'x86': ('i686-linux-android', 'x86', 'i686'),
    'x86_64': ('x86_64-linux-android', 'x86_64', 'x86_64'),
}
SOURCES = {
    'mpv': ('https://codeload.github.com/mpv-player/mpv/tar.gz/c798884163c1b779b0b17755631e319a17683e52', '8ecf4d717629c363207564f8434dd6934bed83f784d396763894fd88673c0ec8'),
    'placebo': ('https://codeload.github.com/haasn/libplacebo/tar.gz/33b5dfada6a84692912e4d41f673f895df79479e', '5031f3ea2d7c2ef54aa2c8acc9de866c7974b3b7c95e748728309ea849c01fa1'),
    'ffmpeg': ('https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.0.1.tar.gz', '679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1'),
    'lua': ('https://www.lua.org/ftp/lua-5.2.4.tar.gz', 'b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b'),
}


def run(*args, cwd=None, env=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, env=env, text=True)


def source(name, cache, destination):
    url, digest = SOURCES[name]
    archive = cache / (digest + '.tar.gz')
    if not archive.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError('Unexpected source checksum: ' + name)
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Invalid cached archive: ' + name)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts:
                raise RuntimeError('Invalid archive path')
            if not member.isfile():
                continue
            target = destination.joinpath(*relative.parts[1:])
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.extractfile(member) as data:
                target.write_bytes(data.read())
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True, help='Unmodified 2026-03-22 jniLibs directory')
    parser.add_argument('--ndk', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True, help='New output/build directory outside the repository')
    parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/expo-mpv')
    parser.add_argument('--libass-git', type=Path, help='Local libass repository for offline builds')
    parser.add_argument('--abi', choices=list(ARCH), action='append')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    work, cache, original = args.work.resolve(), args.cache.resolve(), args.input.resolve()
    if work.exists():
        raise RuntimeError('Use a fresh work directory; failed builds must not reuse old outputs')
    ndk = args.ndk.resolve()
    if '27.1.12297006' not in (ndk / 'source.properties').read_text():
        raise RuntimeError('This build is pinned to NDK 27.1.12297006')
    host = 'darwin-x86_64' if platform.system() == 'Darwin' else 'linux-x86_64'
    tool = ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
    meson = ['meson'] if shutil.which('meson') else ['uvx', 'meson']
    patch = Path(__file__).with_name('libass-sparse-drawings.patch')
    patch_hash = hashlib.sha256(patch.read_bytes()).hexdigest()
    marker = 'expo_mpv_libass_sparse_' + patch_hash[:16]
    work.mkdir(parents=True)
    cache.mkdir(parents=True, exist_ok=True)
    sources = {name: source(name, cache, work / 'sources' / name) for name in SOURCES}
    resize_patch = Path(__file__).with_name('android-surface-resize.patch')
    resize_hash = hashlib.sha256(resize_patch.read_bytes()).hexdigest()
    resize_marker = 'expo_mpv_android_resize_' + resize_hash[:16]
    run('git', 'apply', '--check', resize_patch, cwd=sources['mpv'])
    run('git', 'apply', resize_patch, cwd=sources['mpv'])
    context = sources['mpv'] / 'video/out/opengl/context_android.c'
    context.write_text(context.read_text() + f'\n__attribute__((visibility("default"))) void {resize_marker}(void) {{}}\n')
    libass = work / 'sources/libass'
    if args.libass_git:
        repository = args.libass_git.resolve()
        run('git', '-C', repository, 'cat-file', '-e', LIBASS_REVISION + '^{commit}')
        data = subprocess.check_output(['git', '-C', str(repository), 'archive', LIBASS_REVISION])
        libass.mkdir()
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(libass, filter='data')
    else:
        run('git', 'init', libass)
        run('git', 'fetch', '--depth=1', 'https://github.com/libass/libass.git', LIBASS_REVISION, cwd=libass)
    if not args.libass_git:
        run('git', 'checkout', '--detach', LIBASS_REVISION, cwd=libass)
        if run('git', 'rev-parse', 'HEAD', cwd=libass).strip() != LIBASS_REVISION:
            raise RuntimeError('Unexpected libass revision')
    run('git', 'apply', '--check', patch, cwd=libass)
    run('git', 'apply', patch, cwd=libass)
    renderer = libass / 'libass/ass_render.c'
    renderer.write_text(renderer.read_text() + f'\nvoid {marker}(void) {{}}\n')
    headers = {name: run('pkg-config', '--cflags-only-I', name).strip() for name in ('freetype2', 'fribidi', 'harfbuzz', 'libunibreak', 'fontconfig')}
    manifest = {'patch_sha256': patch_hash, 'android_resize_patch_sha256': resize_hash, 'libass_revision': LIBASS_REVISION, 'ndk': '27.1.12297006', 'header_packages': {name: run('pkg-config', '--modversion', name).strip() for name in headers}, 'libraries': {}}
    for abi in args.abi or list(ARCH):
        print('Building ' + abi, flush=True)
        prefix = work / abi
        libs, pc, include = prefix / 'lib', prefix / 'pkgconfig', prefix / 'include'
        for directory in (libs, pc, include):
            directory.mkdir(parents=True)
        base = original / abi / 'libmpv.so'
        data = base.read_bytes()
        if hashlib.sha256(data).hexdigest() != ORIGINAL[abi] or data.count(b'libmpv.so\0') != 1:
            raise RuntimeError('Unexpected upstream libmpv: ' + abi)
        (libs / 'libmpb.so').write_bytes(data.replace(b'libmpv.so\0', b'libmpb.so\0'))
        for library in (original / abi).glob('*.so'):
            if library.name != 'libmpv.so':
                shutil.copy2(library, libs / library.name)
        (include / 'ass').symlink_to(libass / 'libass', target_is_directory=True)
        (include / 'libavutil').mkdir()
        (include / 'libavutil/avconfig.h').write_text('#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 0\n')
        (include / 'libavutil/ffversion.h').write_text('#define FFMPEG_VERSION "8.0.1"\n')
        (include / 'libplacebo').mkdir()
        config = (sources['placebo'] / 'src/include/libplacebo/config.h.in').read_text()
        config = config.replace('@majorver@', '7').replace('@apiver@', '362').replace('@extra_defs@', '#define PL_HAVE_OPENGL 1\n#define PL_HAVE_GL_PROC_ADDR 1\n#define PL_HAVE_DOVI 1\n')
        (include / 'libplacebo/config.h').write_text(config)
        def package(name, version, flags='', links=None):
            if links is None:
                links = f'-L{libs} -lmpb'
            (pc / (name + '.pc')).write_text(f'Name: {name}\nDescription: Pinned mpv-android dependency ABI\nVersion: {version}\nLibs: {links}\nCflags: {flags}\n')
        for name, version in [('freetype2', '26.2.20'), ('fribidi', '1.0.16'), ('harfbuzz', '13.0.1'), ('libunibreak', '6.1'), ('fontconfig', '2.17.1')]:
            package(name, version, headers[name])
        for name, version in [('libavcodec', '62.11.100'), ('libavfilter', '11.4.100'), ('libavformat', '62.3.100'), ('libavutil', '60.8.100'), ('libavdevice', '62.1.100'), ('libswresample', '6.1.100'), ('libswscale', '9.1.100')]:
            package(name, version, f'-I{include} -I{sources["ffmpeg"]}', f'-L{libs} -l{name[3:]}')
        package('libplacebo', '7.362.0', f'-I{include} -I{sources["placebo"]}/src/include')
        package('lua52', '5.2.4', f'-I{sources["lua"]}/src')
        package('egl', '1.5', links='-lEGL')
        package('glesv2', '3.2', links='-lGLESv2')
        triple, family, cpu = ARCH[abi]
        cross = prefix / 'cross.ini'
        cross.write_text(f'''[binaries]
c = '{tool}/{triple}21-clang'
cpp = '{tool}/{triple}21-clang++'
ar = '{tool}/llvm-ar'
strip = '{tool}/llvm-strip'
pkg-config = '{shutil.which("pkg-config")}'
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'android'
cpu_family = '{family}'
cpu = '{cpu}'
endian = 'little'
[built-in options]
pkg_config_path = ['{pc}']
c_args = ['-I{include}']
c_link_args = ['-Wl,-z,max-page-size=16384', '-L{libs}']
''')
        env = {**os.environ, 'PKG_CONFIG_LIBDIR': str(pc), 'PKG_CONFIG_PATH': str(pc)}
        ass_build, mpv_build = prefix / 'libass', prefix / 'mpv'
        run(*meson, 'setup', ass_build, libass, '--cross-file', cross, '-Dbuildtype=release', '-Db_ndebug=true', '-Dcoretext=disabled', '-Dfontconfig=enabled', '-Dtest=disabled', '-Dcheckasm=disabled', '-Dcompare=disabled', env=env)
        run(*meson, 'compile', '-C', ass_build, '-j', args.jobs, env=env)
        # An ordinary object is included even when libmpb appears earlier in a
        # dependency list. Avoid silently binding libass symbols to the old DSO.
        ass_object = prefix / 'libass-combined.o'
        run(tool / 'ld.lld', '-r', '--whole-archive', ass_build / 'libass/libass.a', '--no-whole-archive', '-o', ass_object)
        package('libass', '0.17.4', f'-I{include}', f'{ass_object} -L{libs} -lmpb')
        run(*meson, 'setup', mpv_build, sources['mpv'], '--cross-file', cross, '--auto-features=disabled', '-Dbuildtype=release', '-Db_ndebug=true', '-Dlibmpv=true', '-Dcplayer=false', '-Dgl=enabled', '-Degl=enabled', '-Degl-android=enabled', '-Dandroid-media-ndk=enabled', '-Daudiotrack=enabled', '-Dzlib=enabled', '-Dlibavdevice=enabled', '-Dlua=lua52', '-Daaudio=enabled', '-Dopensles=enabled', '-Dcplugins=enabled', '-Ddvbin=enabled', '-Dvector=enabled', env=env)
        run(*meson, 'compile', '-C', mpv_build, '-j', args.jobs, env=env)
        stage = prefix / 'stage'
        run(*meson, 'install', '-C', mpv_build, '--no-rebuild', '--strip', '--destdir', stage, env=env)
        installed = list(stage.rglob('libmpv.so'))
        if len(installed) != 1:
            raise RuntimeError('Expected one installed libmpv.so')
        output = work / 'artifacts' / abi
        output.mkdir(parents=True)
        shutil.copy2(installed[0], output / 'libmpv.so')
        shutil.copy2(libs / 'libmpb.so', output / 'libmpb.so')
        symbols = run(tool / 'llvm-nm', '-D', output / 'libmpv.so')
        if marker not in symbols or resize_marker not in symbols or any(' U ass_' in line for line in symbols.splitlines()):
            raise RuntimeError('Rebuilt libmpv is missing the Android resize or complete libass repair')
        exported = {line.split()[-1] for line in run(tool / 'llvm-nm', '-D', '--defined-only', libs / 'libmpb.so').splitlines() if line.split()}
        prefixes = ('FT_', 'hb_', 'fribidi_', 'Fc', 'pl_', 'lua')
        imports = {line.split()[-1] for line in symbols.splitlines() if ' U ' in line and line.split()[-1].startswith(prefixes)}
        if imports - exported:
            raise RuntimeError('Dependency ABI mismatch: ' + repr(sorted(imports - exported)))
        needed = run(tool / 'llvm-readelf', '-d', output / 'libmpv.so')
        if 'libmpb.so' not in needed or str(work) in needed:
            raise RuntimeError('Invalid runtime dependencies or build-directory RPATH')
        manifest['libraries'][abi] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.glob('*.so')}
        (work / 'artifacts/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print('Verified ' + abi, flush=True)


if __name__ == '__main__':
    main()
