#!/usr/bin/env python3
"""Fetch the pinned macOS updater; binaries stay outside Git in .tools/."""

import hashlib
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "2.10.1"
SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
DESTINATION = ROOT / ".tools" / ("sparkle-" + VERSION)


def install():
    marker = DESTINATION / ".archive-sha256"
    if marker.is_file() and marker.read_text().strip() == SHA256:
        return DESTINATION
    cache = ROOT / ".tools/sparkle-download"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ("Sparkle-" + VERSION + ".tar.xz")
    if not archive.is_file():
        url = "https://github.com/sparkle-project/Sparkle/releases/download/{}/{}".format(VERSION, archive.name)
        temporary = archive.with_suffix(".download")
        with urllib.request.urlopen(url, timeout=120) as source, temporary.open("wb") as target:
            shutil.copyfileobj(source, target)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Sparkle archive checksum mismatch; remove the cached archive and retry.")
    with tempfile.TemporaryDirectory(prefix="sparkle-", dir=cache) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive) as package:
            members = [member for member in package.getmembers()
                       if member.name.removeprefix("./").startswith(("Sparkle.framework/", "bin/"))
                       or member.name.removeprefix("./") == "LICENSE"]
            package.extractall(staging, members=members, filter="data")
        (staging / ".archive-sha256").write_text(SHA256 + "\n")
        if DESTINATION.exists():
            raise RuntimeError("Incomplete Sparkle installation exists: " + str(DESTINATION))
        shutil.copytree(staging, DESTINATION, symlinks=True)
    return DESTINATION


if __name__ == "__main__":
    print(install())
