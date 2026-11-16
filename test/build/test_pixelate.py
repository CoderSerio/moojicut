"""Exercise the shared native pixel backend with both desktop toolchains."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PixelateTest(unittest.TestCase):
    def test_source_grid_clipping_and_stride(self):
        compiler = shutil.which("cl" if os.name == "nt" else "cc")
        if not compiler:
            self.skipTest("native C compiler is unavailable")
        with tempfile.TemporaryDirectory(prefix="moojicut-pixelate-") as directory:
            binary = Path(directory) / ("pixelate.exe" if os.name == "nt" else "pixelate")
            source = ROOT / "test/native/pixelate.c"
            command = ([compiler, "/nologo", "/std:c11", "/W4", "/I" + str(ROOT), str(source), "/Fe" + str(binary)]
                       if os.name == "nt" else
                       [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT), str(source), "-o", str(binary)])
            subprocess.run(command, cwd=directory, check=True, capture_output=True)
            subprocess.run([str(binary)], cwd=directory, check=True, capture_output=True)
