"""Prevent shared feature cores from acquiring UI or application dependencies."""

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from check_module_boundaries import check_boundaries, production_imports


class ModuleBoundariesTest(unittest.TestCase):
    def test_current_repository_obeys_production_boundaries(self):
        self.assertEqual(check_boundaries(ROOT), [])

    def test_core_rejects_ui_even_with_an_alias_but_allows_test_integration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
            manifest = root / "src/internal/features/capture/core/moon.pkg"
            manifest.parent.mkdir(parents=True)
            ui = '"sample/app/internal/features/capture/ui" @view'
            manifest.write_text('import { ' + ui + ' }\n')
            self.assertIn("feature core", check_boundaries(root)[0])
            manifest.write_text('import { "sample/app/internal/shared/geometry" }\n'
                                'import { ' + ui + ' } for "wbtest"\n')
            self.assertEqual(check_boundaries(root), [])
            for entry in ("sample/app", "sample/app/cmd/moojicut", "sample/app/bindings"):
                manifest.write_text('import { "' + entry + '" }\n')
                self.assertEqual(len(check_boundaries(root)), 1)

    def test_foundations_and_feature_isolation_are_checked(self):
        for source, target in (
            ("shared/geometry", "features/capture/core"),
            ("plugins/runtime", "features/capture/extensions/annotations"),
            ("plugins/contracts", "plugins/runtime"),
            ("features/recording/core", "features/capture/core"),
            ("features/capture/ui", "app"),
            ("features/capture/core", "test_support"),
            ("shared/geometry", "video"),
            ("plugins/runtime", "video"),
            ("protocol", "features/capture/core"),
            ("selection", "capture_ui"),
            ("tool_registry", "video_ui"),
        ):
            with self.subTest(source=source, target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
                manifest = root / "src/internal" / source / "moon.pkg"
                manifest.parent.mkdir(parents=True)
                manifest.write_text('import { "sample/app/internal/' + target + '" }\n')
                self.assertEqual(len(check_boundaries(root)), 1)

    def test_comments_do_not_hide_imports_and_unknown_scope_fails(self):
        self.assertEqual(production_imports('''
            // import { "ignored/comment" }
            import { "sample/app/internal/shared/geometry" @geometry }
            /* import { "ignored/block" } */
            import { "test/helper" } for "test"
        '''), ["sample/app/internal/shared/geometry"])
        with self.assertRaises(ValueError):
            production_imports('import { "sample/app" } for "unknown"')


if __name__ == "__main__":
    unittest.main()
