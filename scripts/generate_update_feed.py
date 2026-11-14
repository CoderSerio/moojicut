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
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

from install_sparkle import ROOT, install


def generate(archive, output, previous=None, signing_input=None):
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
        signing_options = ["--ed-key-file", "-"] if signing_input is not None else ["--account", "dev.moojicut.native"]
        subprocess.run([str(sparkle / "bin/generate_appcast"), *signing_options,
                        "--maximum-deltas", "0", "--versions", info["CFBundleVersion"],
                        "--download-url-prefix", prefix, "--link", "https://github.com/CoderSerio/moojicut",
                        "-o", str(feed), str(staging)], input=signing_input, check=True)
        # Use the full preview label in the UI; Apple's bundle short version is numeric.
        namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        ET.register_namespace("sparkle", namespace)
        tree = ET.parse(feed)
        for item in tree.findall("./channel/item"):
            if item.findtext("{" + namespace + "}version") == info["CFBundleVersion"]:
                item.find("title").text = "Mooji Cut " + version
                item.find("{" + namespace + "}shortVersionString").text = version
        tree.write(feed, encoding="utf-8", xml_declaration=True)
        signer = [str(sparkle / "bin/sign_update"), *signing_options]
        subprocess.run([*signer, str(feed)], input=signing_input, check=True)
        subprocess.run(["xcrun", "swift", str(ROOT / "scripts/verify_update.swift"),
                        str(ROOT / "native/macos/updates/feed.json"), str(feed), str(archive)], check=True)
        shutil.copy2(feed, output)
    print("Signed update feed:", output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--key-stdin", action="store_true",
                        help="Read the existing signing key from stdin; never write it to a file or command argument.")
    args = parser.parse_args()
    signing_input = None
    if args.key_stdin:
        import base64
        signing_input = sys.stdin.buffer.read(1024).strip()
        try:
            if len(base64.b64decode(signing_input, validate=True)) not in (32, 96):
                raise ValueError("Invalid signing key format")
        except (ValueError, base64.binascii.Error):
            sys.exit("Invalid signing key format on stdin.")
        signing_input += b"\n"
    generate(args.archive.resolve(), args.output.resolve(), args.previous.resolve() if args.previous else None,
             signing_input=signing_input)
