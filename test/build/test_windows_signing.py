import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from windows_signing import WindowsSigner


PUBLISHER = "A" * 40
VENDOR = "B" * 40


def pe(path, certificate=b""):
    dos = b"MZ" + bytes(58) + struct.pack("<I", 64)
    optional = bytearray(240)
    struct.pack_into("<H", optional, 0, 0x20B)
    struct.pack_into("<I", optional, 108, 16)
    if certificate:
        struct.pack_into("<II", optional, 144, 64 + 24 + len(optional), len(certificate))
    header = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, len(optional), 2)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(dos + header + optional + certificate)


class WindowsSigningTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tool = self.root / "signtool.exe"
        self.tool.touch()
        self.bundle = self.root / "Mooji Cut"
        self.main = self.bundle / "MoojiCut.exe"
        self.vendor = self.bundle / "runtime" / "vc.dll"
        pe(self.main)
        pe(self.vendor, b"cert-vendor")
        self.commands = []
        self.bad_vendor = False
        self.bad_timestamp = False
        self.wrong_publisher = False

    def execute(self, command, **kwargs):
        self.commands.append((command, kwargs))
        if command[1] == "verify":
            timestamped = "/tw" in command
            fail = self.bad_timestamp if timestamped else self.bad_vendor
            return subprocess.CompletedProcess(command, 2 if fail else 0, b"", b"private diagnostic")
        if command[1] == "sign":
            files = command[command.index("/sha1") + 2:]
            for name in files:
                pe(Path(name), b"cert-publisher")
            return subprocess.CompletedProcess(command, 0, b"", b"")
        files = json.loads(kwargs["input"])
        identities = []
        for name in files:
            is_vendor = Path(name) == self.vendor
            thumbprint = VENDOR if is_vendor or self.wrong_publisher else PUBLISHER
            identities.append({"signer": "CN=Test Vendor" if is_vendor else "CN=Test Publisher",
                               "thumbprint": thumbprint})
        return subprocess.CompletedProcess(command, 0, json.dumps(identities).encode(), b"")

    def signer(self):
        return WindowsSigner.from_env({"MOOJICUT_SIGNTOOL": str(self.tool),
                                       "MOOJICUT_WINDOWS_SIGN_CERT_SHA1": PUBLISHER.lower()},
                                      execute=self.execute)

    def test_explicit_credential_selection(self):
        tool = {"MOOJICUT_SIGNTOOL": str(self.tool)}
        for settings, message in [
            ({}, "Configure"),
            ({"MOOJICUT_WINDOWS_SIGN_CERT_SHA1": "invalid"}, "40-digit"),
            ({"MOOJICUT_WINDOWS_SIGN_DLIB": "dlib"}, "Configure both"),
            ({"MOOJICUT_WINDOWS_SIGN_CERT_SHA1": PUBLISHER, "MOOJICUT_WINDOWS_SIGN_DLIB": "dlib"},
             "Select one"),
        ]:
            with self.subTest(settings=settings), self.assertRaisesRegex(RuntimeError, message):
                WindowsSigner.from_env(tool | settings, execute=self.execute)
        dlib = self.root / "Azure.CodeSigning.Dlib.dll"
        metadata = self.root / "private signing.json"
        dlib.touch()
        metadata.write_text("{}")
        signer = WindowsSigner.from_env(tool | {
            "MOOJICUT_WINDOWS_SIGN_DLIB": str(dlib),
            "MOOJICUT_WINDOWS_SIGN_METADATA": str(metadata),
        }, execute=self.execute)
        self.assertEqual(signer.provider, ["/dlib", str(dlib.resolve()), "/dmdf", str(metadata.resolve())])
        self.assertIsNone(signer.thumbprint)

    def test_sign_only_unsigned_pes_and_verify_the_receipt(self):
        before = self.vendor.read_bytes()
        renamed = self.bundle / "runtime" / "backend.binary"
        pe(renamed)
        (self.bundle / "README.txt").write_text("install instructions")
        signer = self.signer()
        receipt = signer.sign_bundle(self.bundle)
        self.assertEqual(self.vendor.read_bytes(), before)
        self.assertEqual(set(receipt), {"MoojiCut.exe", "runtime/backend.binary", "runtime/vc.dll"})
        self.assertEqual(receipt["runtime/vc.dll"]["source"], "vendor")
        self.assertEqual(receipt["MoojiCut.exe"]["thumbprint"], PUBLISHER)
        self.assertTrue(receipt["runtime/backend.binary"]["timestamped"])
        commands = [command for command, _ in self.commands]
        self.assertEqual(commands[0][1:4], ["verify", "/pa", str(self.vendor)])
        self.assertEqual(commands[1][1:8], ["sign", "/fd", "SHA256", "/tr",
                                             "https://timestamp.acs.microsoft.com", "/td", "SHA256"])
        self.assertEqual(commands[2][1:4], ["verify", "/pa", "/tw"])
        signer.verify_bundle(self.bundle, receipt)
        self.main.write_bytes(self.main.read_bytes() + b"modified")
        with self.assertRaisesRegex(RuntimeError, "differs"):
            signer.verify_bundle(self.bundle, receipt)

    def test_reject_invalid_existing_signature_before_signing_anything(self):
        self.bad_vendor = True
        original = self.main.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "embedded Authenticode signatures.*exit 2") as error:
            self.signer().sign_bundle(self.bundle)
        self.assertNotIn("private diagnostic", str(error.exception))
        self.assertEqual(self.main.read_bytes(), original)
        self.assertEqual(len(self.commands), 1)

    def test_reject_unstamped_signature_or_wrong_leaf(self):
        self.bad_timestamp = True
        with self.assertRaisesRegex(RuntimeError, "timestamped Authenticode signatures"):
            self.signer().sign_bundle(self.bundle)
        pe(self.main)
        self.bad_timestamp = False
        self.wrong_publisher = True
        with self.assertRaisesRegex(RuntimeError, "selected certificate"):
            self.signer().sign_bundle(self.bundle)

    def test_reject_a_missing_receipt_entry_or_invalid_binary(self):
        signer = self.signer()
        receipt = signer.sign_bundle(self.bundle)
        del receipt["runtime/vc.dll"]
        with self.assertRaisesRegex(RuntimeError, "complete binary inventory"):
            signer.verify_bundle(self.bundle, receipt)
        (self.bundle / "bad.dll").write_bytes(b"empty")
        with self.assertRaisesRegex(RuntimeError, "Invalid PE header"):
            signer.sign_bundle(self.bundle)


if __name__ == "__main__":
    unittest.main()
