"""Regression coverage for static module linkage and object-file isolation."""

import copy
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from native_modules import object_path, resolve_sources


class NativeModulesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manifest = {"schema_version": 1, "platforms": {"windows": {
            "host": {"sources": ["native/windows/main.c"], "requires": ["feature.capture", "feature.pin"]},
            "feature.capture": {"sources": ["plugins/feature/capture/windows/feature.c"], "requires": ["component.hud"]},
            "feature.pin": {"sources": ["plugins/feature/pin/windows/feature.c"], "requires": ["component.hud"]},
            "component.hud": {"sources": ["components/hud/windows/hud.cpp"], "requires": []},
        }}}
        for module in self.manifest["platforms"]["windows"].values():
            for source in module["sources"]:
                path = self.root / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()

    def test_shared_dependency_is_linked_once_and_external_files_are_not_discovered(self):
        external = self.root / "plugins/imported/third_party.c"
        external.parent.mkdir(parents=True)
        external.touch()
        all_sources = resolve_sources(self.root, self.manifest, "windows")
        self.assertEqual(len(all_sources), 4)
        self.assertNotIn(external, all_sources)
        capture = resolve_sources(self.root, self.manifest, "windows", ("feature.capture",))
        self.assertEqual([p.name for p in capture], ["hud.cpp", "feature.c"])

    def test_broken_module_graphs_fail_before_the_compiler_runs(self):
        for failure in ("cycle", "unknown", "missing", "duplicate", "outside"):
            with self.subTest(failure=failure):
                manifest = copy.deepcopy(self.manifest)
                modules = manifest["platforms"]["windows"]
                if failure == "cycle":
                    modules["component.hud"]["requires"] = ["feature.capture"]
                elif failure == "unknown":
                    modules["feature.pin"]["requires"] = ["feature.unregistered"]
                elif failure == "missing":
                    modules["feature.pin"]["sources"] = ["plugins/feature/pin/windows/missing.c"]
                elif failure == "duplicate":
                    modules["feature.pin"]["sources"] *= 2
                else:
                    modules["feature.pin"]["sources"] = ["../external.c"]
                with self.assertRaises(ValueError):
                    resolve_sources(self.root, manifest, "windows")

    def test_same_named_sources_do_not_overwrite_each_others_objects(self):
        capture = ROOT / "plugins/feature/capture/windows/feature.c"
        pin = ROOT / "plugins/feature/pin/windows/feature.c"
        cpp = capture.with_suffix(".cpp")
        self.assertEqual(len({object_path(self.root, path) for path in (capture, pin, cpp)}), 3)

    def test_swift_is_an_explicit_macos_source_not_an_editor_dependency(self):
        modules = {
            "host": {"sources": ["native/macos/main.m"], "requires": ["feature.capture_text", "feature.image_editor"]},
            "feature.capture_text": {"sources": ["plugins/feature/capture_text/macos/Bridge.swift"], "requires": []},
            "feature.image_editor": {"sources": ["plugins/feature/image_editor/macos/Editor.m"], "requires": []},
        }
        for module in modules.values():
            for source in module["sources"]:
                path = self.root / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
        manifest = {"schema_version": 1, "platforms": {"macos": modules}}
        host = resolve_sources(self.root, manifest, "macos")
        self.assertEqual(sum(path.suffix == ".swift" for path in host), 1)
        editor = resolve_sources(self.root, manifest, "macos", ("feature.image_editor",))
        self.assertEqual([path.name for path in editor], ["Editor.m"])
        modules["feature.image_editor"]["sources"] = ["plugins/feature/capture_text/macos/Bridge.swift"]
        with self.assertRaises(ValueError):
            resolve_sources(self.root, manifest, "macos")


if __name__ == "__main__":
    unittest.main()
