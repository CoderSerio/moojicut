#!/usr/bin/env python3
"""Fetch the pinned target plugin SDK into .tools; never install globally.

Returned binaries retain their upstream bytes. Packaging must copy them before
rewriting/signing. Windows CRT deployment and full transitive notices remain the
packager's responsibility; this SDK includes the pinned Extism/Wasmtime notices.
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
        "files": {"libextism.dylib": (23826656, "6ea6a864e95b3e550675c98f6eb17b43cefe7d815ab6010a24b213762e0c646d")},
    },
    "x86_64-apple-darwin": {
        "archive": "163769b36ffee26a3e1f8fe1cc695bd2d9d83deb1d8fc728dfa20dedce87e2cf",
        "files": {"libextism.dylib": (27311184, "ad73e82c425ca0d8bb99da1a7595f57e4246b2c427dc00fd0f3e7dfa0e6d3ab9")},
    },
    "x86_64-pc-windows-msvc": {
        "archive": "cb64724d56313e8089e90416e1181e38000698270d7856ef821d1b85bfc2e23b",
        "files": {
            "extism.dll": (22519296, "83d7e76a24e97f964bd7b9f525b1abb66fe979600b3a648e54f468ab70037481"),
            "extism.dll.lib": (11322, "fd21845bf84a6f690b3dad02926f14d23d0a5753f32fe819b8401783f97ee949"),
        },
    },
    "x86_64-unknown-linux-gnu": {
        "archive": "753cef478c853556212f6ad64b6e98adbc8b7908931c54b79678bb7c1fb2643b",
        "files": {"libextism.so": (30811880, "44eb7ed56c6b5610b97b9aa62a436e6ff7e3175730e487c42bb67105185d7e01")},
    },
}
# These notices cover Extism and its engine, not all transitive dependencies.
# Preserve the existing Mac notice filename/API. The audited Windows/Linux
# binaries expose Wasmtime 49.0.2 symbols; both license revisions have the same
# pinned bytes, but the new targets use the actual engine version in their name.
NOTICES = {
    "extism-1.41.0-LICENSE": (
        "https://raw.githubusercontent.com/extism/extism/v1.41.0/LICENSE",
        "d01e60805075b591cbecc63b8582788e54e190f699037f1af19fb5294b7a47ab"),
    "wasmtime-49.0.0-LICENSE": (
        "https://raw.githubusercontent.com/bytecodealliance/wasmtime/v49.0.0/LICENSE",
        "268872b9816f90fd8e85db5a28d33f8150ebb8dd016653fb39ef1f94f2686bc5"),
    "wasmtime-49.0.2-LICENSE": (
        "https://raw.githubusercontent.com/bytecodealliance/wasmtime/v49.0.2/LICENSE",
        "268872b9816f90fd8e85db5a28d33f8150ebb8dd016653fb39ef1f94f2686bc5"),
}


def resolve_target(arch=None):
    # Explicit legacy architecture aliases retain their macOS meaning. New
    # cross-build callers should pass a complete target triple.
    aliases = {"arm64": "aarch64-apple-darwin", "aarch64": "aarch64-apple-darwin",
               "x86_64": "x86_64-apple-darwin", "amd64": "x86_64-apple-darwin"}
    if arch is None:
        machine, system = platform.machine().lower(), platform.system()
        if system == "Windows" and machine in ("amd64", "x86_64"):
            arch = "x86_64-pc-windows-msvc"
        elif system == "Linux" and machine in ("amd64", "x86_64"):
            arch = "x86_64-unknown-linux-gnu"
        elif system == "Darwin":
            arch = machine
        else:
            raise RuntimeError("Unsupported Extism host: " + system + "/" + machine)
    target = aliases.get(arch.lower(), arch.lower())
    if target not in RUNTIMES:
        raise RuntimeError("Unsupported Extism target: " + arch)
    return target


def notice_names(target=None):
    target = resolve_target(target)
    engine = "49.0.0" if target.endswith("-apple-darwin") else "49.0.2"
    return ("extism-" + VERSION + "-LICENSE", "wasmtime-" + engine + "-LICENSE")


def runtime_files(target=None):
    """Only selected SDK files: filename -> (exact byte length, SHA-256)."""
    target = resolve_target(target)
    return {"extism.h": (11013, HEADER_SHA256), **RUNTIMES[target]["files"]}


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def verified(path, expected):
    return not path.is_symlink() and path.is_file() and digest(path) == expected


def fetch_verified(url, destination, expected, candidates, maximum):
    for candidate in [destination, *candidates]:
        if (not candidate.is_symlink() and candidate.is_file() and
                candidate.stat().st_size <= maximum and verified(candidate, expected)):
            return candidate
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix="extism-download-", dir=destination.parent, delete=False) as target:
            temporary = Path(target.name)
            request = urllib.request.Request(url, headers={"User-Agent": "MoojiCut-build/1"})
            with urllib.request.urlopen(request, timeout=60) as source:
                total = 0
                while chunk := source.read(1024*1024):
                    total += len(chunk)
                    if total > maximum:
                        raise RuntimeError("Extism download exceeds its size limit")
                    target.write(chunk)
        # On Windows the download handle must be closed before reopening it for
        # verification or atomically replacing the cache entry.
        if digest(temporary) != expected:
            raise RuntimeError("Extism download checksum mismatch: " + destination.name)
        temporary.replace(destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

    return destination


def installation_verified(destination, members, notices, archive_hash):
    try:
        if destination.is_symlink() or not destination.is_dir():
            return False
        expected = {**{name: checksum for name, (_, checksum) in members.items()},
                    **{name: NOTICES[name][1] for name in notices}}
        if set(path.name for path in destination.iterdir()) != set(expected) | {".archive-sha256"}:
            return False
        if any((destination/name).stat().st_size != size for name, (size, _) in members.items()):
            return False
        if not all(verified(destination/name, checksum) for name, checksum in expected.items()):
            return False
        receipt = destination/".archive-sha256"
        return (not receipt.is_symlink() and receipt.is_file() and
                receipt.read_text(encoding="ascii") == archive_hash + "\n")
    except (OSError, UnicodeError):
        return False


def install(arch=None):
    target = resolve_target(arch)
    runtime = RUNTIMES[target]
    members = runtime_files(target)
    names = notice_names(target)
    destination = ROOT / ".tools" / ("extism-" + VERSION) / target
    if destination.exists() or destination.is_symlink():
        if installation_verified(destination, members, names, runtime["archive"]):
            return destination
        raise RuntimeError("Modified/incomplete Extism installation exists: " + str(destination))
    cache = ROOT / ".tools/extism-download"
    filename = "libextism-{}-v{}.tar.gz".format(target, VERSION)
    evaluation = ROOT / ".artifacts/plugin-evaluation"
    audit = ROOT / ".artifacts/d1a/extism"
    candidates = [audit/filename, evaluation / "platforms" / target / filename]
    if target == "aarch64-apple-darwin":
        candidates.append(evaluation / "extism-runtime/archive.tar.gz")
    archive = fetch_verified(
        "https://github.com/extism/extism/releases/download/v{}/{}".format(VERSION, filename),
        cache / filename, runtime["archive"], candidates, 64*1024*1024)
    notices = {name: fetch_verified(NOTICES[name][0], cache/name, NOTICES[name][1],
                                   [audit/"upstream"/name, evaluation/"platforms"/name], 64*1024)
               for name in names}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="extism-stage-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive, "r:gz") as package:
            # Copy only known regular members; never extract paths, links, the
            # large static runtime or SDK discovery files into a runtime cache.
            for name, (size, checksum) in members.items():
                matches = [m for m in package.getmembers() if m.name.removeprefix("./") == name]
                if len(matches) != 1 or not matches[0].isfile() or matches[0].size != size:
                    raise RuntimeError("Unexpected Extism archive member: " + name)
                with package.extractfile(matches[0]) as source, (staging/name).open("wb") as output:
                    shutil.copyfileobj(source, output)
                if not verified(staging/name, checksum):
                    raise RuntimeError("Extism extracted file checksum mismatch: " + name)
        for name, source in notices.items():
            shutil.copyfile(source, staging/name)
        (staging/".archive-sha256").write_text(runtime["archive"] + "\n", encoding="ascii")
        if not installation_verified(staging, members, names, runtime["archive"]):
            raise RuntimeError("Staged Extism installation verification failed")
        if destination.exists() or destination.is_symlink():
            raise RuntimeError("Extism installation appeared during staging: " + str(destination))
        staging.rename(destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", "--target", dest="arch", choices=["arm64", "x86_64", *RUNTIMES])
    print(install(parser.parse_args().arch))
