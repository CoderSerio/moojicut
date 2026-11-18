import os
import json
import contextlib
import io
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from desktop import DesktopBuild, portable_inventory


class DesktopEnvironmentTest(unittest.TestCase):
    def test_portable_uninstall_inventory_matches_the_complete_layout(self):
        files = {"moojicut", "runtime/worker.so"}
        self.assertEqual(portable_inventory(files, {"runtime", "runtime/empty"}),
                         b"MoojiCut portable 1\nmoojicut\nruntime/\nruntime/empty/\n"
                         b"runtime/worker.so\nuninstall-manifest.txt\n")
        for paths, directories in ((files, {"runtime/empty"}),
                                   ({"../outside"}, {".."}),
                                   ({"runtime\\worker.so"}, {"runtime"})):
            with self.subTest(paths=paths, directories=directories), self.assertRaises(ValueError):
                portable_inventory(paths, directories)

    def test_timed_out_process_keeps_its_last_stdout_stderr_and_fails(self):
        build = DesktopBuild.__new__(DesktopBuild)
        build.env = dict(os.environ)
        stdout, stderr = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "run.log"
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), self.assertRaises(subprocess.TimeoutExpired):
                build.run(sys.executable, "-X", "utf8", "-u", "-c",
                          "import sys,time; print('阶段: dialog'); print('pending save',file=sys.stderr); time.sleep(10)",
                          timeout=1, log=log)
            saved = log.read_text(encoding="utf-8")
        self.assertIn("阶段: dialog", stdout.getvalue())
        self.assertIn("pending save", stderr.getvalue())
        self.assertIn("阶段: dialog", saved)
        self.assertIn("pending save", saved)
        self.assertIn("TIMEOUT", saved)

    def test_independent_window_checks_still_run_but_a_media_failure_rejects_the_build(self):
        build = DesktopBuild.__new__(DesktopBuild)
        calls = []
        def failed_media():
            calls.append("media")
            raise RuntimeError("actual media failure")
        build.media_tests = failed_media
        build.verify_binary = lambda _: calls.append("core")
        build.canvas_smoke = lambda: calls.append("canvas")
        build.video_smoke = lambda *, prepared: calls.append(("editor", prepared))
        build.plugin_worker_smoke = lambda bundle: calls.append(("plugin-worker", bundle))
        build.plugin_store_smoke = lambda: calls.append("plugin-store")
        with tempfile.TemporaryDirectory() as temporary:
            build.directory = Path(temporary)
            build.bundle = build.directory / "bundle"
            build.executable = build.directory / "app"
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, "checks failed: media"):
                build.runtime_tests()
            report = json.loads((build.directory / "runtime-checks.json").read_text())
        self.assertEqual(calls, ["media", "core", "canvas", ("editor", True), ("plugin-worker", build.bundle), "plugin-store"])
        self.assertEqual(report["result"], "failed")
        self.assertEqual(report["checks"]["video-editor"]["result"], "passed")
        self.assertEqual(report["checks"]["plugin-worker"]["result"], "passed")
        self.assertEqual(report["checks"]["plugin-store"]["result"], "passed")

    def test_packaged_app_uses_the_actual_windows_system_drive_without_sdk_paths(self):
        build = DesktopBuild.__new__(DesktopBuild)
        build.system = "windows"
        with tempfile.TemporaryDirectory() as temporary:
            build.directory = Path(temporary)
            build.env = {"SYSTEMROOT": "D:/Windows", "PATH": "untrusted-sdk-bin",
                         "GST_PLUGIN_PATH": "untrusted-sdk-plugins"}
            environment = build.app_test_environment()
        windows = Path("D:/Windows")
        self.assertEqual(environment["PATH"], os.pathsep.join(map(str, (windows / "System32", windows))))
        self.assertNotIn("GST_PLUGIN_PATH", environment)
        self.assertNotIn("untrusted-sdk", str(environment))


if __name__ == "__main__":
    unittest.main()
