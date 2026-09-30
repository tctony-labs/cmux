#!/usr/bin/env python3
"""Validate and archive the dSYMs produced by the tctony Release build."""

import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def arm64_uuid(path: Path) -> str:
    output = command("xcrun", "dwarfdump", "--uuid", str(path))
    entries = re.findall(r"^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) ", output, re.MULTILINE)
    if len(entries) != 1 or entries[0][1] != "arm64":
        raise ValueError(f"Expected one arm64 UUID in {path.name}, found: {output}")
    return entries[0][0].upper()


def validate_symbols(binary: Path, dsym: Path) -> str:
    if not binary.is_file():
        raise ValueError(f"Missing executable: {binary}")
    if not dsym.is_dir():
        raise ValueError(f"Missing dSYM: {dsym}")
    dwarf = dsym / "Contents/Resources/DWARF" / binary.name
    if not dwarf.is_file() or dwarf.stat().st_size == 0:
        raise ValueError(f"Missing or empty DWARF file: {dwarf}")

    binary_uuid = arm64_uuid(binary)
    symbol_uuid = arm64_uuid(dwarf)
    if binary_uuid != symbol_uuid:
        raise ValueError(f"UUID mismatch for {dsym.name}: executable={binary_uuid}, dSYM={symbol_uuid}")
    debug_info = command("xcrun", "dwarfdump", "--debug-info", "--recurse-depth=0", str(dwarf))
    if "DW_TAG_compile_unit" not in debug_info:
        raise ValueError(f"Missing DWARF compile units: {dwarf}")
    subprocess.run(["xcrun", "dwarfdump", "--verify", "--quiet", str(dwarf)], check=True)
    print(f"Validated {dsym.name}: arm64 {binary_uuid}", flush=True)
    return binary_uuid


def archive(app: Path, destination: Path) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    products = app.parent
    # These are the three Xcode products built and bundled by the cmux scheme.
    # GhosttyKit and Swift packages link into them. The Rust/Zig helpers and
    # prebuilt third-party frameworks do not produce dSYMs in this build.
    targets = [
        (app / "Contents/MacOS" / info["CFBundleExecutable"], products / f"{app.name}.dSYM"),
        (app / "Contents/Resources/bin/cmux", products / "cmux.dSYM"),
        (
            app / "Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin",
            products / "CmuxDockTilePlugin.plugin.dSYM",
        ),
    ]
    symbols = []
    for binary, dsym in targets:
        uuid = validate_symbols(binary, dsym)
        symbols.append({
            "executable": binary.relative_to(app).as_posix(),
            "dsym": dsym.name,
            "architecture": "arm64",
            "uuid": uuid,
        })

    metadata = {
        "source_commit": command("git", "rev-parse", "HEAD"),
        "app_version": info["CFBundleShortVersionString"],
        "build_number": info["CFBundleVersion"],
        "xcode_version": command("xcodebuild", "-version"),
        "symbols": symbols,
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cmux-symbols-") as temporary:
        staging = Path(temporary) / "cmux-tctony-symbols"
        staging.mkdir()
        for _, dsym in targets:
            shutil.copytree(dsym, staging / dsym.name, symlinks=True)
        (staging / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        temporary_zip = Path(temporary) / "symbols.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(staging), str(temporary_zip)], check=True)
        shutil.move(str(temporary_zip), destination)
    print(f"Archived Release symbols: {destination}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: archive-release-symbols.py <app-path> <symbols-zip>")
    try:
        archive(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"error: {error}") from error


if __name__ == "__main__":
    main()
