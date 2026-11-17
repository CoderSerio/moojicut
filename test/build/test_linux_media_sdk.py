"""Source integrity, private discovery and all-or-nothing Linux SDK setup.

Runtime compilation/factory/ABI checks are intentionally performed by the
installer on Linux CI, not simulated as evidence of a functioning media SDK.
"""

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import install_linux_gstreamer as sdk


class LinuxMediaSDKTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="linux sdk test ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.lock = copy.deepcopy(sdk.load_lock())

    def archive(self, entries=None):
        archive = self.root / "source.tar.gz"
        entries = entries or [("source/configure", b"#!/bin/sh\n", None)]
        with tarfile.open(archive, "w:gz") as tar:
            for name, data, link in entries:
                info = tarfile.TarInfo(name)
                info.mode = 0o4755
                if link is not None:
                    info.type = tarfile.SYMTYPE
                    info.linkname = link
                    tar.addfile(info)
                else:
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
        package = {"root": "source", "version": "1", "archive": "source.tar.gz",
                   "url": "https://example.invalid/source.tar.gz", "bytes": archive.stat().st_size,
                   "sha256": sdk.digest(archive), "max_unpacked_bytes": 4096}
        return archive, package

    def test_lock_uses_lgpl_shared_minimal_sources_and_explicit_plugins(self):
        options = set(self.lock["ffmpeg_options"])
        for flag in ("--enable-shared", "--disable-static", "--disable-autodetect", "--disable-gpl",
                     "--disable-nonfree", "--disable-version3", "--disable-programs", "--disable-network",
                     "--disable-protocols", "--disable-everything", "--enable-avfilter",
                     "--enable-encoder=aac", "--enable-decoder=aac,h264", "--enable-muxer=mov,mp4"):
            self.assertIn(flag, options)
        for source in self.lock["sources"].values():
            self.assertRegex(source["sha256"], "^[a-f0-9]{64}$")
            self.assertGreater(source["bytes"], 100000)
            self.assertTrue(source["url"].startswith("https://"))
        options = set(self.lock["meson_options"])
        for flag in ("auto_features=disabled", "glib_checks=true", "glib_assert=true", "glib_debug=enabled",
                     "gpl=disabled", "orc-source=system", "orc=enabled", "gst-plugins-good:ximagesrc=enabled",
                     "gst-plugins-good:pulse=enabled", "gst-plugins-bad:openh264=enabled"):
            self.assertIn(flag, options)
        self.assertIn("pipewiresrc", self.lock["required_factories"])
        self.assertIn("ximagesrc", self.lock["required_factories"])
        for name in ("gstopenh264enc.cpp", "gstopenh264dec.cpp", "gstopenh264plugin.c"):
            self.assertIn("subprojects/gst-plugins-bad/ext/openh264/" + name, self.lock["licenses"]["gstreamer"])

    def test_download_verifies_cache_and_never_promotes_partial_or_bad_payload(self):
        archive, package = self.archive()
        payload = archive.read_bytes()
        cache = self.root / "cache"
        wrong = dict(package, sha256="0" * 64)
        with patch.object(sdk, "urlopen", return_value=io.BytesIO(payload)):
            with self.assertRaisesRegex(ValueError, "SHA256"):
                sdk.download(wrong, cache)
        self.assertEqual(list(cache.iterdir()), [])
        with patch.object(sdk, "urlopen", return_value=io.BytesIO(payload + b"extra")):
            with self.assertRaisesRegex(ValueError, "exceeds"):
                sdk.download(package, cache)
        self.assertEqual(list(cache.iterdir()), [])
        with patch.object(sdk, "urlopen", return_value=io.BytesIO(payload)):
            target = sdk.download(package, cache)
        target.write_bytes(b"cache corruption")
        with patch.object(sdk, "urlopen") as network:
            with self.assertRaisesRegex(ValueError, "SHA256"):
                sdk.download(package, cache)
            network.assert_not_called()

    def test_tar_rejects_traversal_links_and_link_ancestor_before_any_write(self):
        cases = [
            [("source/../../escape", b"x", None)],
            [("/source/absolute", b"x", None)],
            [("source/link", b"", "../../escape")],
            [("source/link", b"", "target"), ("source/link/file", b"x", None)],
            [("source/file", b"1", None), ("source/file", b"2", None)],
        ]
        for entries in cases:
            with self.subTest(entries=entries):
                archive, package = self.archive(entries)
                destination = self.root / "extract"
                with self.assertRaises(ValueError):
                    sdk.unpack(archive, destination, package)
                self.assertFalse(destination.exists())
        self.assertFalse((self.root / "escape").exists())

    def test_tar_preserves_internal_document_link_and_strips_privileged_bits(self):
        archive, package = self.archive([("source/a", b"a", None), ("source/link", b"", "a")])
        source = sdk.unpack(archive, self.root / "extract", package)
        self.assertEqual((source / "link").read_bytes(), b"a")
        self.assertEqual((source / "a").stat().st_mode & 0o7777, 0o755)
        with self.assertRaisesRegex(ValueError, "existing"):
            sdk.unpack(archive, self.root / "extract", package)

    def test_environment_keeps_gtk_context_but_removes_other_media_installations(self):
        original = {"PATH": "/venv/bin:/usr/bin", "DISPLAY": ":99", "DBUS_SESSION_BUS_ADDRESS": "bus",
                    "GST_PLUGIN_PATH": "bad", "GST_PLUGIN_FEATURE_RANK": "bad", "LD_LIBRARY_PATH": "old",
                    "LD_PRELOAD": "bad", "PKG_CONFIG_LIBDIR": "old", "GST_ENV": "old"}
        environment = sdk.sdk_environment(self.root, original)
        self.assertEqual(environment["DISPLAY"], ":99")
        self.assertEqual(environment["DBUS_SESSION_BUS_ADDRESS"], "bus")
        self.assertEqual(environment["LD_LIBRARY_PATH"], str(self.root / "lib"))
        self.assertEqual(environment["GST_PLUGIN_SYSTEM_PATH_1_0"], str(self.root / "lib/gstreamer-1.0"))
        self.assertEqual(environment["GST_PLUGIN_PATH_1_0"], "")
        for name in ("GST_PLUGIN_PATH", "GST_ENV", "LD_PRELOAD", "PKG_CONFIG_LIBDIR", "GST_PLUGIN_FEATURE_RANK"):
            self.assertNotIn(name, environment)
        self.assertEqual(original["LD_LIBRARY_PATH"], "old")

    def test_plugin_bsd_is_allowed_but_empty_license_never_consumes_next_field(self):
        plugin = self.root / "lib/gstreamer-1.0/libgstopenh264.so"
        plugin.parent.mkdir(parents=True)
        plugin.touch()
        output = ("Plugin Details:\n  Name openh264\n  Filename " + str(plugin) +
                  "\n  Version 1.28.9\n  License BSD\n  Source module gst-plugins-bad\n")
        self.assertEqual(sdk.plugin_metadata(output, self.root, self.lock)["License"], "BSD")
        for bad in (output.replace("License BSD", "License "), output.replace("License BSD", "License GPL"),
                    output.replace("Version 1.28.9", "Version 1.20.3")):
            with self.assertRaisesRegex(ValueError, "version/license"):
                sdk.plugin_metadata(bad, self.root, self.lock)
        outside = output.replace(str(plugin), str(self.root.parent / "outside.so"))
        with self.assertRaisesRegex(ValueError, "outside"):
            sdk.plugin_metadata(outside, self.root, self.lock)

    def fixture_install(self):
        archive, package = self.archive()
        lock = copy.deepcopy(self.lock)
        lock["sources"] = {"fixture": package}
        home = self.root / "sdk"
        def build(home, sources, work, lock, jobs, execute):
            self.assertEqual((sources["fixture"] / "configure").read_bytes(), b"#!/bin/sh\n")
            (home / "payload").write_text("built", encoding="utf-8")
        def verify(home, lock, **kwargs):
            return {"prefix": str(home), "lock_sha256": sdk.digest(sdk.LOCK),
                    "configuration_sha256": sdk.configuration_digest(lock), "files": sdk.inventory(home)}
        return archive, lock, home, build, verify

    def test_failed_new_build_removes_only_its_prefix_and_publishes_no_receipt(self):
        archive, lock, home, build, verify = self.fixture_install()
        sibling = self.root / "keep"
        sibling.write_text("user data", encoding="utf-8")
        def reject(*args, **kwargs):
            raise ValueError("real ABI failed")
        with patch.object(sdk, "download", return_value=archive):
            with self.assertRaisesRegex(ValueError, "real ABI"):
                sdk.install(home, self.root / "cache", lock, build=build, verify=reject)
        self.assertFalse(home.exists())
        self.assertEqual(sibling.read_text(), "user data")
        self.assertEqual(list(self.root.glob(".linux-media-build-*")), [])

    def test_success_publishes_receipt_last_and_reuse_does_not_rebuild(self):
        archive, lock, home, build, verify = self.fixture_install()
        def verified(home, lock, **kwargs):
            self.assertFalse((home / sdk.REPORT).exists())
            self.assertFalse(kwargs["require_receipt"])
            return verify(home, lock, **kwargs)
        with patch.object(sdk, "download", return_value=archive):
            sdk.install(home, self.root / "cache", lock, build=build, verify=verified)
        saved = json.loads((home / sdk.REPORT).read_text())
        self.assertEqual(saved["files"], sdk.inventory(home))
        with patch.object(sdk, "download") as download, patch.object(sdk, "build_sdk") as rebuild:
            self.assertEqual(sdk.install(home, self.root / "cache", lock, verify=verify), saved)
            download.assert_not_called()
            rebuild.assert_not_called()

    def test_invalid_existing_prefix_is_preserved_not_adopted(self):
        home = self.root / "sdk"
        home.mkdir()
        (home / "keep").write_text("do not remove", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "receipt"):
            sdk.install(home, self.root / "cache")
        self.assertEqual((home / "keep").read_text(), "do not remove")

    def test_cache_hash_and_lock_mismatch_fail_before_running_binaries(self):
        archive, lock, home, build, verify = self.fixture_install()
        with patch.object(sdk, "download", return_value=archive):
            sdk.install(home, self.root / "cache", lock, build=build, verify=verify)
        (home / "payload").write_text("corrupt", encoding="utf-8")
        with patch.object(sdk, "run") as execute:
            with self.assertRaisesRegex(ValueError, "hash inventory"):
                sdk.verify_sdk(home, lock, execute=execute)
            execute.assert_not_called()
        receipt = json.loads((home / sdk.REPORT).read_text())
        receipt["lock_sha256"] = "0" * 64
        (home / sdk.REPORT).write_text(json.dumps(receipt), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "configuration"):
            sdk.verify_sdk(home, lock)

    def test_inventory_records_library_symlinks_but_rejects_external_payload(self):
        home = self.root / "sdk"
        (home / "lib").mkdir(parents=True)
        (home / "lib/libavcodec.so.61.1").write_bytes(b"elf")
        (home / "lib/libavcodec.so.61").symlink_to("libavcodec.so.61.1")
        (home / "include/libavcodec").mkdir(parents=True)
        (home / "include/libavcodec/avcodec.h").write_text("header", encoding="utf-8")
        entries = {x["path"]: x for x in sdk.inventory(home)}
        self.assertEqual(entries["lib/libavcodec.so.61"]["symlink"], "libavcodec.so.61.1")
        self.assertEqual(entries["lib/libavcodec.so.61.1"]["component"], "ffmpeg")
        self.assertEqual(entries["include/libavcodec/avcodec.h"]["component"], "ffmpeg")
        (home / "lib/external").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(ValueError, "external or dangling"):
            sdk.inventory(home)

    def test_build_commands_forbid_fallback_and_keep_pipewire_system_client(self):
        home, work = self.root / "sdk", self.root / "build"
        home.mkdir(); work.mkdir()
        sources = {}
        for name, licenses in self.lock["licenses"].items():
            sources[name] = self.root / name
            for relative in licenses:
                file = sources[name] / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("upstream license", encoding="utf-8")
        commands = []
        def execute(command, **kwargs):
            commands.append(list(map(str, command)))
            return ""
        with patch.object(sdk, "tool_environment", return_value=({"meson": "/venv/meson", "ninja": "/venv/ninja"}, {})):
            sdk.build_sdk(home, sources, work, self.lock, 2, execute)
        setup = next(x for x in commands if x[:2] == ["/venv/meson", "setup"] and str(work / "gst-build") in x)
        self.assertIn("--wrap-mode=nofallback", setup)
        self.assertIn("--libdir=lib", setup)
        self.assertIn("--libexecdir=libexec", setup)
        self.assertTrue(any("libpipewire-0.3" in x for x in commands))
        plugin = next(x for x in commands if "-shared" in x)
        self.assertEqual(sum(item.endswith(".c") for item in plugin), 8)
        self.assertIn(str(home / "lib/gstreamer-1.0/libgstpipewire.so"), plugin)
        self.assertFalse(any("sudo" in x for x in commands))


if __name__ == "__main__":
    unittest.main()
