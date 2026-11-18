"""Pinned SDK/cache boundaries; target binaries are never executed here."""

import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import install_extism as sdk


def checksum(data):
    return hashlib.sha256(data).hexdigest()


class ExtismInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="extism sdk test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root_patch = patch.object(sdk, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.network = patch.object(sdk.urllib.request, "urlopen", side_effect=AssertionError("unexpected network"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def patched(self, context):
        result = context.start()
        self.addCleanup(context.stop)
        return result

    def archive(self, target, mutation=None):
        """Locally pinned tiny upstream fixture, including unwanted static SDK files."""
        payloads = {"extism.h": b"fixture header\n"}
        for name in sdk.RUNTIMES[target]["files"]:
            payloads[name] = (name + " fixture\n").encode()
        members = {name: (len(data), checksum(data)) for name, data in payloads.items()}
        audit = self.root / ".artifacts/d1a/extism"
        audit.mkdir(parents=True, exist_ok=True)
        archive = audit / ("libextism-" + target + "-v" + sdk.VERSION + ".tar.gz")
        with tarfile.open(archive, "w:gz") as package:
            for name, data in payloads.items():
                entry = tarfile.TarInfo("./" + name)
                entry.size = len(data)
                if mutation and name != "extism.h":
                    mutation(entry)
                package.addfile(entry, io.BytesIO(data) if entry.isfile() else None)
            for name in ("libextism.a", "../unselected-path"):
                entry = tarfile.TarInfo(name)
                entry.size = 7
                package.addfile(entry, io.BytesIO(b"ignored"))
        runtime = {"archive": sdk.digest(archive), "files": {}}
        self.patched(patch.dict(sdk.RUNTIMES, {target: runtime}))
        self.patched(patch.object(sdk, "runtime_files", return_value=members))
        notices = {}
        for name in sdk.notice_names(target):
            data = (name + " official fixture\n").encode()
            path = audit / "upstream" / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(data)
            notices[name] = ("https://example.invalid/" + name, checksum(data))
        self.patched(patch.dict(sdk.NOTICES, notices))
        return members, archive

    def test_target_detection_and_legacy_mac_notice_api(self):
        self.assertEqual(sdk.resolve_target("arm64"), "aarch64-apple-darwin")
        self.assertEqual(sdk.resolve_target("x86_64"), "x86_64-apple-darwin")
        self.assertEqual(sdk.notice_names("x86_64")[-1], "wasmtime-49.0.0-LICENSE")
        for system, machine, target in (
            ("Windows", "AMD64", "x86_64-pc-windows-msvc"),
            ("Linux", "x86_64", "x86_64-unknown-linux-gnu"),
            ("Darwin", "arm64", "aarch64-apple-darwin"),
        ):
            with self.subTest(system=system), patch.object(sdk.platform, "system", return_value=system), \
                    patch.object(sdk.platform, "machine", return_value=machine):
                self.assertEqual(sdk.resolve_target(), target)
                self.assertIn("extism.h", sdk.runtime_files())
        with patch.object(sdk.platform, "system", return_value="Linux"), \
                patch.object(sdk.platform, "machine", return_value="aarch64"):
            with self.assertRaisesRegex(RuntimeError, "Unsupported"):
                sdk.install()

    def test_windows_sdk_minimal_verified_cache(self):
        self.install_and_reuse("x86_64-pc-windows-msvc")

    def test_linux_sdk_minimal_verified_cache(self):
        self.install_and_reuse("x86_64-unknown-linux-gnu")

    def test_mac_sdk_keeps_legacy_cache_layout(self):
        self.install_and_reuse("aarch64-apple-darwin", "arm64")

    def install_and_reuse(self, target, alias=None):
        members, _ = self.archive(target)
        result = sdk.install(alias or target)
        self.assertEqual(result, self.root / ".tools" / ("extism-" + sdk.VERSION) / target)
        self.assertEqual({p.name for p in result.iterdir()},
                         set(members) | set(sdk.notice_names(target)) | {".archive-sha256"})
        before = {p.name: (p.stat().st_mtime_ns, p.read_bytes()) for p in result.iterdir()}
        with patch.object(sdk, "fetch_verified", side_effect=AssertionError("cache must not fetch")):
            self.assertEqual(sdk.install(alias or target), result)
        self.assertEqual(before, {p.name: (p.stat().st_mtime_ns, p.read_bytes()) for p in result.iterdir()})
        self.assertFalse((result.parent / "unselected-path").exists())

    def test_modified_or_incomplete_install_is_never_overwritten(self):
        target = "x86_64-pc-windows-msvc"
        self.archive(target)
        result = sdk.install(target)
        for name, data in (("extism.dll", b"corrupt"),
                           (sdk.notice_names(target)[0], b"changed notice"),
                           (".archive-sha256", b"\xff"), ("unexpected.dll", b"injected")):
            with self.subTest(name=name):
                path = result / name
                original = path.read_bytes() if path.exists() else None
                path.write_bytes(data)
                with patch.object(sdk, "fetch_verified", side_effect=AssertionError("must reject before fetching")), \
                        self.assertRaisesRegex(RuntimeError, "Modified/incomplete"):
                    sdk.install(target)
                self.assertEqual(path.read_bytes(), data)
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_selected_archive_symlink_rejected_without_publishing(self):
        target = "x86_64-unknown-linux-gnu"
        def make_link(entry):
            entry.type, entry.size, entry.linkname = tarfile.SYMTYPE, 0, "../../outside"
        self.archive(target, make_link)
        with self.assertRaisesRegex(RuntimeError, "Unexpected Extism archive member"):
            sdk.install(target)
        parent = self.root / ".tools" / ("extism-" + sdk.VERSION)
        self.assertEqual(list(parent.iterdir()), [])

    def test_selected_archive_checksum_rejected_without_publishing(self):
        target = "x86_64-unknown-linux-gnu"
        members, _ = self.archive(target)
        size, _ = members["libextism.so"]
        members["libextism.so"] = (size, "0" * 64)
        with self.assertRaisesRegex(RuntimeError, "extracted file checksum"):
            sdk.install(target)
        self.assertEqual(list((self.root / ".tools" / ("extism-" + sdk.VERSION)).iterdir()), [])

    def test_download_closed_before_verification_and_replace(self):
        destination = self.root / "download" / "runtime.tar.gz"
        payload = b"verified upstream bytes"
        handles = []
        real_temporary, real_digest, real_replace = tempfile.NamedTemporaryFile, sdk.digest, Path.replace
        def temporary(*args, **kwargs):
            handle = real_temporary(*args, **kwargs)
            handles.append(handle)
            return handle
        def closed_digest(path):
            self.assertTrue(handles[-1].closed)
            return real_digest(path)
        def closed_replace(path, target):
            self.assertTrue(handles[-1].closed)
            return real_replace(path, target)
        with patch.object(sdk.urllib.request, "urlopen", return_value=io.BytesIO(payload)), \
                patch.object(sdk.tempfile, "NamedTemporaryFile", side_effect=temporary), \
                patch.object(sdk, "digest", side_effect=closed_digest), \
                patch.object(Path, "replace", closed_replace):
            self.assertEqual(sdk.fetch_verified("https://example.invalid/sdk", destination,
                                               checksum(payload), [], 1024), destination)
        self.assertEqual(destination.read_bytes(), payload)
        self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_failed_download_preserves_cache_and_cleans_temporary(self):
        destination = self.root / "runtime.tar.gz"
        destination.write_bytes(b"prior cache")
        for payload, maximum, error in ((b"wrong checksum", 100, "checksum mismatch"),
                                         (b"oversized", 4, "size limit")):
            with self.subTest(error=error), patch.object(sdk.urllib.request, "urlopen", return_value=io.BytesIO(payload)):
                with self.assertRaisesRegex(RuntimeError, error):
                    sdk.fetch_verified("https://example.invalid/sdk", destination, checksum(b"valid"), [], maximum)
                self.assertEqual(destination.read_bytes(), b"prior cache")
                self.assertEqual(list(self.root.iterdir()), [destination])


if __name__ == "__main__":
    unittest.main()
