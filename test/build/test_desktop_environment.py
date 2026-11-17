import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from desktop import DesktopBuild


class DesktopEnvironmentTest(unittest.TestCase):
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
