"""Release mixups must fail before an update is published or an app is launched."""

import copy
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from prepare_update import APP_NAME, REPOSITORY, SPARKLE, read_archive, sha256, validate_feed, version_values


class UpdateDeliveryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.commit = "a" * 40
        self.key = "fixture-public-key"
        self.version = "0.1.0-alpha.13"
        self.archive = self.directory / ("moojicut-" + self.version + "-macos-arm64.zip")
        self.info = {"CFBundleIdentifier": "dev.moojicut.native", "SUPublicEDKey": self.key,
                     "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                     "MoojiCutReleaseVersion": self.version, "CFBundleShortVersionString": "0.1.0",
                     "CFBundleVersion": "0.1.0a13", "LSMinimumSystemVersion": "26.0"}
        self.metadata = {"version": self.version, "bundleVersion": "0.1.0a13", "commit": self.commit,
                         "workingTreeDirty": False, "signing": "certificate", "arch": "arm64",
                         "minimumMacOSVersion": "26.0", "notarized": False}

    def write_archive(self, info=None, metadata=None):
        metadata = metadata or self.metadata
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr(APP_NAME + "/Contents/Info.plist", plistlib.dumps(info or self.info))
            archive.writestr(APP_NAME + "/Contents/Resources/build.json", json.dumps(metadata))
        self.archive.with_suffix(".build.json").write_text(json.dumps(dict(
            metadata, archive=self.archive.name, sha256=sha256(self.archive))))

    def write_feed(self):
        root = ET.Element("rss")
        channel = ET.SubElement(root, "channel")
        item = ET.SubElement(channel, "item")
        for name, value in (("version", "0.1.0a13"), ("shortVersionString", self.version),
                            ("minimumSystemVersion", "26.0"), ("hardwareRequirements", "arm64")):
            ET.SubElement(item, SPARKLE + name).text = value
        ET.SubElement(item, "enclosure", url=REPOSITORY + "/releases/download/v" + self.version + "/" + self.archive.name)
        feed = self.directory / "macos.xml"
        ET.ElementTree(root).write(feed)
        return feed, root, item

    def test_mixed_builds_and_changed_archives_are_rejected(self):
        self.write_archive()
        info, metadata, _ = read_archive(self.archive, self.key, self.commit)
        self.assertEqual((info, metadata), (self.info, self.metadata))
        for field, value in (("version", "0.1.0-alpha.12"), ("commit", "b" * 40),
                             ("workingTreeDirty", True), ("signing", "ad-hoc"), ("arch", "x86_64")):
            with self.subTest(field=field):
                self.write_archive(metadata=dict(self.metadata, **{field: value}))
                with self.assertRaises(ValueError):
                    read_archive(self.archive, self.key, self.commit)
        self.write_archive()
        with zipfile.ZipFile(self.archive, "a") as archive:
            archive.writestr(APP_NAME + "/Contents/Resources/late-change.txt", "changed after checksums")
        with self.assertRaisesRegex(ValueError, "sidecar"):
            read_archive(self.archive, self.key, self.commit)

    def test_wrong_identity_or_disabled_signature_verification_is_rejected(self):
        for field, value in (("CFBundleIdentifier", "dev.moojicut.test"), ("SUPublicEDKey", "another-key"),
                             ("MoojiCutBuildProfile", "smoke"), ("MoojiCutDefaultsDomain", "dev.moojicut.test.preferences"),
                             ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
                             ("CFBundleVersion", "0.1.0a12")):
            with self.subTest(field=field):
                self.write_archive(info=dict(self.info, **{field: value}))
                with self.assertRaises(ValueError):
                    read_archive(self.archive, self.key, self.commit)

    def test_signed_feed_semantics_must_match_exact_candidate(self):
        feed, _, _ = self.write_feed()
        self.assertTrue(validate_feed(feed, self.archive, self.info).endswith(self.archive.name))
        for failure in ("wrong-repo", "wrong-version", "minimum-os", "architecture", "duplicate", "extra-enclosure"):
            with self.subTest(failure=failure):
                feed, root, item = self.write_feed()
                if failure == "wrong-repo":
                    item.find("enclosure").set("url", "https://example.invalid/" + self.archive.name)
                elif failure == "wrong-version":
                    item.find(SPARKLE + "version").text = "0.1.0a12"
                elif failure == "minimum-os":
                    item.find(SPARKLE + "minimumSystemVersion").text = "11.0"
                elif failure == "architecture":
                    item.find(SPARKLE + "hardwareRequirements").text = "x86_64"
                elif failure == "duplicate":
                    root.find("channel").append(copy.deepcopy(item))
                else:
                    item.append(copy.deepcopy(item.find("enclosure")))
                ET.ElementTree(root).write(feed)
                with self.assertRaises(ValueError):
                    validate_feed(feed, self.archive, self.info)

    def test_preview_version_order_prevents_equal_or_older_update(self):
        versions = ["0.1.0-alpha.9", "0.1.0-alpha.12", "0.1.0-alpha.13", "0.1.0-beta.1", "0.1.0-rc.1", "0.1.0", "0.2.0-alpha.1"]
        values = [version_values(version)[2] for version in versions]
        self.assertEqual(values, sorted(set(values)))


