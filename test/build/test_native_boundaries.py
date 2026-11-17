"""Check real includes and native inventory, not only the link source list."""

import copy
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from check_native_boundaries import check_native_boundaries, quoted_includes
from native_modules import SHARED_PREFIXES, resolve_sources


class NativeBoundariesTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.binding = SHARED_PREFIXES["shared.bindings"] + "capture.h"
        self.manifest = {"schema_version": 1, "shared": {
            "shared.bindings": {"sources": [], "files": [self.binding], "requires": []},
        }, "platforms": {"windows": {
            "host": {"sources": ["native/windows/main.c"], "files": ["native/windows/app.manifest"],
                     "requires": ["feature.capture"]},
            "feature.capture": {"sources": ["plugins/feature/capture/windows/capture.c"],
                                "files": ["plugins/feature/capture/windows/capture.h"],
                                "requires": [], "includes": ["shared.bindings"]},
        }}}
        self.write(self.binding, '#include "moonbit.h"\n')
        self.write("native/windows/main.c", '#include "plugins/feature/capture/windows/capture.h"\n')
        self.write("native/windows/app.manifest", "<assembly/>")
        self.write("plugins/feature/capture/windows/capture.c", '#include "capture.h"\n')
        self.write("plugins/feature/capture/windows/capture.h", f'#include "{self.binding}"\n')

    def write(self, relative, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        return path

    def errors(self, manifest=None):
        return check_native_boundaries(self.root, manifest or self.manifest)

    def test_declared_header_dependencies_do_not_add_linked_sources(self):
        self.assertEqual(self.errors(), [])
        sources = resolve_sources(self.root, self.manifest, "windows")
        self.assertEqual(len(sources), 2)
        self.assertTrue(all(path.suffix == ".c" for path in sources))

    def test_unregistered_source_header_fragment_and_resource_are_rejected(self):
        for extension in (".c", ".h", ".inc", ".manifest", ".ico"):
            with self.subTest(extension=extension):
                path = self.write("native/windows/forgotten" + extension, "")
                self.assertTrue(any("not registered" in error for error in self.errors()))
                path.unlink()
        external = self.write("plugins/imported/untrusted.c", "arbitrary plugin code")
        self.assertEqual(self.errors(), [])
        self.assertNotIn(external, resolve_sources(self.root, self.manifest, "windows"))

    def test_missing_duplicate_and_external_owned_files_are_rejected(self):
        for failure in ("missing", "duplicate", "external"):
            with self.subTest(failure=failure):
                manifest = copy.deepcopy(self.manifest)
                module = manifest["platforms"]["windows"]["feature.capture"]
                module["files"].append({
                    "missing": "plugins/feature/capture/windows/missing.h",
                    "duplicate": module["files"][0],
                    "external": "../external.h",
                }[failure])
                self.assertTrue(self.errors(manifest))

    def test_real_includes_require_declared_dependencies(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["platforms"]["windows"]["feature.capture"]["includes"] = []
        self.assertTrue(any("undeclared native dependency" in error for error in self.errors(manifest)))
        self.write("plugins/feature/capture/windows/capture.c", '#include "missing.h"\n')
        self.assertTrue(any("cannot resolve native include" in error for error in self.errors()))

    def test_compilation_units_cannot_hide_in_the_header_or_resource_inventory(self):
        module = self.manifest["platforms"]["windows"]["feature.capture"]
        module["files"].append(module["sources"].pop())
        self.assertTrue(any("must be listed in sources" in error for error in self.errors()))

    def test_angle_or_computed_include_cannot_bypass_the_dependency_check(self):
        header = "plugins/feature/capture/windows/capture.h"
        self.manifest["platforms"]["windows"]["host"]["requires"] = []
        self.write("native/windows/main.c", f"#include <{header}>\n")
        self.assertTrue(any("undeclared native dependency" in error for error in self.errors()))
        self.write("native/windows/main.c", f'#define HEADER "{header}"\n#include HEADER\n')
        self.assertTrue(any("computed include" in error for error in self.errors()))

    def test_platform_layer_cannot_import_product_even_when_dependency_is_declared(self):
        source = "platform/windows/recording/backend.c"
        target = "plugins/feature/capture/windows/capture.h"
        self.write(source, f'#include "{target}"\n')
        self.manifest["platforms"]["windows"]["platform.recording"] = {
            "sources": [source], "files": [], "requires": [], "includes": ["feature.capture"],
        }
        self.assertTrue(any("platform adapters must not import" in error for error in self.errors()))
        self.manifest["legacy_includes"] = [{"from": source, "to": target, "reason": "Recorded migration debt"}]
        self.assertEqual(self.errors(), [])
        another = "platform/windows/recording/new_backend.c"
        self.write(another, f'#include "{target}"\n')
        self.manifest["platforms"]["windows"]["platform.recording"]["sources"].append(another)
        self.assertTrue(any(another in error and "platform adapters" in error for error in self.errors()))
        self.write(source, "")
        self.assertTrue(any("unused legacy exception" in error for error in self.errors()))

    def test_native_include_parser_ignores_comments_but_checks_real_imports(self):
        self.assertEqual(quoted_includes('''// #include "wrong.h"
/* #import "wrong2.h" */
# import "real.h"
#include \\
 "continued.h"
const char *example = "#include \\"not-a-header.h\\"";
int value; /* A multiline comment must preserve directive line boundaries.
*/ #include "after-comment.h"
'''), ["real.h", "continued.h", "after-comment.h"])
        self.write("native/windows/main.c", '#include "plugins/feature/capture/linux/capture.h"\n')
        self.write("plugins/feature/capture/linux/capture.h", "")
        self.manifest["platforms"]["linux"] = {
            "host": {"sources": [], "requires": []},
            "feature.capture": {"sources": [], "files": ["plugins/feature/capture/linux/capture.h"], "requires": []},
        }
        self.assertTrue(any("another platform" in error for error in self.errors()))


if __name__ == "__main__":
    unittest.main()
