#!/usr/bin/env python3
"""Run the real MoltenVK backend's geometry/event regression on macOS."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("resize_repair", root / "ios/fix-moltenvk-resize.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)
with tempfile.TemporaryDirectory(prefix="expo-mpv-resize-test-") as temporary:
    work = Path(temporary)
    mpv = repair.source_archive("mpv", work)
    vulkan = repair.source_archive("vulkan", work)
    (work / "config.h").write_text("#define HAVE_POSIX 1\n")
    include = work / "include"
    include.mkdir()
    for library, module in [("Libplacebo", "libplacebo"), ("Libavutil", "libavutil")]:
        (include / module).symlink_to(root / "ios/Frameworks" / (library + ".xcframework") /
                                     "macos-arm64_x86_64" / (library + ".framework/Headers"),
                                     target_is_directory=True)
    binary = work / "resize-regression"
    subprocess.run(["xcrun", "clang", "-O2", "-I", str(work), "-I", str(include),
                    "-I", str(mpv), "-I", str(mpv / "video/out/vulkan"),
                    "-I", str(vulkan / "include"), str(root / "__tests__/moltenvk-resize.m"),
                    "-framework", "Foundation", "-framework", "QuartzCore",
                    "-Wl,-undefined,dynamic_lookup", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