@unittest.skipUnless(sys.platform == "darwin", "CryptoKit verifier is macOS-only")
class SignedFeedVerifierTest(unittest.TestCase):
    def test_real_ed25519_verifier_rejects_tampering_and_duplicate_archive(self):
        # The private key lives only in this short-lived process. Only a public
        # key, signatures and inert bytes are written; no Keychain is accessed.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = directory / "fixture.swift"
            fixture.write_text('''import Foundation
import CryptoKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let archive = Data("inert archive fixture".utf8)
try archive.write(to: directory.appendingPathComponent("candidate.zip"))
try JSONSerialization.data(withJSONObject: ["publicKey": key.publicKey.rawRepresentation.base64EncodedString()]).write(to: directory.appendingPathComponent("feed.json"))
let signature = try key.signature(for: archive).base64EncodedString()
let enclosure = "<enclosure url=\\"https://example.invalid/candidate.zip\\" length=\\"\\(archive.count)\\" sparkle:edSignature=\\"\\(signature)\\"/>"
for count in [1, 2] {
    let xml = Data(("<rss xmlns:sparkle=\\"http://www.andymatuschak.org/xml-namespaces/sparkle\\"><channel>" + String(repeating: "<item>" + enclosure + "</item>", count: count) + "</channel></rss>").utf8)
    let footer = "<!-- sparkle-signatures:\\nedSignature: \\(try key.signature(for: xml).base64EncodedString())\\nlength: \\(xml.count)\\n-->\\n"
    try (xml + Data(footer.utf8)).write(to: directory.appendingPathComponent("feed\\(count).xml"))
}
''')
            subprocess.run(["xcrun", "swift", str(fixture), str(directory)], check=True, capture_output=True, timeout=120)
            verifier = directory / "verify-update"
            subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/verify_update.swift"), "-o", str(verifier)],
                           check=True, capture_output=True, timeout=120)
            def verify(feed):
                return subprocess.run([str(verifier), str(directory / "feed.json"), str(feed), str(directory / "candidate.zip")],
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(verify(directory / "feed1.xml").returncode, 0)
            self.assertIn("exactly once", verify(directory / "feed2.xml").stderr)
            feed = directory / "feed1.xml"
            original = feed.read_bytes()
            feed.write_bytes(original.replace(b"example.invalid", b"altered.invalid"))
            self.assertIn("Feed signature mismatch", verify(feed).stderr)
            feed.write_bytes(original)
            (directory / "candidate.zip").write_bytes(b"altered archive fixture")
            self.assertIn("Archive signature mismatch", verify(feed).stderr)


if __name__ == "__main__":
    unittest.main()
