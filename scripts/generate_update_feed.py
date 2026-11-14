#!/usr/bin/env python3
"""Create and verify a signed macOS appcast from a tested release archive.

The signing key stays in the macOS Keychain. This command does not publish.
"""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

from install_sparkle import ROOT, install


def generate(archive, output, previous=None):
    sparkle = install()
    config = json.loads((ROOT / "native/macos/updates/feed.json").read_text())
    # The public verifier below detects the wrong signing key without reading
    # the private key merely to inspect its corresponding public key.
    public_key = config["publicKey"]
    with zipfile.ZipFile(archive) as package:
        info = plistlib.loads(package.read("Mooji Cut.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "dev.moojicut.native" or info.get("SUPublicEDKey") != public_key:
        raise RuntimeError("The archive has an unexpected app identity or update key.")
    version = info["MoojiCutReleaseVersion"]
    prefix = "https://github.com/CoderSerio/moojicut/releases/download/v" + urllib.parse.quote(version, safe="") + "/"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="appcast-", dir=output.parent) as directory:
        staging = Path(directory)
        shutil.copy2(archive, staging / archive.name)
        feed = staging / "macos.xml"
        if previous:
            shutil.copy2(previous, feed)
        subprocess.run([str(sparkle / "bin/generate_appcast"), "--account", "dev.moojicut.native",
                        "--maximum-deltas", "0", "--versions", info["CFBundleVersion"],
                        "--download-url-prefix", prefix, "--link", "https://github.com/CoderSerio/moojicut",
                        "-o", str(feed), str(staging)], check=True)
        # Use the full preview label in the UI; Apple's bundle short version is numeric.
        namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        ET.register_namespace("sparkle", namespace)
        tree = ET.parse(feed)
        for item in tree.findall("./channel/item"):
            if item.findtext("{" + namespace + "}version") == info["CFBundleVersion"]:
                item.find("title").text = "Mooji Cut " + version
                item.find("{" + namespace + "}shortVersionString").text = version
        tree.write(feed, encoding="utf-8", xml_declaration=True)
        signer = [str(sparkle / "bin/sign_update"), "--account", "dev.moojicut.native"]
        subprocess.run([*signer, str(feed)], check=True)
        subprocess.run(["xcrun", "swift", str(ROOT / "scripts/verify_update.swift"),
                        str(ROOT / "native/macos/updates/feed.json"), str(feed), str(archive)], check=True)
        shutil.copy2(feed, output)
    print("Signed update feed:", output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args()
    generate(args.archive.resolve(), args.output.resolve(), args.previous.resolve() if args.previous else None)
