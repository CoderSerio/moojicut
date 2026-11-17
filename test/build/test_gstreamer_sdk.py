"""Private SDK preparation cannot publish partial or machine-resolved installs."""

import copy
from contextlib import redirect_stdout
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import install_gstreamer as sdk


class GStreamerSDKTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="gstreamer test ")
        self.addCleanup(self.directory.cleanup)
        # Windows TEMP may use an 8.3 alias (RUNNER~1); verification reports
        # canonical paths, so fixture expectations use the same real directory.
        self.root = Path(self.directory.name).resolve()
        self.package = copy.deepcopy(sdk.load_lock())

    def archive(self):
        archive = self.root / "verified.exe"
        archive.write_bytes(b"fixture installer")
        self.package.update(bytes=archive.stat().st_size, sha256=sdk.digest(archive))
        return archive

    def fixture_sdk(self):
        home = self.root / "sdk"
        for relative in self.package["required_files"] + ["lib/" + x for x in self.package["link_libraries"]]:
            path = home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        for name in self.package["required_license_dirs"]:
            path = home / "share/licenses" / name / "COPYING"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Fixture license", encoding="utf-8")
        plugin = home / "lib/gstreamer-1.0/gstfixture.dll"
        plugin.parent.mkdir(parents=True, exist_ok=True)
        plugin.touch()
        return home, plugin

    def plugin_output(self, plugin, version=None, module="gst-plugins-base"):
        expected = self.package.get("component_versions", {}).get(module, self.package["version"])
        return ("Plugin Details:\n  Name fixture\n  Filename " + str(plugin) +
                "\n  Version " + (version or expected) + "\n  License LGPL\n  Source module " + module + "\n")

    def factory_output(self, plugin, factory):
        module = "gst-plugins-base"
        if factory in {"nlecomposition", "gesdemux"}:
            module = "gst-editing-services"
        elif factory == "queue":
            module = "gstreamer"
        elif factory in {"pitch", "h264parse", "openh264enc", "mfh264enc"}:
            module = "gst-plugins-bad"
        return self.plugin_output(plugin, module=module)

    def test_installer_is_portable_and_never_sets_machine_or_ci_environment(self):
        command = sdk.installer_command("verified.exe", self.root / "sdk path", self.root / "install.log")
        for required in ("/PORTABLE=1", "/CURRENTUSER", "/TASKS=", "/NOICONS", "/TYPE=devel", "/NORESTART"):
            self.assertIn(required, command)
        self.assertNotIn("/ALLUSERS", command)
        self.assertIn("/DIR=" + str(self.root / "sdk path"), command)
        original = {"PATH": "machine-untrusted", "SystemRoot": "C:/Windows", "GST_PLUGIN_PATH": "external",
                    "GST_PLUGIN_PATH_1_0": "another", "GST_PLUGIN_FEATURE_RANK": "avenc_aac:999",
                    "GITHUB_ENV": "do-not-write", "GSTREAMER_ROOT_X86_64": "old SDK"}
        environment = sdk.sdk_environment(self.root, original)
        self.assertEqual(original["PATH"], "machine-untrusted")
        self.assertNotIn("machine-untrusted", environment["PATH"])
        self.assertNotIn("GST_PLUGIN_FEATURE_RANK", environment)
        self.assertNotIn("GST_PLUGIN_PATH", environment)
        self.assertNotIn("GSTREAMER_ROOT_X86_64", environment)
        self.assertEqual(environment["GST_PLUGIN_PATH_1_0"], "")
        self.assertTrue(environment["GST_REGISTRY_1_0"].startswith(str(self.root.resolve())))

    def test_download_rejects_wrong_hash_and_never_promotes_partial_content(self):
        payload = b"incorrect installer"
        self.package.update(bytes=len(payload), sha256="0" * 64)
        cache = self.root / "cache"
        with patch.object(sdk, "urlopen", return_value=io.BytesIO(payload)):
            with self.assertRaisesRegex(ValueError, "SHA256"):
                sdk.download(self.package, cache)
        self.assertEqual(list(cache.iterdir()), [])
        self.package["sha256"] = hashlib.sha256(payload).hexdigest()
        with patch.object(sdk, "urlopen", return_value=io.BytesIO(payload)):
            downloaded = sdk.download(self.package, cache)
        self.assertEqual(downloaded.read_bytes(), payload)
        downloaded.write_bytes(b"damaged")
        with self.assertRaisesRegex(ValueError, "Cached SDK checksum"):
            sdk.download(self.package, cache)
        self.assertEqual(downloaded.read_bytes(), b"damaged")

    def test_install_checks_digest_before_execution_and_preserves_existing_destination(self):
        archive = self.archive()
        self.package["sha256"] = "0" * 64
        with patch.object(sdk, "run") as execute:
            with self.assertRaisesRegex(ValueError, "unverified"):
                sdk.install(self.root / "sdk", archive, self.package, execute=execute)
            execute.assert_not_called()
        self.package["sha256"] = sdk.digest(archive)
        home = self.root / "sdk"
        home.mkdir()
        (home / "existing").write_text("keep", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            sdk.install(home, archive, self.package)
        self.assertEqual((home / "existing").read_text(), "keep")

    def test_failure_during_verification_never_publishes_sdk(self):
        archive = self.archive()
        home = self.root / "sdk"
        def execute(command):
            stage = Path(next(item[5:] for item in command if item.startswith("/DIR=")))
            stage.mkdir()
            (stage / "partial").touch()
        def reject(stage, package):
            self.assertTrue((stage / "partial").exists())
            raise ValueError("missing real GES library")
        with self.assertRaisesRegex(ValueError, "missing real GES"):
            sdk.install(home, archive, self.package, execute=execute, verify=reject)
        self.assertFalse(home.exists())
        self.assertEqual(list(self.root.glob(".gstreamer-sdk-*")), [])
        self.assertTrue(archive.exists())

    def test_relocated_sdk_is_reverified_and_failure_removes_only_new_install(self):
        archive = self.archive()
        home = self.root / "sdk"
        def execute(command):
            Path(next(item[5:] for item in command if item.startswith("/DIR="))).mkdir()
        verified = []
        def verify(path, package):
            verified.append(path)
            if path == home:
                raise ValueError("stale staging plugin path")
            return {"verified": True}
        with self.assertRaisesRegex(ValueError, "stale staging"):
            sdk.install(home, archive, self.package, execute=execute, verify=verify)
        self.assertEqual(len(verified), 2)
        self.assertFalse(home.exists())
        self.assertTrue(archive.exists())
        verified.clear()
        def success(path, package):
            verified.append(path)
            return {"verified": True}
        sdk.install(home, archive, self.package, execute=execute, verify=success)
        self.assertEqual(verified[-1], home)
        self.assertTrue((home / sdk.REPORT).is_file())

    def test_plugin_discovery_rejects_external_or_wrong_version_libraries(self):
        home, plugin = self.fixture_sdk()
        metadata = sdk.plugin_metadata(self.plugin_output(plugin), home, self.package)
        self.assertEqual(metadata["Filename"], "lib/gstreamer-1.0/gstfixture.dll")
        with self.assertRaisesRegex(ValueError, "outside"):
            sdk.plugin_metadata(self.plugin_output(self.root / "machine-plugin.dll"), home, self.package)
        with self.assertRaisesRegex(ValueError, "expected version"):
            sdk.plugin_metadata(self.plugin_output(plugin, "1.20.0"), home, self.package)

    def test_actual_component_patches_are_locked_without_relaxing_other_plugins(self):
        home, plugin = self.fixture_sdk()
        for module in ("gstreamer", "gst-editing-services", "gst-plugins-base", "gst-plugins-good", "gst-plugins-bad", "gst-libav"):
            actual = self.plugin_output(plugin, "1.28.8.1", module).replace("\n", "\r\n")
            self.assertEqual(sdk.plugin_metadata(actual, home, self.package)["Version"], "1.28.8.1")
        for version, module in (("1.28.8", "gst-editing-services"),
                                ("1.28.8.10", "gst-editing-services"),
                                ("1.28.8.10", "gst-plugins-bad"),
                                ("1.28.8.10", "gst-plugins-base"),
                                ("1.28.8.1", "unlocked-module")):
            with self.subTest(version=version, module=module), self.assertRaisesRegex(ValueError, "expected version"):
                sdk.plugin_metadata(self.plugin_output(plugin, version, module), home, self.package)

    def test_verification_collects_all_factory_failures_and_still_runs_available_abi_probe(self):
        home, plugin = self.fixture_sdk()
        calls, output = [], io.StringIO()
        def execute(command, **kwargs):
            calls.append(command)
            if command[0] == "cl":
                return "compiled"
            if str(command[0]).endswith("sdk-probe.exe"):
                return "GStreamer ABI 1.28.8.1\nGES 1.28.8.1\nGES headers 1.28.8.1\nlibav ABI 61 61 59; mov demux/mp4 mux available\n"
            query = command[-1]
            if query == "--version":
                return "GStreamer 1.28.8\n"
            if query == "nlecomposition":
                return self.plugin_output(plugin, "1.28.8.10", "gst-editing-services")
            if query == "appsink":
                return self.plugin_output(self.root / "foreign.dll")
            if query == "pitch":
                return self.plugin_output(plugin, module="gst-plugins-bad").replace("License LGPL", "License ")
            return self.factory_output(plugin, query)
        with redirect_stdout(output), self.assertRaises(ValueError) as raised:
            sdk.verify_sdk(home, self.package, execute=execute)
        for factory in ("nlecomposition", "appsink", "pitch"):
            self.assertIn("SDK factory " + factory, str(raised.exception))
        for factory in self.package["required_factories"]:
            self.assertTrue(any(command[-1] == factory for command in calls), factory)
        for candidates in self.package["encoder_alternatives"].values():
            for candidate in candidates:
                self.assertTrue(any(command[-1] == candidate for command in calls), candidate)
        self.assertIn("SDK ABI probe:\nGStreamer ABI 1.28.8.1", output.getvalue())
        self.assertFalse((home / sdk.REPORT).exists())

    def test_verification_reports_all_missing_inputs_and_actual_license_directories(self):
        home, plugin = self.fixture_sdk()
        absent = ["include/gstreamer-1.0/ges/ges.h", "include/libavformat/avformat.h"]
        for relative in absent:
            (home / relative).unlink()
        for name in ("soundtouch", "ffmpeg"):
            (home / "share/licenses" / name / "COPYING").unlink()
        calls, output = [], io.StringIO()
        def execute(command, **kwargs):
            calls.append(command)
            if command[-1] == "--version":
                return "GStreamer 1.28.8\n"
            return self.factory_output(plugin, command[-1])
        with redirect_stdout(output), self.assertRaises(ValueError) as raised:
            sdk.verify_sdk(home, self.package, execute=execute)
        for relative in absent:
            self.assertIn(str(home / relative), str(raised.exception))
        for name in ("soundtouch", "ffmpeg"):
            self.assertIn(str(home / "share/licenses" / name), str(raised.exception))
        self.assertIn("SDK license directories: ffmpeg, gst-editing-services-1.0, gstreamer-1.0, soundtouch", output.getvalue())
        self.assertIn("SDK ABI probe unavailable", output.getvalue())
        self.assertFalse(any(command[0] == "cl" for command in calls))

    def test_compile_and_runtime_probe_are_required_and_license_inventory_is_recorded(self):
        home, plugin = self.fixture_sdk()
        calls = []
        probe_version = self.package["component_versions"]["gst-editing-services"]
        def execute(command, **kwargs):
            calls.append((command, kwargs))
            if command[0] == "cl":
                self.assertIn("/MD", command)
                self.assertIn("/WX", command)
                self.assertIn("ges-1.0.lib", command)
                self.assertIn("avformat.lib", command)
                self.assertNotIn("env", kwargs)  # retain the MSVC developer shell for compilation only
                return "compiled"
            self.assertNotIn("machine-untrusted", kwargs["env"]["PATH"])
            if str(command[0]).endswith("sdk-probe.exe"):
                return "GStreamer ABI 1.28.8.1\nGES " + probe_version + "\nlibav ABI 61 61 59; mov demux/mp4 mux available\n"
            if command[-1] == "--version":
                return "GStreamer " + self.package["version"] + "\n"
            return self.factory_output(plugin, command[-1])
        report = sdk.verify_sdk(home, self.package, execute=execute)
        self.assertFalse(report["redistribution_approved"])
        self.assertEqual(set(report["encoder_candidates"]), {"h264", "aac"})
        self.assertTrue(report["factories"]["nlecomposition"])
        self.assertEqual(len(report["licenses"]), len(self.package["required_license_dirs"]))
        self.assertTrue(any(command[0] == "cl" for command, _ in calls))
        self.assertTrue(any(str(command[0]).endswith("sdk-probe.exe") for command, _ in calls))
        self.assertEqual(report["factories"]["nlecomposition"]["Version"], "1.28.8.1")
        probe_version = "1.28.8.10"
        with self.assertRaisesRegex(ValueError, "Wrong GES ABI/runtime version"):
            sdk.verify_sdk(home, self.package, execute=execute)

    def test_missing_codec_or_nonportable_install_is_rejected(self):
        home, plugin = self.fixture_sdk()
        candidates = {name for names in self.package["encoder_alternatives"].values() for name in names}
        def execute(command, **kwargs):
            if command[-1] == "--version":
                return "GStreamer " + self.package["version"]
            if command[-1] in candidates:
                raise RuntimeError("factory unavailable")
            return self.factory_output(plugin, command[-1])
        with self.assertRaisesRegex(ValueError, "encoder"):
            sdk.verify_sdk(home, self.package, execute=execute)
        (home / "unins000.exe").touch()
        with self.assertRaisesRegex(ValueError, "portable"):
            sdk.verify_sdk(home, self.package, execute=execute)


if __name__ == "__main__":
    unittest.main()
