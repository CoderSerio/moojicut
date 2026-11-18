#!/usr/bin/env python3
"""Run the unchanged Ubuntu 22 release and fixture binaries on another Linux.

This file intentionally imports only the Python standard library. It neither
builds code nor locates an SDK. Run inside xvfb-run/dbus-run-session on the
target machine; display/session variables are retained, media SDK variables
are removed. The fixture kit is CI evidence, never part of a user download.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

import plugin_worker_fixture

FIXTURES = ("gst-media", "mp4-mux", "media-worker", "media-waveform", "video-editor-host", "video-editor",
            "plugin-worker-host")
SAMPLE_PATH = "samples/capture-info.zip"
PRODUCT_SAMPLE_PATH = "samples/numbered-box.zip"
SAMPLE_PATHS = (SAMPLE_PATH, PRODUCT_SAMPLE_PATH)
CHECK_COUNT = 9
MAX_ARCHIVE_BYTES = 1024 * 1024 * 1024
MAX_UNPACKED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024


def sha256(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while block := stream.read(1024 * 1024):
            value.update(block)
    return value.hexdigest()


def regular_file(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular file: " + str(path))
    return path


def commit_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("Expected a full lowercase Git commit SHA")
    return value


def read_json(path):
    path = regular_file(path)
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("JSON exceeds the metadata size limit")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate metadata key: " + key)
            result[key] = value
        return result
    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("Expected a metadata object")
    return value


def verify_release(package_path, commit):
    commit_id(commit)
    package = regular_file(package_path).resolve()
    if not package.name.endswith(".tar.gz") or package.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("Expected a bounded Linux .tar.gz package")
    metadata = read_json(package.with_name(package.name[:-7] + ".build.json"))
    if (metadata.get("commit") != commit or metadata.get("platform") != "linux" or
            metadata.get("arch") != "x64" or metadata.get("archive") != package.name or
            metadata.get("workingTreeDirty") is not False):
        raise ValueError("Release metadata does not match the clean Linux x64 commit/archive")
    digest = sha256(package)
    if metadata.get("sha256") != digest:
        raise ValueError("Release package SHA256 mismatch")
    return metadata


def elf_x64(path):
    path = regular_file(path)
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 62:
        raise ValueError("Expected an already compiled Linux x86_64 ELF: " + str(path))
    return path


def product_sample_contents(package_path):
    """Validate the fixed v2 app fixture without extracting or executing it.

    This is fixture identity/bounds checking, not the product's package policy;
    the unchanged application must still validate/import the entire real ZIP.
    """
    package = plugin_worker_fixture.regular_file(package_path, plugin_worker_fixture.ZIP_LIMIT)
    limits = plugin_worker_fixture.MEMBER_LIMITS
    with zipfile.ZipFile(package) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if (len(names) != len(set(names)) or set(names) not in
                ({"manifest.json", "plugin.wasm"}, set(limits))):
            raise ValueError("Expected exactly the numbered-box ZIP members")
        contents = {}
        for entry in entries:
            if (stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG) or entry.flag_bits & 1 or
                    entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) or
                    not 0 < entry.file_size <= limits[entry.filename]):
                raise ValueError("Unsupported, linked or oversized product ZIP member: " + entry.filename)
            contents[entry.filename] = archive.read(entry)
    manifest = plugin_worker_fixture.decode_json(contents["manifest.json"])
    if (not isinstance(manifest, dict) or type(manifest.get("apiVersion")) is not int or
            manifest.get("apiVersion") != 2 or
            manifest.get("pluginId") != "com.moojicut.examples.numbered-box" or
            manifest.get("entry") != "plugin.wasm" or manifest.get("runtime") != "extism-1" or
            manifest.get("tools") != [
                {"toolId": "numbered-box", "title": "编号框", "gesture": "dragRect", "effect": "capture.annotations.add"},
                {"toolId": "describe", "title": "查看尺寸", "gesture": "invoke", "effect": "result.text"},
            ]):
        raise ValueError("ZIP is not the expected packaged numbered-box v2 sample")
    if contents["plugin.wasm"][:8] != b"\0asm\1\0\0\0":
        raise ValueError("Product sample must contain core Wasm; actual execution belongs to app-smoke")


def write_fixture_kit(destination, package_path, commit, executables, plugin_fixture_path, product_fixture_path):
    """Bind existing ELF fixtures and the two distinct MoonBit ZIPs to a release.

    destination is the complete archive filename (no overwrite). executables
    is the existing directory containing the fixed names in FIXTURES.
    plugin_fixture_path is the capture-info ZIP already used by the build's
    worker checks. product_fixture_path is the numbered-box v2 ZIP used by
    app-smoke. Both are hashed as-is; no recompilation/repackaging is allowed.
    Runtime files are deliberately excluded; target tests use the release's
    exact runtime. Returns the absolute destination Path.
    """
    metadata = verify_release(package_path, commit)
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Refusing to overwrite fixture kit: " + str(destination))
    executables = Path(executables).resolve()
    files = []
    sources = {}
    for name in FIXTURES:
        binary = elf_x64(executables / name)
        if binary.stat().st_size > MAX_MEMBER_BYTES:
            raise ValueError("Fixture executable exceeds size limit")
        if os.name == "posix" and not binary.stat().st_mode & 0o111:
            raise ValueError("Fixture is not executable: " + name)
        files.append({"path": "bin/" + name, "sha256": sha256(binary), "bytes": binary.stat().st_size})
        sources["bin/" + name] = binary
    for name, source, validate in (
            (SAMPLE_PATH, plugin_fixture_path, plugin_worker_fixture.sample_contents),
            (PRODUCT_SAMPLE_PATH, product_fixture_path, product_sample_contents)):
        sample = regular_file(source)
        validate(sample)
        files.append({"path": name, "sha256": sha256(sample), "bytes": sample.stat().st_size})
        sources[name] = sample
    manifest = {"schemaVersion": 1, "platform": "linux", "arch": "x64", "commit": commit,
                "packageSha256": metadata["sha256"], "files": files}
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".fixture-kit-", suffix=".tar.gz", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with tarfile.open(temporary, "w:gz") as output:
            payload = (json.dumps(manifest, indent=2) + "\n").encode()
            info = tarfile.TarInfo("manifest.json")
            info.mode, info.size = 0o644, len(payload)
            output.addfile(info, io.BytesIO(payload))
            for entry in files:
                binary = sources[entry["path"]]
                # Read once to guarantee manifest bytes match this tar even if
                # another build replaces a fixture during kit generation.
                payload = binary.read_bytes()
                if len(payload) != entry["bytes"] or hashlib.sha256(payload).hexdigest() != entry["sha256"]:
                    raise ValueError("Fixture changed while creating kit: " + entry["path"])
                info = tarfile.TarInfo(entry["path"])
                info.mode, info.size = (0o644 if entry["path"] in SAMPLE_PATHS else 0o755), len(payload)
                output.addfile(info, io.BytesIO(payload))
        if sha256(package_path) != metadata["sha256"]:
            raise ValueError("Release changed while creating fixture kit")
        # Atomic, exclusive publication: do not overwrite a concurrently
        # created artifact after the initial existence check.
        os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def safe_unpack(archive, destination, *, kit=False):
    archive, destination = regular_file(archive), Path(destination)
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError("Archive exceeds compressed size limit")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Extraction destination must be fresh")
    allowed = {"manifest.json", "bin", "samples", *SAMPLE_PATHS, *("bin/" + name for name in FIXTURES)}
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        if len(members) > 20000:
            raise ValueError("Archive contains too many entries")
        seen, total = set(), 0
        for entry in members:
            path = PurePosixPath(entry.name)
            if (not path.parts or path.is_absolute() or ".." in path.parts or
                    "\\" in entry.name or ":" in entry.name or path in seen):
                raise ValueError("Unsafe or duplicate archive path: " + entry.name)
            if not (entry.isfile() or entry.isdir()) or entry.mode & 0o7000:
                raise ValueError("Archive links, special files and privileged modes are forbidden")
            if (kit and path.as_posix() not in allowed) or (not kit and path.parts[0] != "MoojiCut"):
                raise ValueError("Unexpected archive member: " + entry.name)
            if (entry.size < 0 or entry.size > MAX_MEMBER_BYTES):
                raise ValueError("Archive member exceeds size limit")
            total += entry.size
            if total > MAX_UNPACKED_BYTES:
                raise ValueError("Archive exceeds unpacked size limit")
            seen.add(path)
        # Catch a regular-file ancestor before any writes, not halfway through
        # extraction when an otherwise safe path becomes an I/O failure.
        regular = {PurePosixPath(entry.name) for entry in members if entry.isfile()}
        if any(parent in regular for path in seen for parent in path.parents):
            raise ValueError("Archive has a regular-file path ancestor")
        destination.mkdir(parents=True)
        for entry in members:
            path = destination / entry.name
            if entry.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(entry) as incoming, path.open("xb") as output:
                    shutil.copyfileobj(incoming, output)
                path.chmod(0o755 if entry.mode & 0o111 else 0o644)
    return destination


def verify_kit(directory, metadata, commit):
    directory = Path(directory)
    manifest = read_json(directory / "manifest.json")
    if (manifest.get("schemaVersion") != 1 or manifest.get("platform") != "linux" or
            manifest.get("arch") != "x64" or manifest.get("commit") != commit or
            manifest.get("packageSha256") != metadata["sha256"]):
        raise ValueError("Fixture kit does not match the package/commit")
    expected = {*SAMPLE_PATHS, *("bin/" + name for name in FIXTURES)}
    entries = manifest.get("files")
    if not isinstance(entries, list) or len(entries) != len(expected):
        raise ValueError("Fixture kit must contain exactly the hashed binaries and both sample ZIPs")
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("path") not in expected or entry["path"] in seen:
            raise ValueError("Invalid or duplicate fixture manifest path")
        seen.add(entry["path"])
        sample = entry["path"] in SAMPLE_PATHS
        path = regular_file(directory / entry["path"]) if sample else elf_x64(directory / entry["path"])
        if (entry.get("sha256") != sha256(path) or entry.get("bytes") != path.stat().st_size or
                (not sample and os.name == "posix" and not path.stat().st_mode & 0o111)):
            raise ValueError("Fixture hash/size/mode mismatch: " + entry["path"])
        if entry["path"] == SAMPLE_PATH:
            plugin_worker_fixture.sample_contents(path)
        elif entry["path"] == PRODUCT_SAMPLE_PATH:
            product_sample_contents(path)
    actual = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()}
    if actual != expected | {"manifest.json"}:
        raise ValueError("Fixture kit contains unlisted files")
    return manifest


def clean_environment(output, inherited=None):
    original = os.environ if inherited is None else inherited
    blocked = ("GST_", "GSTREAMER_", "LD_", "GIO_", "MOOJICUT_", "PKG_CONFIG_", "MOON", "PYTHON")
    environment = {key: value for key, value in original.items()
                   if not key.upper().startswith(blocked) and key not in
                   {"GI_TYPELIB_PATH", "GSETTINGS_SCHEMA_DIR", "LIBRARY_PATH", "G_DEBUG", "G_MESSAGES_DEBUG"}}
    profile = Path(output) / "profile"
    environment.update(PATH="/usr/bin:/bin", LC_ALL="C", LANG="C",
                       XDG_CONFIG_HOME=str(profile / "config"), XDG_DATA_HOME=str(profile / "data"),
                       XDG_CACHE_HOME=str(profile / "cache"), XDG_STATE_HOME=str(profile / "state"))
    return environment


def fixture_environment(bundle, output, name, inherited=None):
    environment = clean_environment(output, inherited)
    runtime = Path(bundle) / "runtime"
    environment.update(LD_LIBRARY_PATH=str(runtime / "lib"), GST_PLUGIN_PATH_1_0="",
                       GST_PLUGIN_SYSTEM_PATH_1_0=str(runtime / "plugins"),
                       GST_PLUGIN_SCANNER_1_0=str(runtime / "bin/gst-plugin-scanner"),
                       GST_REGISTRY_1_0=str(Path(output) / "cache" / name / "registry.bin"),
                       G_DEBUG="fatal-criticals")
    return environment


def bootstrap_environment(output, name, inherited=None):
    environment = clean_environment(output, inherited)
    invalid = str(Path(output) / "deliberately-unavailable-sdk")
    environment.update(GST_PLUGIN_PATH_1_0=invalid, GST_PLUGIN_SYSTEM_PATH_1_0=invalid,
                       GST_PLUGIN_SCANNER_1_0=invalid, GST_REGISTRY_1_0=invalid,
                       GST_REGISTRY_UPDATE="no", GST_PLUGIN_FEATURE_RANK="openh264enc:NONE,avenc_aac:NONE",
                       MOOJICUT_MEDIA_CACHE_DIR=str(Path(output) / "cache" / name),
                       MOOJICUT_X11_INPUT_SMOKE="1", MOOJICUT_SMOKE_SCREENSHOT=str(Path(output) / "app-smoke.png"))
    return environment


def run_command(command, *, env, cwd, log, timeout):
    """Preserve diagnostics on errors/timeouts and reap the whole test group."""
    started = time.monotonic()
    result = {"returncode": None, "timedOut": False}
    with Path(log).open("w", encoding="utf-8") as output:
        output.write("Command: " + json.dumps(list(map(str, command))) + "\n")
        output.flush()
        try:
            with subprocess.Popen(list(map(str, command)), cwd=cwd, env=env, stdout=output,
                                  stderr=subprocess.STDOUT, start_new_session=True) as process:
                try:
                    result["returncode"] = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    result["timedOut"] = True
                    # Production execution is Linux only. Killing the process
                    # group also reaps any plugin scanner the fixture spawned.
                    os.killpg(process.pid, signal.SIGKILL)
                    result["returncode"] = process.wait()
                    output.write("\nTIMEOUT after " + str(timeout) + " seconds\n")
        except OSError as error:
            result["error"] = str(error)
            output.write("\nEXECUTION ERROR: " + str(error) + "\n")
    result["seconds"] = round(time.monotonic() - started, 3)
    return result


def check_package(package, fixtures, output, commit, *, execute=run_command, inherited=None):
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Validation output must be a fresh directory")
    output.mkdir(parents=True)
    output = output.resolve()
    logs = output / "logs"
    logs.mkdir()
    report = {"schemaVersion": 1, "commit": commit, "platform": "linux", "result": "failed",
              "runtime": "unchanged release runtime", "checks": [], "failures": {},
              "host": {"system": platform.system(), "machine": platform.machine(), "kernel": platform.release()}}
    if sys.platform == "linux":
        try:
            report["host"]["distribution"] = platform.freedesktop_os_release()
        except OSError:
            report["host"]["distribution"] = {"error": "Cannot read os-release"}
    original_hash = None
    try:
        metadata = verify_release(package, commit)
        original_hash = metadata["sha256"]
        report["packageSha256"] = original_hash
        safe_unpack(package, output / "package")
        safe_unpack(fixtures, output / "fixtures", kit=True)
        verify_kit(output / "fixtures", metadata, commit)
        app = output / "package/MoojiCut"
        internal = read_json(app / "build.json")
        for key in ("commit", "platform", "arch", "version", "workingTreeDirty"):
            if internal.get(key) != metadata.get(key):
                raise ValueError("Packaged build.json disagrees with release metadata: " + key)
        elf_x64(app / "moojicut")
        elf_x64(app / "MoojiPluginWorker")
        elf_x64(app / "runtime/bin/gst-plugin-scanner")
        for relative in ("runtime/lib", "runtime/plugins"):
            if not (app / relative).is_dir() or not any((app / relative).iterdir()):
                raise ValueError("Release runtime is incomplete: " + relative)
        binary = output / "fixtures/bin"
        shutil.copytree(app / "runtime", binary / "runtime")
        for name in (*FIXTURES, "app-self-test", "app-smoke"):
            (output / "cache" / name).mkdir(parents=True)
        for part in ("config", "data", "cache", "state", "videos"):
            (output / "profile" / part).mkdir(parents=True, exist_ok=True)
        (output / "profile/config/user-dirs.dirs").write_text(
            'XDG_VIDEOS_DIR="' + str(output / "profile/videos") + '"\n', encoding="utf-8")
        media = output / "media"
        checks = [
            ("app-self-test", [app / "moojicut", "--self-test"], True, 120),
            ("app-smoke", [app / "moojicut", "--smoke"], True, 300),
            ("gst-media", [binary / "gst-media", media], False, 600),
            ("mp4-mux", [binary / "mp4-mux", media / "identity-raw.mp4", output / "mux"], False, 180),
            ("media-worker", [binary / "media-worker", output / "worker"], False, 600),
            ("media-waveform", [binary / "media-waveform", output / "waveform"], False, 300),
            ("video-editor-host", [binary / "video-editor-host", output / "host"], False, 600),
            ("video-editor", [binary / "video-editor", media / "generated-source.mkv", output / "editor"], True, 600),
            ("plugin-worker-host", [Path(sys.executable).resolve(), Path(plugin_worker_fixture.__file__).resolve(),
                                    "--fixture", binary / "plugin-worker-host", "--worker", app / "MoojiPluginWorker",
                                    "--package", output / "fixtures" / SAMPLE_PATH,
                                    "--output", output / "plugin-worker"], False, 90),
        ]
        for name, command, bootstrap, timeout in checks:
            # The worker must locate Extism from its own packaged RUNPATH, not
            # an SDK or the media fixtures' LD_LIBRARY_PATH.
            environment = (clean_environment(output, inherited) if name == "plugin-worker-host" else
                           bootstrap_environment(output, name, inherited) if bootstrap else
                           fixture_environment(binary, output, name, inherited))
            if name == "app-smoke":
                environment["MOOJICUT_PLUGIN_SAMPLE"] = str((output / "fixtures" / PRODUCT_SAMPLE_PATH).resolve())
            try:
                result = execute(command, env=environment, cwd=output, log=logs / (name + ".log"), timeout=timeout)
                if (name == "plugin-worker-host" and result.get("returncode") == 0 and
                        not result.get("timedOut") and not result.get("error")):
                    plugin_worker_fixture.verify_results(output / "plugin-worker")
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
                result = {"returncode": None, "error": str(error)}
                with (logs / (name + ".log")).open("a", encoding="utf-8") as log:
                    log.write("\nCHECK ERROR: " + str(error) + "\n")
            passed = result.get("returncode") == 0 and not result.get("timedOut") and not result.get("error")
            report["checks"].append({"name": name, "result": "passed" if passed else "failed", **result})
            if not passed:
                report["failures"][name] = result
            print(name + ": " + ("passed" if passed else "FAILED"), flush=True)
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        report["failures"]["validation"] = str(error)
        (logs / "validation.log").write_text(str(error) + "\n", encoding="utf-8")
    finally:
        if original_hash is not None:
            try:
                if sha256(package) != original_hash:
                    report["failures"]["package-unchanged"] = "Input package bytes changed during validation"
            except OSError as error:
                report["failures"]["package-unchanged"] = str(error)
        if len(report["checks"]) == CHECK_COUNT and not report["failures"]:
            report["result"] = "passed"
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    arguments = parser.parse_args()
    if sys.platform != "linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        parser.error("Runtime verification requires Linux x86_64")
    try:
        report = check_package(arguments.package, arguments.fixtures, arguments.output, arguments.commit)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    print("Package compatibility:", report["result"], flush=True)
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
