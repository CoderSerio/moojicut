"""Prevent shared feature cores from acquiring UI or application dependencies."""

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from check_module_boundaries import RETIRED_PACKAGES, check_boundaries, production_imports


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
            ("features/capture/ui", "features/capture/extensions/annotations"),
            ("features/capture/ui/fields", "features/capture"),
            ("features/capture/core", "shared/test_support"),
            ("shared/geometry", "features/video_editor/core/legacy_document"),
            ("plugins/runtime/catalog", "features/video_editor/core"),
            ("shared/protocol", "features/capture/core"),
            ("shared/geometry", "features/capture/ui"),
            ("plugins/runtime/lifecycle", "features/video_editor/ui"),
        ):
            with self.subTest(source=source, target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
                manifest = root / "src/internal" / source / "moon.pkg"
                manifest.parent.mkdir(parents=True)
                manifest.write_text('import { "sample/app/internal/' + target + '" }\n')
                self.assertEqual(len(check_boundaries(root)), 1)

    def test_ui_consumes_core_and_shared_fields_without_loading_contributions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
            manifest = root / "src/internal/features/capture/ui/moon.pkg"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('import {\n'
                                '"sample/app/internal/features/capture/core"\n'
                                '"sample/app/internal/features/capture/ui/layout"\n'
                                '"sample/app/internal/shared/ui/fields"\n}\n'
                                'import { "sample/app/internal/features/capture" } for "wbtest"\n')
            self.assertEqual(check_boundaries(root), [])

    def test_retired_package_roots_cannot_reappear_even_without_a_manifest(self):
        for name in RETIRED_PACKAGES:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
                old = root / "src/internal" / name
                old.mkdir(parents=True)
                self.assertIn("retired package path", check_boundaries(root)[0])
                (old / "moon.pkg").write_text('// An empty wrapper must also fail.\n')
                self.assertEqual(len(check_boundaries(root)), 1)

    def test_retired_imports_fail_in_production_and_test_scopes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
            manifest = root / "src/internal/features/capture/ui/moon.pkg"
            manifest.parent.mkdir(parents=True)
            for name in RETIRED_PACKAGES:
                for scope in ("", ' for "test"', ' for "wbtest"'):
                    with self.subTest(name=name, scope=scope):
                        manifest.write_text('import { "sample/app/internal/' + name + '" @old }' + scope)
                        errors = check_boundaries(root)
                        self.assertEqual(len(errors), 1)
                        self.assertIn("retired package path", errors[0])
            manifest.write_text('import { "sample/app/internal/features/video_editor/core" } for "wbtest"\n'
                                'import { "external/library/internal/video" }\n')
            self.assertEqual(check_boundaries(root), [])

    def test_unowned_roots_fail_and_nested_core_packages_remain_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "moon.mod").write_text('name = "sample/app"\nsource = "src"\n')
            manifest = root / "src/internal/features/video_editor/core/moon.pkg"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('import { "sample/app/internal/features/video_editor/core/legacy_document" @video }\n')
            self.assertEqual(check_boundaries(root), [])
            manifest.write_text('import { "sample/app/internal/misc/utils" }\n')
            self.assertIn("internal package must belong", check_boundaries(root)[0])
            manifest.unlink()
            misplaced = root / "src/internal/misc/moon.pkg"
            misplaced.parent.mkdir()
            misplaced.write_text('// No imports\n')
            self.assertIn("internal package must belong", check_boundaries(root)[0])

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
