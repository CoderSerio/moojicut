import os
import json
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from desktop import DesktopBuild


class DesktopEnvironmentTest(unittest.TestCase):
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
        with tempfile.TemporaryDirectory() as temporary:
            build.directory = Path(temporary)
            build.executable = build.directory / "app"
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, "checks failed: media"):
                build.runtime_tests()
            report = json.loads((build.directory / "runtime-checks.json").read_text())
        self.assertEqual(calls, ["media", "core", "canvas", ("editor", True)])
        self.assertEqual(report["result"], "failed")
        self.assertEqual(report["checks"]["video-editor"]["result"], "passed")

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
