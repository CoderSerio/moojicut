#!/usr/bin/env python3
"""Build a standalone MoonBit plugin and package it with an optional PNG icon.

This checks build artifacts and archive structure, not the Mooji Cut business
protocol. App import remains authoritative for manifest validation and the
mooji_run ABI/runtime probe.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_LIMIT = 64 * 1024
WASM_LIMIT = 4 * 1024 * 1024
ICON_LIMIT = 256 * 1024
ZIP_LIMIT = 8 * 1024 * 1024
TOTAL_LIMIT = 5 * 1024 * 1024


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"Non-JSON numeric constant: {value}")


def read_manifest(project: Path) -> bytes:
    path = project / "manifest.json"
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MANIFEST_LIMIT:
        raise ValueError("manifest.json must be a regular file of at most 64 KiB.")
    data = path.read_bytes()
    manifest = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                          parse_constant=reject_constant)
    if not isinstance(manifest, dict) or manifest.get("entry") != "plugin.wasm":
        raise ValueError("Expected a manifest object with entry set to plugin.wasm.")
    return data


def read_icon(project: Path) -> bytes | None:
    path = project / "assets" / "icon.png"
    if not path.exists() and not path.is_symlink():
        return None
    if (not path.is_file() or path.is_symlink() or path.parent.is_symlink() or
            path.stat().st_size > ICON_LIMIT):
        raise ValueError("assets/icon.png must be a regular, non-symlink file of at most 256 KiB.")
    data = path.read_bytes()
    if (len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or
            data[8:16] != b"\0\0\0\rIHDR"):
        raise ValueError("assets/icon.png must start with a valid PNG IHDR chunk.")
    width, height = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if not (1 <= width <= 512 and 1 <= height <= 512):
        raise ValueError("Plugin icon dimensions must be 1–512 pixels.")
    if (data[24] not in (1, 2, 4, 8, 16) or data[25] not in (0, 2, 3, 4, 6) or
            data[26:28] != b"\0\0" or data[28] not in (0, 1) or
            zlib.crc32(data[12:29]) != int.from_bytes(data[29:33], "big")):
        raise ValueError("Invalid PNG IHDR fields or checksum.")
    # Full image decoding remains an App import check.
    return data


class Reader:
    def __init__(self, data: bytes):
        self.data, self.offset = data, 0

    def take(self, length: int) -> bytes:
        if length < 0 or length > len(self.data) - self.offset:
            raise ValueError("Truncated Wasm section.")
        result = self.data[self.offset:self.offset + length]
        self.offset += length
        return result

    def byte(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        value = 0
        for index in range(5):
            byte = self.byte()
            if index == 4 and byte & 0xF0:
                raise ValueError("Invalid Wasm u32 encoding.")
            value |= (byte & 0x7F) << (index * 7)
            if not byte & 0x80:
                return value
        raise ValueError("Invalid Wasm u32 encoding.")

    def name(self) -> str:
        return self.take(self.u32()).decode("utf-8")


def validate_wasm(data: bytes) -> None:
    if len(data) > WASM_LIMIT or data[:8] != b"\0asm\x01\0\0\0":
        raise ValueError("Expected a core Wasm v1 module of at most 4 MiB.")
    module = Reader(data[8:])
    exports, memory_count = {}, 0
    while module.offset < len(module.data):
        section_id = module.byte()
        section = Reader(module.take(module.u32()))
        if section_id == 2:  # The selected Extism ABI imports functions only.
            for _ in range(section.u32()):
                section.name()
                section.name()
                if section.byte() != 0:
                    raise ValueError("Expected function-only Wasm imports.")
                section.u32()
        elif section_id == 5:
            count = section.u32()
            memory_count += count
            for _ in range(count):
                flags = section.u32()
                if flags not in (0, 1):
                    raise ValueError("Use --target wasm with 32-bit, unshared linear memory.")
                section.u32()
                if flags & 1:
                    section.u32()
        elif section_id == 7:
            for _ in range(section.u32()):
                name, kind, index = section.name(), section.byte(), section.u32()
                if name in exports:
                    raise ValueError("Duplicate Wasm export name.")
                exports[name] = (kind, index)
        else:
            continue  # Full module/ABI validation belongs to the App's probe.
        if section.offset != len(section.data):
            raise ValueError("Invalid Wasm import, memory, or export section.")
    if memory_count != 1 or exports.get("memory") != (2, 0):
        raise ValueError("The plugin must export its single linear memory as memory.")
    if exports.get("mooji_run", (None,))[0] != 0:
        raise ValueError("The plugin must export the function mooji_run.")


def moon_toolchain() -> tuple[Path, dict[str, str]]:
    environment = os.environ.copy()
    configured = environment.get("MOON_HOME")
    executable_name = "moon.exe" if sys.platform == "win32" else "moon"
    bundled_home = ROOT / ".tools" / "moon"
    if configured:
        home = Path(configured).expanduser()
        executable = home / "bin" / executable_name
    elif (bundled_home / "bin" / executable_name).is_file():
        home = bundled_home
        executable = home / "bin" / executable_name
    else:
        found = shutil.which("moon")
        if not found:
            raise ValueError("Install MoonBit or set MOON_HOME to your toolchain directory.")
        executable = Path(found).resolve()
        home = executable.parent.parent
    if not executable.is_file():
        raise ValueError(f"MoonBit executable not found: {executable}")
    environment["MOON_HOME"] = str(home.resolve())
    environment.setdefault("MOON_REGISTRY_API", "1")
    return executable.resolve(), environment


def moon_command(executable: Path, project: Path, environment: dict[str, str], *arguments: str) -> str:
    command = [str(executable), "-C", str(project), *arguments]
    result = subprocess.run(command, cwd=project, env=environment, text=True,
                            capture_output=True, timeout=180)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode:
        if result.stdout:
            print(result.stdout, end="", file=sys.stderr)
        raise ValueError(f"moon {arguments[0]} failed (exit {result.returncode}).")
    return result.stdout


def build(project: Path, offline: bool) -> bytes:
    executable, environment = moon_toolchain()
    if not offline:
        print("Refreshing exact dependency metadata…", flush=True)
        print(moon_command(executable, project, environment, "update"), end="")
    arguments = ["--target-dir", str(project / "_build" / "package-plugin"),
                 "build", "--target", "wasm", "--release", "--output-json"]
    if offline:
        arguments.append("--frozen")
    print("Building the Wasm plugin…", flush=True)
    output = moon_command(executable, project, environment, *arguments)
    artifacts = []
    for line in output.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (message.get("$message_type") == "artifact" and
                message.get("target_backend") == "wasm"):
            path = Path(message["path"])
            if not path.is_absolute():
                path = project / path
            if path.suffix == ".wasm":
                artifacts.append(path)
    if len(artifacts) != 1:
        raise ValueError("Expected exactly one exported Wasm artifact in this standalone module.")
    path = artifacts[0]
    if not path.is_file() or path.is_symlink() or path.stat().st_size > WASM_LIMIT:
        raise ValueError("The reported Wasm artifact is missing or exceeds 4 MiB.")
    data = path.read_bytes()
    validate_wasm(data)
    return data


def write_package(output: Path, manifest: bytes, wasm: bytes, icon: bytes | None = None) -> None:
    files = [("manifest.json", manifest), ("plugin.wasm", wasm)]
    if icon is not None:
        files.append(("assets/icon.png", icon))
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".plugin-package-", suffix=".zip", dir=output.parent)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED,
                             compresslevel=9, allowZip64=False) as archive:
            for name, data in files:
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, data)
        if Path(temporary).stat().st_size > ZIP_LIMIT:
            raise ValueError("Plugin ZIP exceeds 8 MiB.")
        with zipfile.ZipFile(temporary) as archive:
            if archive.namelist() != [name for name, _ in files] or archive.testzip() is not None:
                raise ValueError("Packaged file names or CRC validation failed.")
            if sum(entry.file_size for entry in archive.infolist()) > TOTAL_LIMIT:
                raise ValueError("Expanded package exceeds 5 MiB.")
            if any(archive.read(name) != data for name, data in files):
                raise ValueError("Packaged contents differ from the validated build inputs.")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="Standalone MoonBit plugin directory")
    parser.add_argument("--output", required=True, type=Path, help="Destination .zip file")
    parser.add_argument("--offline", action="store_true", help="Skip registry refresh and require cached dependencies")
    arguments = parser.parse_args()
    project, output = arguments.project.resolve(), arguments.output.resolve()
    try:
        if not (project / "moon.mod").is_file() or (project / "moon.work").exists():
            raise ValueError("Use a standalone moon.mod project without a moon.work workspace.")
        if output.suffix.lower() != ".zip":
            raise ValueError("--output must end in .zip.")
        manifest = read_manifest(project)
        icon = read_icon(project)
        wasm = build(project, arguments.offline)
        write_package(output, manifest, wasm, icon)
    except (OSError, ValueError, RecursionError, subprocess.TimeoutExpired, zipfile.BadZipFile) as error:
        print(f"Plugin packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Created {output} ({output.stat().st_size} bytes)")
    print("Build and package checks passed. App import performs authoritative manifest and runtime validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
