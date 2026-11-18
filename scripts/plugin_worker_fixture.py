#!/usr/bin/env python3
"""Run the real worker fixture against one unchanged capture-info sample ZIP.

Only the standard library is needed on a target machine. No SDK lookup, build,
Wasm substitute or production plugin import is performed here. The actual
worker validates and executes the extracted Wasm; this harness checks bounded
archive inputs and the semantic JSON returned by both sample commands.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import zipfile

ZIP_LIMIT = 8 * 1024 * 1024
MEMBER_LIMITS = {"manifest.json": 64 * 1024, "plugin.wasm": 4 * 1024 * 1024,
                 "assets/icon.png": 256 * 1024}
OUTPUT_LIMIT = 256 * 1024
EXPECTED = {
    "describe-result.json": {
        "apiVersion": 1, "invocationId": "host-description-42", "kind": "text",
        "title": "截图信息",
        "text": "尺寸：320 × 180 像素\n格式：PNG\n修订：7\n\n这里只读取当前截图的元数据，不读取图像内容。",
    },
    "copy-size-result.json": {
        "apiVersion": 1, "invocationId": "host-dimensions-43", "kind": "text",
        "title": "查看尺寸", "text": "320 × 180",
    },
}


def regular_file(path, limit):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= limit:
        raise ValueError("Expected a bounded regular file: " + str(path))
    return path


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key: " + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("Non-JSON numeric constant: " + value)


def decode_json(data):
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                      parse_constant=reject_constant)


def sample_contents(package_path):
    """Read only fixed, regular ZIP members; never use extract/extractall."""
    package = regular_file(package_path, ZIP_LIMIT)
    with zipfile.ZipFile(package) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if (len(names) != len(set(names)) or set(names) not in
                ({"manifest.json", "plugin.wasm"}, set(MEMBER_LIMITS))):
            raise ValueError("Expected exactly the capture-info ZIP members")
        contents = {}
        for entry in entries:
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if (kind not in (0, stat.S_IFREG) or entry.flag_bits & 1 or
                    entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) or
                    not 0 < entry.file_size <= MEMBER_LIMITS[entry.filename]):
                raise ValueError("Unsupported, linked or oversized sample ZIP member: " + entry.filename)
            # ZipFile checks each member's CRC while reading the bounded data.
            contents[entry.filename] = archive.read(entry)
    manifest = decode_json(contents["manifest.json"])
    if (not isinstance(manifest, dict) or type(manifest.get("apiVersion")) is not int or
            manifest.get("apiVersion") != 1 or
            manifest.get("pluginId") != "com.moojicut.examples.capture-info" or
            manifest.get("entry") != "plugin.wasm" or manifest.get("runtime") != "extism-1" or
            manifest.get("capabilities") != ["capture.metadata", "result.text"] or
            manifest.get("tools") != [
                {"toolId": "describe", "title": "截图信息", "target": "screenshot", "action": "run"},
                {"toolId": "copy-size", "title": "查看尺寸", "target": "screenshot", "action": "run"},
            ]):
        raise ValueError("ZIP is not the expected packaged capture-info sample")
    wasm = contents["plugin.wasm"]
    if wasm[:8] != b"\0asm\1\0\0\0":
        raise ValueError("Sample must contain core Wasm; actual ABI validation belongs to the worker")
    return wasm


def prepare_sample(package_path, output_directory):
    """Validate the sample ZIP and write plugin.wasm into a fresh output dir."""
    wasm = sample_contents(package_path)
    output = Path(output_directory).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Plugin fixture output must be a fresh directory")
    output.mkdir(parents=True)
    path = output.resolve() / "plugin.wasm"
    with path.open("xb") as stream:
        stream.write(wasm)
    return path


def verify_results(output_directory):
    """Reject missing, malformed or semantically wrong successful responses."""
    results = {}
    for filename, expected in EXPECTED.items():
        path = regular_file(Path(output_directory) / filename, OUTPUT_LIMIT)
        value = decode_json(path.read_bytes())
        if (not isinstance(value, dict) or type(value.get("apiVersion")) is not int or
                value != expected):
            raise ValueError("Worker returned unexpected sample semantics: " + filename)
        results[filename] = value
    return results


def run_fixture(fixture, worker, package_path, output_directory, *, environment=None, timeout=45):
    """Run actual binaries, keep diagnostics, and raise on any failed check."""
    fixture = regular_file(fixture, 256 * 1024 * 1024).resolve()
    worker = regular_file(worker, 256 * 1024 * 1024).resolve()
    if not 0 < timeout <= 300:
        raise ValueError("Fixture timeout must be between 0 and 300 seconds")
    package = regular_file(package_path, ZIP_LIMIT).resolve()
    before = hashlib.sha256(package.read_bytes()).hexdigest()
    wasm = prepare_sample(package, output_directory)
    output = wasm.parent
    command = [str(fixture), str(worker), str(wasm), str(output)]
    log_path = output / "worker-host.log"
    try:
        with log_path.open("wb") as log:
            log.write(("Command: " + json.dumps(command) + "\n").encode("utf-8"))
            log.flush()
            options = {"start_new_session": True} if os.name == "posix" else {}
            with subprocess.Popen(command, cwd=output, env=environment, stdout=log,
                                  stderr=subprocess.STDOUT, **options) as process:
                try:
                    result = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    if os.name == "posix":
                        os.killpg(process.pid, signal.SIGKILL)
                    else:
                        # The only children are this finite fixture and the
                        # trusted worker; terminate their owned process tree.
                        taskkill = Path(os.environ["SystemRoot"]) / "System32/taskkill.exe"
                        try:
                            subprocess.run([str(taskkill), "/PID", str(process.pid), "/T", "/F"],
                                           stdout=log, stderr=subprocess.STDOUT, timeout=10, check=False)
                        finally:
                            if process.poll() is None:
                                process.kill()
                    process.wait()
                    log.write(b"\nTIMEOUT waiting for plugin worker fixture\n")
                    raise RuntimeError("Plugin worker fixture timed out; see " + str(log_path))
        if result:
            raise RuntimeError("Plugin worker fixture failed (exit " + str(result) + "); see " + str(log_path))
        responses = verify_results(output)
        return {"result": "passed", "sampleSha256": before, "responses": responses}
    finally:
        if hashlib.sha256(package.read_bytes()).hexdigest() != before:
            raise ValueError("Plugin sample ZIP changed during fixture execution")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=45)
    args = parser.parse_args()
    try:
        report = run_fixture(args.fixture, args.worker, args.package, args.output, timeout=args.timeout)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        parser.exit(1, str(error) + "\n")
    # Results were decoded as strict UTF-8 above. Keep console reporting ASCII
    # so redirected Windows output also works with a legacy console code page.
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
