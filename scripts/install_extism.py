#!/usr/bin/env python3
"""Fetch the pinned macOS plugin runtime into .tools; never install globally.

Returned binaries retain their upstream install name/signature. Packaging must
copy, rewrite the install name to @rpath/libextism.dylib, then sign the copy.
"""
import argparse
import hashlib
import platform
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "1.41.0"
HEADER_SHA256 = "69a790998bc21a3bbdcbb02dc7d1c4862b62edab60b98139831eacea21e5ca1e"
RUNTIMES = {
    "aarch64-apple-darwin": {
        "archive": "a6b1bcdecea3fcb0bcb20908a992d32e4c1f714683d15771735eaa7ef47d6aae",
        "library": "6ea6a864e95b3e550675c98f6eb17b43cefe7d815ab6010a24b213762e0c646d",
        "bytes": 23826656,
    },
    "x86_64-apple-darwin": {
        "archive": "163769b36ffee26a3e1f8fe1cc695bd2d9d83deb1d8fc728dfa20dedce87e2cf",
        "library": "ad73e82c425ca0d8bb99da1a7595f57e4246b2c427dc00fd0f3e7dfa0e6d3ab9",
        "bytes": 27311184,
    },
}
# These two notices cover Extism and its engine, not all transitive dependencies.
NOTICES = {
    "extism-1.41.0-LICENSE": (
        "https://raw.githubusercontent.com/extism/extism/v1.41.0/LICENSE",
        "d01e60805075b591cbecc63b8582788e54e190f699037f1af19fb5294b7a47ab"),
    "wasmtime-49.0.0-LICENSE": (
        "https://raw.githubusercontent.com/bytecodealliance/wasmtime/v49.0.0/LICENSE",
        "268872b9816f90fd8e85db5a28d33f8150ebb8dd016653fb39ef1f94f2686bc5"),
}


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def verified(path, expected):
    return path.is_file() and digest(path) == expected


def fetch_verified(url, destination, expected, candidates, maximum):
    for candidate in [destination, *candidates]:
        if verified(candidate, expected):
            return candidate
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix="extism-download-", dir=destination.parent, delete=False) as target:
        temporary = Path(target.name)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "MoojiCut-build/1"})
            with urllib.request.urlopen(request, timeout=60) as source:
                total = 0
                while chunk := source.read(1024*1024):
                    total += len(chunk)
                    if total > maximum:
                        raise RuntimeError("Extism download exceeds its size limit")
                    target.write(chunk)
            target.flush()
            if digest(temporary) != expected:
                raise RuntimeError("Extism download checksum mismatch: " + destination.name)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
    return destination


def install(arch=None):
    aliases = {"arm64": "aarch64-apple-darwin", "aarch64": "aarch64-apple-darwin",
               "x86_64": "x86_64-apple-darwin", "amd64": "x86_64-apple-darwin"}
    arch = arch or platform.machine().lower()
    target = aliases.get(arch, arch)
    if target not in RUNTIMES:
        raise RuntimeError("Unsupported Extism macOS architecture: " + arch)
    runtime = RUNTIMES[target]
    destination = ROOT / ".tools" / ("extism-" + VERSION) / target
    expected_files = {"extism.h": HEADER_SHA256, "libextism.dylib": runtime["library"],
                      **{name: item[1] for name, item in NOTICES.items()}}
    if all(verified(destination / name, expected) for name, expected in expected_files.items()):
        return destination
    cache = ROOT / ".tools/extism-download"
    filename = "libextism-{}-v{}.tar.gz".format(target, VERSION)
    evaluation = ROOT / ".artifacts/plugin-evaluation"
    candidates = [evaluation / "platforms" / target / filename]
    if target == "aarch64-apple-darwin":
        candidates.append(evaluation / "extism-runtime/archive.tar.gz")
    archive = fetch_verified(
        "https://github.com/extism/extism/releases/download/v{}/{}".format(VERSION, filename),
        cache / filename, runtime["archive"], candidates, 64*1024*1024)
    notices = {name: fetch_verified(url, cache/name, checksum, [evaluation/"platforms"/name], 64*1024)
               for name, (url, checksum) in NOTICES.items()}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="extism-stage-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive, "r:gz") as package:
            # Copy only known regular members; never extract paths or symlinks.
            for name, size in [("extism.h", 11013), ("libextism.dylib", runtime["bytes"])]:
                matches = [m for m in package.getmembers() if m.name.removeprefix("./") == name]
                if len(matches) != 1 or not matches[0].isfile() or matches[0].size != size:
                    raise RuntimeError("Unexpected Extism archive member: " + name)
                with package.extractfile(matches[0]) as source, (staging/name).open("wb") as output:
                    shutil.copyfileobj(source, output)
                if not verified(staging/name, expected_files[name]):
                    raise RuntimeError("Extism extracted file checksum mismatch: " + name)
        for name, source in notices.items():
            shutil.copyfile(source, staging/name)
        (staging/".archive-sha256").write_text(runtime["archive"] + "\n")
        if destination.exists():
            raise RuntimeError("Modified/incomplete Extism installation exists: " + str(destination))
        staging.rename(destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64", *RUNTIMES])
    print(install(parser.parse_args().arch))
