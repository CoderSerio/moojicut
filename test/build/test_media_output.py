"""Exercise the production recording/output ownership policy on all hosts."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MediaOutputTest(unittest.TestCase):
    def test_original_survives_failures_and_only_derived_outputs_are_cleaned(self):
        compiler = shutil.which("cl" if os.name == "nt" else "c++")
        if not compiler:
            self.skipTest("native C++ compiler is unavailable")
        with tempfile.TemporaryDirectory(prefix="moojicut-media-output-") as directory:
            binary = Path(directory) / ("media-output.exe" if os.name == "nt" else "media-output")
            source = ROOT / "test/native/media-output.cpp"
            command = ([compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", "/I" + str(ROOT),
                        str(source), "/Fe" + str(binary)] if os.name == "nt" else
                       [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT),
                        str(source), "-o", str(binary)])
            subprocess.run(command, cwd=directory, check=True, capture_output=True)
            subprocess.run([str(binary), str(Path(directory) / "files")],
                           cwd=directory, check=True, capture_output=True)
