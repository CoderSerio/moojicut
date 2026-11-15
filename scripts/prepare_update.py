#!/usr/bin/env python3
"""Verify a signed macOS update and stage immutable GitHub Release assets.

No app is launched, installed or registered. No release or signing key is changed.
The installed application is read only to verify continuity of its identity.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Mooji Cut.app"
BUNDLE_ID = "dev.moojicut.native"
INSTALL_PATH = Path("/Applications") / APP_NAME
REPOSITORY = "https://github.com/CoderSerio/moojicut"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def version_values(version):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.([1-9]\d{0,2}))?", version)
    require(match is not None, "Unsupported release version: " + version)
    major, minor, patch, stage, serial = match.groups()
    require(not serial or int(serial) <= 255, "Prerelease number must be at most 255.")
    short = ".".join((major, minor, patch))
    bundle = short + ({"alpha": "a", "beta": "b", "rc": "fc"}[stage] + serial if stage else "")
    order = (int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, "rc": 2, None: 3}[stage], int(serial or 0))
    return short, bundle, order


def validate_info(info, public_key):
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected application bundle ID.")
    require(info.get("MoojiCutBuildProfile", "production") == "production" and
            info.get("MoojiCutDefaultsDomain", "dev.mooncap.native.preferences") == "dev.mooncap.native.preferences",
            "A test profile cannot be delivered as a production update.")
    require(info.get("SUPublicEDKey") == public_key, "Application update public key does not match feed.json.")
    require(info.get("SURequireSignedFeed") is True and info.get("SUVerifyUpdateBeforeExtraction") is True,
            "Application must verify both feed and archive signatures.")
    version = info.get("MoojiCutReleaseVersion", "")
    short, bundle, order = version_values(version)
    require(info.get("CFBundleVersion") == bundle and info.get("CFBundleShortVersionString") == short,
            "Release and bundle versions disagree.")
    return version, order


def read_archive(archive, public_key, expected_commit):
    require(re.fullmatch(r"[0-9a-f]{40}", expected_commit) is not None, "Expected commit must be a full SHA.")
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        require(len(names) == len(set(names)), "Archive contains duplicate entries.")
        for entry in package.infolist():
            path = PurePosixPath(entry.filename)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in entry.filename,
                    "Unsafe archive path.")
            require(path.parts and path.parts[0] in (APP_NAME, "__MACOSX"), "Unexpected archive root.")
            if stat.S_ISLNK(entry.external_attr >> 16):
                require(entry.file_size < 4096, "Unexpected archive symlink.")
                target = package.read(entry).decode("utf-8")
                resolved = PurePosixPath(posixpath.normpath(str(path.parent / target)))
                require(not target.startswith("/") and resolved.parts and resolved.parts[0] == path.parts[0],
                        "Archive symlink escapes its bundle.")
        require(package.testzip() is None, "Archive CRC check failed.")
        info = plistlib.loads(package.read(APP_NAME + "/Contents/Info.plist"))
        metadata = json.loads(package.read(APP_NAME + "/Contents/Resources/build.json"))
    version, order = validate_info(info, public_key)
    require(archive.name == "moojicut-" + version + "-macos-arm64.zip", "Unexpected Release asset filename.")
    require(metadata.get("version") == version and metadata.get("bundleVersion") == info["CFBundleVersion"],
            "Embedded metadata and application versions disagree.")
    require(metadata.get("commit") == expected_commit and metadata.get("workingTreeDirty") is False,
            "Candidate must be a clean build of the expected commit.")
    require(metadata.get("arch") == "arm64" and metadata.get("signing") == "certificate",
            "Update delivery requires the certificate-signed arm64 candidate.")
    require(metadata.get("minimumMacOSVersion") == info.get("LSMinimumSystemVersion"),
            "Minimum macOS version differs between bundle and build metadata.")
    sidecar = archive.with_suffix(".build.json")
    recorded = json.loads(sidecar.read_text())
    require(recorded == dict(metadata, archive=archive.name, sha256=sha256(archive)),
            "Archive sidecar is stale or does not match embedded metadata/checksum.")
    return info, metadata, order


def validate_feed(feed, archive, info):
    # Either generated locally, or verified by verify_update.swift first.
    tree = ET.parse(feed)
    items = tree.findall("./channel/item")
    require(len(items) == 1, "Release feed must contain exactly this candidate, not stale or additional items.")
    item = items[0]
    expected_url = REPOSITORY + "/releases/download/v" + info["MoojiCutReleaseVersion"] + "/" + archive.name
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1 and enclosures[0].get("url") == expected_url,
            "Signed feed does not point to the exact GitHub Release archive.")
    require(item.findtext(SPARKLE + "version") == info["CFBundleVersion"] and
            item.findtext(SPARKLE + "shortVersionString") == info["MoojiCutReleaseVersion"],
            "Signed feed and archive versions disagree.")
    require(item.findtext(SPARKLE + "minimumSystemVersion") == info["LSMinimumSystemVersion"],
            "Signed feed and archive minimum macOS versions disagree.")
    require(item.findtext(SPARKLE + "hardwareRequirements") == "arm64", "Signed feed must require arm64.")
    require(not item.findall(".//" + SPARKLE + "deltas"), "Release delivery expects a full archive, not deltas.")
    return expected_url


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ValueError("{} failed: {}".format(args[0], result.stderr.strip()))
    return result.stdout + result.stderr


def code_identity(app, certificate_prefix):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    details = run("/usr/bin/codesign", "-d", "--verbose=4", app)
    require("Signature=adhoc" not in details and "TeamIdentifier=not set" not in details,
            "Ad-hoc application identity cannot be used for update delivery.")
    team = re.search(r"^TeamIdentifier=(.+)$", details, re.M)
    require(team is not None, "Application has no signing Team ID.")
    requirement = run("/usr/bin/codesign", "-d", "-r-", app)
    match = re.search(r"^designated => (.+)$", requirement, re.M)
    require(match is not None, "Application has no designated requirement.")
    run("/usr/bin/codesign", "-d", "--extract-certificates=" + str(certificate_prefix), app)
    certificate = Path(str(certificate_prefix) + "0")
    require(certificate.is_file(), "Application has no signing certificate.")
    return {"teamID": team.group(1), "certificateSHA256": sha256(certificate), "requirement": match.group(1)}


def verify_requirement(app, requirement):
    # codesign treats a bare -R value as a filename. The leading '=' selects
    # literal requirement source; subprocess passes it without shell quoting.
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, app)


def prepare(archive, feed, output, expected_commit):
    config = json.loads((ROOT / "native/macos/updates/feed.json").read_text())
    require(INSTALL_PATH.is_dir() and not INSTALL_PATH.is_symlink(),
            "Keep exactly one installed application at /Applications/Mooji Cut.app (not a symlink).")
    installed_info = plistlib.loads((INSTALL_PATH / "Contents/Info.plist").read_bytes())
    installed_version, installed_order = validate_info(installed_info, config["publicKey"])
    require(not output.exists(), "Output already exists; use a new delivery directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Hidden scratch space is never launched or passed to LaunchServices. Delete
    # the extracted production-identity app before creating the deliverable.
    with tempfile.TemporaryDirectory(prefix=".update-check-", suffix=".noindex", dir=output.parent) as temporary:
        scratch = Path(temporary)
        staged = scratch / "delivery"
        staged.mkdir()
        for source, name in ((archive, archive.name), (feed, "macos.xml"),
                             (archive.with_suffix(".build.json"), archive.with_suffix(".build.json").name)):
            shutil.copy2(source, staged / name)
        archive, feed = staged / archive.name, staged / "macos.xml"
        info, metadata, candidate_order = read_archive(archive, config["publicKey"], expected_commit)
        require(candidate_order > installed_order, "Update must be newer than the installed application.")
        run("xcrun", "swift", ROOT / "scripts/verify_update.swift",
            ROOT / "native/macos/updates/feed.json", feed, archive)
        download_url = validate_feed(feed, archive, info)
        run("/usr/bin/ditto", "-x", "-k", archive, scratch / "extracted")
        candidate = scratch / "extracted" / APP_NAME
        require(run("/usr/bin/lipo", "-archs", candidate / "Contents/MacOS/MoojiCut").strip() == "arm64",
                "Candidate executable architecture does not match the release asset.")
        installed_identity = code_identity(INSTALL_PATH, scratch / "installed-cert")
        candidate_identity = code_identity(candidate, scratch / "candidate-cert")
        require(installed_identity == candidate_identity,
                "Candidate must use the installed app's existing certificate and designated requirement.")
        verify_requirement(candidate, installed_identity["requirement"])
        shutil.rmtree(scratch / "extracted")
        (staged / (archive.name + ".sha256")).write_text(sha256(archive) + "  " + archive.name + "\n")
        assets = [{"name": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
                  for path in sorted(staged.iterdir())]
        plan = {"schemaVersion": 1, "repository": REPOSITORY, "tag": "v" + metadata["version"],
                "commit": expected_commit, "fromVersion": installed_version, "version": metadata["version"],
                "installationPath": str(INSTALL_PATH), "bundleID": BUNDLE_ID, "identity": candidate_identity,
                "downloadURL": download_url, "feedURL": download_url.rsplit("/", 1)[0] + "/macos.xml",
                "notarized": metadata.get("notarized") is True, "assets": assets,
                "verified": ["clean-source-metadata", "archive-integrity", "feed-and-archive-ed25519",
                             "exact-release-url-and-version", "same-installed-certificate-and-requirement"],
                "published": False, "installed": False, "realUpgradeTested": False}
        (staged / "delivery.json").write_text(json.dumps(plan, indent=2, ensure_ascii=False) + "\n")
        staged.rename(output)
    return plan


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-commit", required=True)
    args = parser.parse_args()
    try:
        plan = prepare(args.archive.resolve(), args.feed.resolve(), args.output.resolve(), args.expected_commit)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ET.ParseError, subprocess.TimeoutExpired) as error:
        parser.exit(1, "Update delivery not ready: " + str(error) + "\n")
    print("Verified update assets:", args.output.resolve())
    print("{} → {}; not published or installed.".format(plan["fromVersion"], plan["version"]))
