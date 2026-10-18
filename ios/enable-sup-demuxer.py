#!/usr/bin/env python3
"""Add FFmpeg n8.0.1's SUP demuxer to MPVKit 0.41.0's iOS archives.

Only supdec.o and the format registry are rebuilt. Existing format order and all
other archive members are preserved, including the device registration API.
"""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "0.41.0"
SOURCE_URL = "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.0.1.tar.gz"
SOURCE_SHA256 = "679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1"
MARKER = "_expo_mpv_sup_demuxer_v2"


def run(*args, cwd=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, text=True)


def source_archive(destination):
    cache = Path.home() / "Library/Caches/expo-mpv"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (SOURCE_SHA256 + ".tar.gz")
    if not archive.exists():
        with urllib.request.urlopen(SOURCE_URL, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
            raise RuntimeError("Unexpected FFmpeg source checksum")
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise RuntimeError(f"Invalid cached FFmpeg source: {archive}")
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Invalid source archive path: {member.name}")
            if member.isfile():
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as data:
                    target.write_bytes(data.read())
    return destination / "FFmpeg-n8.0.1"


def format_lists(registry):
    # Mach-O relocations retain the actual registration order; nm alone sorts
    # symbol names and can silently alter probing precedence.
    relocations = re.findall(
        r"^([0-9a-f]{8})\s+.*\s_ff_(\w+_(?:demuxer|muxer))$",
        run("xcrun", "otool", "-rv", registry), re.MULTILINE)
    ordered = [name for _, name in sorted((int(offset, 16), name)
               for offset, name in relocations)]
    result = {kind: [name for name in ordered if name.endswith("_" + kind)]
              for kind in ("demuxer", "muxer")}
    if not result["demuxer"] or len(ordered) != len(set(ordered)):
        raise RuntimeError("Unexpected FFmpeg format registry relocations")
    undefined = set(re.findall(r"_ff_(\w+_(?:demuxer|muxer))$",
                    run("xcrun", "nm", "-u", registry), re.MULTILINE))
    if set(ordered) != undefined:
        raise RuntimeError("Cannot preserve the complete FFmpeg format registry")
    return result


def patch_slice(frameworks, source, work, item, binary):
    identifier = item["LibraryIdentifier"]
    variant = item.get("SupportedPlatformVariant")
    sdk = {"simulator": "iphonesimulator", "maccatalyst": "macosx"}.get(variant, "iphoneos")
    sdk_path = run("xcrun", "--sdk", sdk, "--show-sdk-path").strip()
    archives = []
    for arch in item["SupportedArchitectures"]:
        if arch not in ("arm64", "x86_64"):
            raise RuntimeError(f"Unsupported architecture: {arch}")
        build = work / identifier / arch
        build.mkdir(parents=True)
        archive = build / "Libavformat.a"
        run("xcrun", "lipo", binary, "-thin", arch, "-output", archive)
        members = run("xcrun", "ar", "-t", archive).splitlines()
        if members.count("allformats.o") != 1:
            raise RuntimeError(f"Unexpected MPVKit FFmpeg archive: {binary}")
        run("xcrun", "ar", "-x", archive, "allformats.o", cwd=build)
        formats = format_lists(build / "allformats.o")
        formats["demuxer"] = [name for name in formats["demuxer"] if name != "sup_demuxer"]
        for kind, names in formats.items():
            entries = names + (["sup_demuxer"] if kind == "demuxer" else [])
            lists = build / "libavformat"
            lists.mkdir(exist_ok=True)
            struct = "FFInputFormat" if kind == "demuxer" else "FFOutputFormat"
            (lists / (kind + "_list.c")).write_text(
                f"static const {struct} *const {kind}_list[] = {{\n" +
                "".join(f"    &ff_{name},\n" for name in entries) + "    NULL\n};\n")
        headers = build / "include"
        headers.mkdir()
        for library, module in [("Libavutil", "libavutil")]:
            (headers / module).symlink_to(frameworks / (library + ".xcframework") /
                identifier / (library + ".framework/Headers"), target_is_directory=True)
        # These two sources only need public FFmpeg ABI headers and portable
        # integer helpers; no codec or platform configuration is changed.
        (build / "config.h").write_text(
            "#define HAVE_FAST_CLZ 1\n#define NULL_IF_CONFIG_SMALL(x) x\n")
        target = f"{arch}-apple-ios16.0"
        if variant == "simulator":
            target += "-simulator"
        elif variant == "maccatalyst":
            target += "-macabi"
        for member in ("allformats", "supdec"):
            input_source = (source / "libavformat/allformats.c" if member == "allformats"
                            else Path(__file__).resolve().parent / "sup-demuxer.c.inc")
            run("xcrun", "clang", "-target", target, "-isysroot", sdk_path,
                "-x", "c", "-std=c11", "-O2", "-include", build / "config.h",
                "-I", build, "-I", headers, "-I", source,
                "-c", input_source,
                "-o", build / (member + ".o"))
        marker = build / "sup-support.c"
        marker.write_text(f"const int {MARKER[1:]} = 1;\n")
        run("xcrun", "clang", "-target", target, "-isysroot", sdk_path,
            "-c", marker, "-o", build / "sup-support.o")
        run("xcrun", "ar", "-r", archive, build / "allformats.o",
            build / "supdec.o", build / "sup-support.o")
        run("xcrun", "ranlib", archive)
        updated = format_lists(build / "allformats.o")
        if (updated["demuxer"] != formats["demuxer"] + ["sup_demuxer"] or
                updated["muxer"] != formats["muxer"]):
            raise RuntimeError("The original FFmpeg format order changed")
        archives.append(archive)
    staged = binary.with_name("Libavformat.sup-enabled")
    try:
        run("xcrun", "lipo", "-create", *archives, "-output", staged)
        staged.chmod(binary.stat().st_mode)
        os.replace(staged, binary)
        # CocoaPods declares the XCFramework directory as a build input.
        os.utime(binary.parents[2], None)
    finally:
        staged.unlink(missing_ok=True)
    print(f"[expo-mpv] Enabled SUP demuxer: {identifier}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frameworks", type=Path)
    args = parser.parse_args()
    frameworks = args.frameworks.resolve()
    if (frameworks / ".version").read_text().strip() != VERSION:
        raise RuntimeError("SUP support is pinned to MPVKit 0.41.0 / FFmpeg n8.0.1")
    xcframework = frameworks / "Libavformat.xcframework"
    metadata = plistlib.loads((xcframework / "Info.plist").read_bytes())
    pending = []
    for item in metadata["AvailableLibraries"]:
        if item["SupportedPlatform"] != "ios":
            continue
        binary = xcframework / item["LibraryIdentifier"] / item["LibraryPath"] / "Libavformat"
        symbols = run("xcrun", "nm", "-arch", "all", "-g", binary)
        if symbols.count(MARKER) != len(item["SupportedArchitectures"]):
            pending.append((item, binary))
    if not pending:
        print("[expo-mpv] SUP demuxer already enabled for every iOS architecture.")
        return
    with tempfile.TemporaryDirectory(prefix="expo-mpv-sup-") as temporary:
        work = Path(temporary)
        source = source_archive(work)
        for item, binary in pending:
            patch_slice(frameworks, source, work, item, binary)


if __name__ == "__main__":
    main()
