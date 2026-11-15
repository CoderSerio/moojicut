"""Compiler routing regressions; no app, signing, or language downloads."""

import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from native import NativeBuild


class NativeSwiftTest(unittest.TestCase):
    def test_mixed_sources_link_objects_and_system_runtime_without_swift_in_clang(self):
        builder = NativeBuild.__new__(NativeBuild)
        commands = []

        def run(*args, **kwargs):
            command = [str(value) for value in args]
            commands.append(command)
            if "--show-sdk-path" in command:
                return "/SDK/MacOSX.sdk\n"
            if "-print-target-info" in command:
                return json.dumps({"paths": {"runtimeLibraryPaths": ["/Toolchain/swift/macosx", "/usr/lib/swift"]}})
            return ""

        builder.run = run
        objc = ROOT / "plugins/feature/capture_text/macos/MCTextToolsController.m"
        swift = ROOT / "plugins/feature/capture_text/macos/MCTranslationBridge.swift"
        with tempfile.TemporaryDirectory() as directory:
            inputs = builder.native_link_inputs(Path(directory), [objc, swift])
            self.assertIn(objc, inputs)
            self.assertFalse(any(str(value).endswith(".swift") for value in inputs))
            self.assertTrue(any(str(value).endswith("MoojiCaptureText.o") for value in inputs))
            self.assertIn("-L/SDK/MacOSX.sdk/usr/lib/swift", inputs)
            self.assertIn("-Wl,-rpath,/usr/lib/swift", inputs)
            compile_commands = [command for command in commands if "-emit-object" in command]
            self.assertEqual(len(compile_commands), 1)
            self.assertIn(str(swift), compile_commands[0])
            self.assertNotIn(str(objc), compile_commands[0])
            self.assertIn("-parse-as-library", compile_commands[0])
            self.assertIn("-whole-module-optimization", compile_commands[0])

    def test_objc_only_modules_do_not_require_a_swift_compiler_or_runtime(self):
        builder = NativeBuild.__new__(NativeBuild)
        builder.run = lambda *args, **kwargs: self.fail("Swift compiler should not be invoked")
        source = ROOT / "plugins/feature/image_editor/macos/MCImageEditorController.m"
        self.assertEqual(builder.native_link_inputs(Path("unused"), [source]), [source])


if __name__ == "__main__":
    unittest.main()
