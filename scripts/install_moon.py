#!/usr/bin/env python3
"""Install the pinned MoonBit toolchain into a supplied CI directory."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen
import zipfile

VERSION = "0.10.20+65efd5b93"
URL_VERSION = VERSION.replace("+", "%2B")
# Toolchain checksums are published by MoonBit; core checksums were verified
# from the matching fixed-version archives on the same official HTTPS origin.
PACKAGES = {
    "win32": (
        ("binaries/" + URL_VERSION + "/moonbit-windows-x86_64.zip",
         "bdff9a3b2d7c61a3adae2fe09221d3de63effc6cab28bfa0cbeb94fb0d529d79", ""),
        ("cores/core-" + URL_VERSION + ".zip",
         "d7982eed233e0c4f933f566274cc9777466447e0d5b633006e8bf18975c7c833", "lib"),
    ),
    "linux": (
        ("binaries/" + URL_VERSION + "/moonbit-linux-x86_64.tar.gz",
         "80d987523308fa490eba9f1baf98df996a5a7891e118357553b7c2608c0597c5", ""),
        ("cores/core-" + URL_VERSION + ".tar.gz",
         "8ec2a2c01335501d703867bb4eef5f92d3cd7e1ae1ee5f7f14d54d16d2c7c2b5", "lib"),
    ),
}


def main():
    if len(sys.argv) != 2 or sys.platform not in PACKAGES:
        sys.exit("Usage on Windows/Linux x64: python scripts/install_moon.py DESTINATION")
    home = Path(sys.argv[1]).resolve()
    if home.exists() and any(home.iterdir()):
        sys.exit("Refusing to overwrite a nonempty MoonBit toolchain directory.")
    home.mkdir(parents=True, exist_ok=True)
    for relative, expected, subdir in PACKAGES[sys.platform]:
        url = "https://cli.moonbitlang.com/" + relative
        print("Downloading", url, flush=True)
        with urlopen(url, timeout=120) as response:
            data = response.read()
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            sys.exit("SHA256 mismatch for " + relative)
        destination = home / subdir
        destination.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryFile() as archive:
            archive.write(data)
            archive.seek(0)
            if relative.endswith(".zip"):
                with zipfile.ZipFile(archive) as package:
                    for name in package.namelist():
                        if not (destination / name).resolve().is_relative_to(destination):
                            sys.exit("Unsafe archive path: " + name)
                    package.extractall(destination)
            else:
                with tarfile.open(fileobj=archive) as package:
                    package.extractall(destination, filter="data")
    moon = home / "bin" / ("moon.exe" if sys.platform == "win32" else "moon")
    if sys.platform != "win32":
        for executable in (home / "bin").iterdir():
            if executable.is_file():
                executable.chmod(executable.stat().st_mode | 0o111)
    env = dict(os.environ, MOON_HOME=str(home))
    subprocess.run([str(moon), "version", "--all"], env=env, check=True)
    subprocess.run([str(moon), "-C", str(home / "lib/core"), "bundle", "--warn-list", "-a", "--all"],
                   env=env, check=True)
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            output.write("MOON_HOME=" + str(home) + "\n")
        with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as output:
            output.write(str(home / "bin") + "\n")
    print("Installed MoonBit", VERSION, "at", home, flush=True)


if __name__ == "__main__":
    main()
