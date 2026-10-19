#!/usr/bin/env python3
"""Apply the sparse drawing renderer to MPVKit 0.41.0's iOS libass slices.

Rebuild the cache, renderer and shaper from the exact bundled libass revision.
All other archive members, assembly routines and dependencies remain intact.
"""
import argparse
import hashlib
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import tarfile

REVISION = "bbb3c7f1570a4a021e52683f3fbdf74fe492ae84"
MEMBERS = ("ass_cache.c.o", "ass_render.c.o", "ass_shaper.c.o")


def run(*args, cwd=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frameworks", type=Path)
    parser.add_argument("--source", type=Path, help="Local libass Git repository for offline builds")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    frameworks = args.frameworks.resolve()
    if (frameworks / ".version").read_text().strip() != "0.41.0":
        raise RuntimeError("The libass repair is pinned to MPVKit 0.41.0")
    patch = Path(__file__).resolve().parent.parent / "native/libass-sparse-drawings.patch"
    digest = hashlib.sha256(patch.read_bytes()).hexdigest()[:16]
    marker = "expo_mpv_libass_sparse_" + digest
    library = frameworks / "Libass.xcframework"
    info = plistlib.loads((library / "Info.plist").read_bytes())
    pending = []
    for item in info["AvailableLibraries"]:
        if item["SupportedPlatform"] != "ios":
            continue
        binary = library / item["LibraryIdentifier"] / item["LibraryPath"] / "Libass"
        if args.force or run("xcrun", "nm", "-arch", "all", "-g", binary).count("_" + marker) != len(item["SupportedArchitectures"]):
            pending.append((item, binary))
    if not pending:
        print("[expo-mpv] Sparse libass renderer already applied to all iOS architectures.")
        return
    with tempfile.TemporaryDirectory(prefix="expo-mpv-libass-") as directory:
        work = Path(directory)
        source = work / "source"
        repository = args.source.resolve() if args.source else Path.home() / "Library/Caches/expo-mpv/libass.git"
        if not args.source:
            if not repository.exists():
                repository.parent.mkdir(parents=True, exist_ok=True)
                run("git", "init", "--bare", repository)
            available = subprocess.run(["git", "-C", str(repository), "cat-file", "-e", REVISION + "^{commit}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if not available:
                run("git", "-C", repository, "fetch", "--depth=1", "https://github.com/libass/libass.git", REVISION)
        run("git", "-C", repository, "cat-file", "-e", REVISION + "^{commit}")
        data = subprocess.check_output(["git", "-C", str(repository), "archive", REVISION])
        source.mkdir()
        with tarfile.open(fileobj=io.BytesIO(data)) as package:
            for member in package.getmembers():
                relative = Path(member.name)
                if relative.is_absolute() or ".." in relative.parts:
                    raise RuntimeError("Invalid source archive path")
                if not member.isfile():
                    continue
                target = source / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as content:
                    target.write_bytes(content.read())
        run("git", "apply", "--check", patch, cwd=source)
        run("git", "apply", patch, cwd=source)
        renderer = source / "libass/ass_render.c"
        renderer.write_text(renderer.read_text() + f"\nvoid {marker}(void) {{}}\n")
        for item, binary in pending:
            identifier = item["LibraryIdentifier"]
            variant = item.get("SupportedPlatformVariant")
            sdk = "iphonesimulator" if variant == "simulator" else "iphoneos"
            if variant == "maccatalyst":
                sdk = "macosx"
            sdk_path = run("xcrun", "--sdk", sdk, "--show-sdk-path").strip()
            archives = []
            for arch in item["SupportedArchitectures"]:
                if arch not in ("arm64", "x86_64"):
                    raise RuntimeError(f"Unsupported architecture: {arch}")
                build = work / identifier / arch
                build.mkdir(parents=True)
                flags = ["ARCH_AARCH64"] if arch == "arm64" else ["ARCH_X86", "ARCH_X86_64"]
                flags += ["CONFIG_ASM", "CONFIG_CORETEXT", "CONFIG_ICONV", "CONFIG_UNIBREAK", "HAVE_FSTAT", "HAVE_STRDUP", "HAVE_STRNDUP"]
                (build / "config.h").write_text("#pragma once\n" + "".join(f"#define {flag} 1\n" for flag in flags) +
                    '#define CONFIG_LARGE_TILES 0\n' + f'#define CONFIG_SOURCEVERSION "0.17.4-{REVISION} + sparse {digest}"\n')
                archive = build / "Libass.a"
                run("xcrun", "lipo", binary, "-thin", arch, "-output", archive)
                members = run("xcrun", "ar", "-t", archive).splitlines()
                if any(members.count(member) != 1 for member in MEMBERS):
                    raise RuntimeError(f"Unexpected libass archive members: {identifier}/{arch}")
                includes = []
                for name, subdir in [("Libfreetype", "freetype2"), ("Libharfbuzz", "harfbuzz"), ("Libfribidi", "fribidi"), ("Libunibreak", "")]:
                    includes += ["-I", frameworks / (name + ".xcframework") / identifier / (name + ".framework/Headers") / subdir]
                target = arch + "-apple-ios16.0"
                if variant == "simulator":
                    target += "-simulator"
                elif variant == "maccatalyst":
                    target += "-macabi"
                for member in MEMBERS:
                    obj = build / member
                    run("xcrun", "clang", "-target", target, "-isysroot", sdk_path,
                        "-O3", "-DNDEBUG", "-fvisibility=hidden", "-I", build,
                        "-I", source / "libass", *includes, "-c", source / "libass" / member[:-2], "-o", obj)
                    run("xcrun", "ar", "-r", archive, obj)
                run("xcrun", "ranlib", archive)
                if "_" + marker not in run("xcrun", "nm", "-g", archive):
                    raise RuntimeError("Missing optimized renderer marker")
                archives.append(archive)
            staged = binary.with_name("Libass.sparse-fixed")
            try:
                run("xcrun", "lipo", "-create", *archives, "-output", staged)
                staged.chmod(binary.stat().st_mode)
                os.replace(staged, binary)
            finally:
                if staged.exists():
                    staged.unlink()
            print(f"[expo-mpv] Optimized libass: {identifier}")


if __name__ == "__main__":
    main()
