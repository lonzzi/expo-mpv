#!/usr/bin/env python3
"""Rebuild only MPVKit 0.41.0's MoltenVK backend for its iOS slices.

The upstream backend never handles VOCTRL_CHECK_EVENTS, leaving mpv's viewport
at its initial dimensions after the CAMetalLayer rotates. Keep all other archive
members and the bundled dependencies intact. Source archives are hash pinned;
each output is assembled separately before atomically replacing the old binary.
"""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import urllib.request

MARKER = "_expo_mpv_moltenvk_resize_v2"
MEMBER = "video_out_vulkan_context_moltenvk.m.o"
SOURCES = {
    "mpv": (
        "https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz",
        "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209",
        "mpv-0.41.0",
    ),
    "vulkan": (
        "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.304.tar.gz",
        "5e1a06b3f27e7581b55d1dea176fd97ee0a2f299406db2f437c1d2f297ceba5b",
        "Vulkan-Headers-1.4.304",
    ),
}


def run(*args, cwd=None):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, text=True)


def source_archive(name, destination):
    url, digest, directory = SOURCES[name]
    cache = Path.home() / "Library/Caches/expo-mpv"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (digest + ".tar.gz")
    if not archive.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError(f"Unexpected checksum for {name}")
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f"Invalid cached source archive: {archive}")
    # Python 3.9+ support without trusting archive paths, links, or permissions.
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Invalid archive path: {member.name}")
            if not member.isfile():
                continue
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.extractfile(member) as data:
                target.write_bytes(data.read())
    return destination / directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frameworks", type=Path)
    parser.add_argument("--force", action="store_true", help="Rebuild after editing the backend")
    args = parser.parse_args()
    frameworks = args.frameworks.resolve()
    if (frameworks / ".version").read_text().strip() != "0.41.0":
        raise RuntimeError("This backend repair is pinned to MPVKit 0.41.0")
    xcframework = frameworks / "Libmpv.xcframework"
    metadata = plistlib.loads((xcframework / "Info.plist").read_bytes())
    slices = [item for item in metadata["AvailableLibraries"]
              if item["SupportedPlatform"] == "ios"]
    if not slices:
        raise RuntimeError("MPVKit has no iOS slices")
    pending = []
    for item in slices:
        binary = xcframework / item["LibraryIdentifier"] / item["LibraryPath"] / "Libmpv"
        symbols = run("xcrun", "nm", "-arch", "all", "-g", binary)
        if args.force or symbols.count(MARKER) != len(item["SupportedArchitectures"]):
            pending.append((item, binary))
    if not pending:
        print("[expo-mpv] MoltenVK resize fix already applied to every iOS architecture.")
        return

    backend = Path(__file__).resolve().parent / "context_moltenvk.m.inc"
    with tempfile.TemporaryDirectory(prefix="expo-mpv-resize-") as temporary:
        work = Path(temporary)
        mpv = source_archive("mpv", work)
        vulkan = source_archive("vulkan", work)
        (work / "config.h").write_text("#define HAVE_POSIX 1\n")
        for item, binary in pending:
            identifier = item["LibraryIdentifier"]
            headers = work / identifier / "include"
            headers.mkdir(parents=True)
            for library, module in [("Libplacebo", "libplacebo"), ("Libavutil", "libavutil")]:
                path = frameworks / (library + ".xcframework") / identifier / (library + ".framework/Headers")
                (headers / module).symlink_to(path, target_is_directory=True)
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
                build.mkdir()
                archive = build / "Libmpv.a"
                run("xcrun", "lipo", binary, "-thin", arch, "-output", archive)
                if run("xcrun", "ar", "-t", archive).splitlines().count(MEMBER) != 1:
                    raise RuntimeError(f"Unexpected MPVKit backend archive: {binary}")
                target = f"{arch}-apple-ios16.0"
                if variant == "simulator":
                    target += "-simulator"
                elif variant == "maccatalyst":
                    target += "-macabi"
                obj = build / MEMBER
                run("xcrun", "clang", "-target", target, "-isysroot", sdk_path,
                    "-O2", "-x", "objective-c", "-fno-objc-arc", "-I", work, "-I", headers,
                    "-I", mpv, "-I", mpv / "video/out/vulkan",
                    "-I", vulkan / "include", "-c", backend, "-o", obj)
                run("xcrun", "ar", "-r", archive, obj)
                run("xcrun", "ranlib", archive)
                if MARKER not in run("xcrun", "nm", "-g", archive):
                    raise RuntimeError(f"Missing fixed backend: {identifier}/{arch}")
                archives.append(archive)
            # Stage next to the target so os.replace is atomic on the same volume.
            staged = binary.with_name("Libmpv.resize-fixed")
            try:
                run("xcrun", "lipo", "-create", *archives, "-output", staged)
                staged.chmod(binary.stat().st_mode)
                os.replace(staged, binary)
            finally:
                if staged.exists():
                    staged.unlink()
            print(f"[expo-mpv] Fixed MoltenVK resize: {identifier}")


if __name__ == "__main__":
    main()
