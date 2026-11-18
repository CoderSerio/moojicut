"""Target-machine validation must use the exact release and never hide failures."""

import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import linux_package_check as check

COMMIT = "a" * 40
ELF = b"\x7fELF\x02\x01" + b"\0" * 12 + b"\x3e\0"


class LinuxPackageCheckTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="linux package check ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()

    def archive(self, destination, members):
        with tarfile.open(destination, "w:gz") as archive:
            for name, data, mode in members:
                entry = tarfile.TarInfo(name)
                entry.mode, entry.size = mode, len(data)
                archive.addfile(entry, io.BytesIO(data))

    def release(self, version="1"):
        package = self.root / ("moojicut-" + version + "-linux-x64.tar.gz")
        metadata = {"commit": COMMIT, "platform": "linux", "arch": "x64", "version": version,
                    "workingTreeDirty": False}
        self.archive(package, [
            ("MoojiCut/moojicut", ELF + b"application", 0o755),
            ("MoojiCut/MoojiPluginWorker", ELF + b"worker", 0o755),
            ("MoojiCut/build.json", json.dumps(metadata).encode(), 0o644),
            ("MoojiCut/runtime/bin/gst-plugin-scanner", ELF + b"scanner", 0o755),
            ("MoojiCut/runtime/lib/libtest.so.1", ELF + b"library", 0o644),
            ("MoojiCut/runtime/plugins/libtest.so", ELF + b"plugin", 0o644),
        ])
        metadata.update(archive=package.name, sha256=check.sha256(package))
        package.with_name(package.name[:-7] + ".build.json").write_text(json.dumps(metadata), encoding="utf-8")
        return package, metadata

    def kit(self, package, name="fixtures.tar.gz"):
        directory = self.root / "compiled"
        directory.mkdir(exist_ok=True)
        for fixture in check.FIXTURES:
            path = directory / fixture
            path.write_bytes(ELF + fixture.encode())
            path.chmod(0o755)
        # Runtime/development artifacts sitting next to compiled binaries must
        # never sneak into the target-machine fixture artifact.
        (directory / "runtime").mkdir(exist_ok=True)
        (directory / "runtime/not-for-kit").write_text("not a release library", encoding="utf-8")
        sample = self.sample()
        return check.write_fixture_kit(self.root / name, package, COMMIT, directory, sample)

    def sample(self):
        sample = self.root / "capture-info.zip"
        with zipfile.ZipFile(sample, "w") as archive:
            archive.writestr("manifest.json", (ROOT / "plugins/examples/capture-info/manifest.json").read_bytes())
            # These unit tests never execute a fabricated Wasm or ELF. They
            # check package binding and orchestration; real sample execution
            # is the native fixture/target-machine gate.
            archive.writestr("plugin.wasm", b"\0asm\1\0\0\0")
        return sample

    def successful_plugin_response(self, command):
        output = Path(command[command.index("--output") + 1])
        output.mkdir()
        for filename, response in check.plugin_worker_fixture.EXPECTED.items():
            (output / filename).write_text(json.dumps(response, ensure_ascii=False), encoding="utf-8")

    def test_release_checksum_commit_and_platform_reject_before_execution(self):
        package, metadata = self.release()
        self.assertEqual(check.verify_release(package, COMMIT)["sha256"], check.sha256(package))
        with self.assertRaisesRegex(ValueError, "metadata"):
            check.verify_release(package, "b" * 40)
        path = package.with_name(package.name[:-7] + ".build.json")
        metadata["platform"] = "windows"
        path.write_text(json.dumps(metadata), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "metadata"):
            check.verify_release(package, COMMIT)
        metadata["platform"] = "linux"
        path.write_text(json.dumps(metadata), encoding="utf-8")
        package.write_bytes(package.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            check.verify_release(package, COMMIT)

    def test_kit_contains_only_fixed_binaries_and_is_bound_to_package_and_commit(self):
        package, metadata = self.release()
        kit = self.kit(package)
        with tarfile.open(kit) as archive:
            self.assertEqual(set(archive.getnames()), {"manifest.json", check.SAMPLE_PATH,
                                                       *("bin/" + x for x in check.FIXTURES)})
        directory = check.safe_unpack(kit, self.root / "unpacked", kit=True)
        manifest = check.verify_kit(directory, metadata, COMMIT)
        self.assertEqual(manifest["packageSha256"], check.sha256(package))
        other, other_metadata = self.release("2")
        with self.assertRaisesRegex(ValueError, "package/commit"):
            check.verify_kit(directory, other_metadata, COMMIT)
        with self.assertRaisesRegex(ValueError, "package/commit"):
            check.verify_kit(directory, metadata, "b" * 40)
        original = kit.read_bytes()
        with self.assertRaisesRegex(ValueError, "overwrite"):
            check.write_fixture_kit(kit, package, COMMIT, self.root / "compiled", self.root / "capture-info.zip")
        self.assertEqual(kit.read_bytes(), original)
        (directory / "bin/gst-media").write_bytes(ELF + b"tampered fixture")
        with self.assertRaisesRegex(ValueError, "hash/size"):
            check.verify_kit(directory, metadata, COMMIT)
        (directory / "bin/gst-media").write_bytes(ELF + b"gst-media")
        (directory / check.SAMPLE_PATH).write_bytes(b"different ZIP")
        with self.assertRaisesRegex(ValueError, "hash/size"):
            check.verify_kit(directory, metadata, COMMIT)

    def test_unsafe_archives_are_rejected_before_extraction(self):
        cases = ["MoojiCut/../../outside", "/MoojiCut/absolute", "MoojiCut\\outside", "other/file"]
        for index, name in enumerate(cases):
            archive = self.root / (str(index) + ".tar.gz")
            self.archive(archive, [(name, b"data", 0o644)])
            destination = self.root / ("unsafe" + str(index))
            with self.assertRaises(ValueError):
                check.safe_unpack(archive, destination)
            self.assertFalse(destination.exists())
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
            archive = self.root / "link.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                item = tarfile.TarInfo("MoojiCut/escape")
                item.type, item.linkname = kind, "../../outside"
                tar.addfile(item)
            with self.assertRaisesRegex(ValueError, "links, special"):
                check.safe_unpack(archive, self.root / "link-output")
        self.assertFalse((self.root / "outside").exists())

    def test_failed_and_timed_out_checks_are_collected_without_stopping_other_checks(self):
        package, metadata = self.release()
        kit = self.kit(package)
        original = package.read_bytes()
        calls = []
        def execute(command, **kwargs):
            name = Path(kwargs["log"]).stem
            calls.append(name)
            Path(kwargs["log"]).write_text("fixture evidence " + name, encoding="utf-8")
            environment = kwargs["env"]
            self.assertEqual(environment["PATH"], "/usr/bin:/bin")
            self.assertNotIn("MOOJICUT_LINUX_MEDIA_SDK", environment)
            self.assertNotIn("LD_PRELOAD", environment)
            self.assertNotIn("PYTHONPATH", environment)
            self.assertNotIn("PYTHONHOME", environment)
            if name == "plugin-worker-host":
                self.assertEqual(Path(command[0]), Path(sys.executable).resolve())
                self.assertEqual(Path(command[command.index("--worker") + 1]),
                                 self.root / "validation/package/MoojiCut/MoojiPluginWorker")
                self.assertEqual(Path(command[command.index("--package") + 1]),
                                 self.root / "validation/fixtures" / check.SAMPLE_PATH)
                self.assertFalse(any(key.startswith(("LD_", "GST_", "MOOJICUT_")) for key in environment))
                self.assertNotIn("G_DEBUG", environment)
                self.successful_plugin_response(command)
            elif name in ("app-self-test", "app-smoke", "video-editor"):
                self.assertNotIn("LD_LIBRARY_PATH", environment)
                self.assertNotIn("G_DEBUG", environment)
                self.assertIn("deliberately-unavailable", environment["GST_PLUGIN_SYSTEM_PATH_1_0"])
                self.assertEqual(environment["MOOJICUT_X11_INPUT_SMOKE"], "1")
            else:
                self.assertEqual(environment["G_DEBUG"], "fatal-criticals")
                self.assertEqual(Path(environment["GST_PLUGIN_SYSTEM_PATH_1_0"]),
                                 self.root / "validation/fixtures/bin/runtime/plugins")
            if name == "gst-media":
                return {"returncode": 1}
            if name == "app-smoke":
                return {"returncode": -9, "timedOut": True}
            return {"returncode": 0}
        result = check.check_package(package, kit, self.root / "validation", COMMIT, execute=execute,
                                     inherited={"PATH": "/private/sdk/bin", "LD_PRELOAD": "bad",
                                                "PYTHONHOME": "/private/sdk/python", "PYTHONPATH": "/private/sdk/modules",
                                                "MOOJICUT_LINUX_MEDIA_SDK": "/sdk", "G_DEBUG": "fatal-warnings"})
        self.assertEqual(len(calls), 9)
        self.assertEqual(result["result"], "failed")
        self.assertEqual(set(result["failures"]), {"gst-media", "app-smoke"})
        self.assertEqual(package.read_bytes(), original)
        saved = json.loads((self.root / "validation/results.json").read_text())
        self.assertEqual(saved, result)
        copied = self.root / "validation/fixtures/bin/runtime/lib/libtest.so.1"
        self.assertEqual(copied.read_bytes(), ELF + b"library")

    def test_invalid_package_never_runs_checks_and_never_reports_passed(self):
        package, metadata = self.release()
        kit = self.kit(package)
        package.write_bytes(package.read_bytes() + b"modified")
        def forbidden(*args, **kwargs):
            self.fail("An invalid package must not execute anything")
        result = check.check_package(package, kit, self.root / "validation", COMMIT, execute=forbidden)
        self.assertEqual(result["result"], "failed")
        self.assertIn("validation", result["failures"])
        self.assertEqual(result["checks"], [])

    def test_package_mutation_fails_even_if_every_process_exits_successfully(self):
        package, metadata = self.release()
        kit = self.kit(package)
        def execute(command, **kwargs):
            if Path(kwargs["log"]).stem == "video-editor":
                package.write_bytes(package.read_bytes() + b"unexpected write")
            if Path(kwargs["log"]).stem == "plugin-worker-host":
                self.successful_plugin_response(command)
            return {"returncode": 0}
        result = check.check_package(package, kit, self.root / "validation", COMMIT, execute=execute)
        self.assertEqual(len(result["checks"]), 9)
        self.assertEqual(result["result"], "failed")
        self.assertIn("package-unchanged", result["failures"])

    def test_zero_exit_with_wrong_plugin_response_cannot_pass_same_package_gate(self):
        package, metadata = self.release()
        kit = self.kit(package)
        stale = True
        def execute(command, **kwargs):
            if Path(kwargs["log"]).stem == "plugin-worker-host":
                self.successful_plugin_response(command)
                if stale:
                    output = Path(command[command.index("--output") + 1])
                    response = json.loads((output / "describe-result.json").read_text(encoding="utf-8"))
                    response["invocationId"] = "stale-invocation"
                    (output / "describe-result.json").write_text(json.dumps(response), encoding="utf-8")
            return {"returncode": 0}
        result = check.check_package(package, kit, self.root / "validation", COMMIT, execute=execute)
        self.assertEqual(len(result["checks"]), 9)
        self.assertEqual(result["result"], "failed")
        self.assertEqual(set(result["failures"]), {"plugin-worker-host"})
        self.assertIn("semantics", result["failures"]["plugin-worker-host"]["error"])
        stale = False
        good = check.check_package(package, kit, self.root / "valid-results", COMMIT, execute=execute)
        self.assertEqual(good["result"], "passed")
        self.assertEqual(len(good["checks"]), 9)

    def test_sample_archive_rejection_precedes_writes_and_json_is_strict(self):
        sample = self.sample()
        with zipfile.ZipFile(sample, "a") as archive:
            archive.writestr("../outside", b"not allowed")
        output = self.root / "plugin output"
        with self.assertRaisesRegex(ValueError, "ZIP members"):
            check.plugin_worker_fixture.prepare_sample(sample, output)
        self.assertFalse(output.exists())
        self.assertFalse((self.root / "outside").exists())
        sample = self.sample()
        original = sample.read_bytes()
        wasm = check.plugin_worker_fixture.prepare_sample(sample, output)
        self.assertEqual(wasm.read_bytes(), b"\0asm\1\0\0\0")
        self.assertEqual(sample.read_bytes(), original)
        with self.assertRaisesRegex(ValueError, "fresh"):
            check.plugin_worker_fixture.prepare_sample(sample, output)
        with self.assertRaisesRegex(ValueError, "regular file"):
            check.plugin_worker_fixture.verify_results(output)
        (output / "describe-result.json").write_text('{"apiVersion":1,"apiVersion":1}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Duplicate JSON"):
            check.plugin_worker_fixture.verify_results(output)

    @unittest.skipUnless(os.name == "posix", "Linux process-group timeout handling")
    def test_real_timeout_retains_stdout_and_failed_status(self):
        log = self.root / "timeout.log"
        result = check.run_command([sys.executable, "-u", "-c", "import time; print('before timeout'); time.sleep(5)"],
                                   env=dict(os.environ), cwd=self.root, log=log, timeout=0.2)
        self.assertTrue(result["timedOut"])
        self.assertNotEqual(result["returncode"], 0)
        self.assertIn("before timeout", log.read_text())
        self.assertIn("TIMEOUT", log.read_text())


if __name__ == "__main__":
    unittest.main()
