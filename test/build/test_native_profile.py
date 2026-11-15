"""Guard the installed identity and avoid surviving production build copies."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from native_profile import native_profile
from native import NativeBuild


class NativeProfileTest(unittest.TestCase):
    def test_development_profiles_are_separate_and_production_identity_is_stable(self):
        a = native_profile(ROOT)
        self.assertEqual(a, native_profile(ROOT))
        b = native_profile(ROOT / "other-worktree")
        self.assertNotEqual(a.bundle_id, b.bundle_id)
        self.assertNotEqual(a.defaults_domain, b.defaults_domain)
        self.assertIn("Test", a.app.name)
        production = native_profile(ROOT, "production")
        self.assertEqual(production.bundle_id, "dev.moojicut.native")
        self.assertEqual(production.defaults_domain, "dev.mooncap.native.preferences")
        self.assertNotEqual(a.defaults_domain, production.defaults_domain)

    @unittest.skipUnless(sys.platform == "darwin", "macOS installed application paths")
    def test_installed_paths_and_symlinks_are_rejected_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "alias").symlink_to("/Applications", target_is_directory=True)
            paths = [Path("/Applications/Mooji Cut.app"), Path.home() / "Applications/Mooji Cut.app",
                     root / "alias/Mooji Cut.app"]
            (root / "Mooji Cut.app").symlink_to(root / "elsewhere")
            paths.append(root / "Mooji Cut.app")
            for path in paths:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    native_profile(root, "production", path)
            real_output = root / "real-output"
            real_output.mkdir()
            (root / "test-alias").symlink_to(real_output, target_is_directory=True)
            profile = native_profile(root, test_id="fixture", output=root / "test-alias/Mooji Cut Test fixture.app")
            self.assertEqual(profile.app, (real_output / "Mooji Cut Test fixture.app").resolve())
            with self.assertRaises(ValueError):
                native_profile(root, test_id="../../native")

    def test_release_staging_is_removed_even_when_packaging_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder = NativeBuild.__new__(NativeBuild)
            builder.profile = native_profile(root, "production")
            builder.app = builder.profile.app
            visited = []

            def package():
                visited.append(builder.app)
                self.assertNotEqual(builder.app, builder.profile.app)
                builder.app.mkdir()
                raise RuntimeError("Synthetic packaging failure")

            builder.package_release = package
            with patch("native.ARTIFACTS", root), self.assertRaisesRegex(RuntimeError, "Synthetic"):
                builder.release()
            self.assertFalse(visited[0].exists())
            self.assertEqual(builder.app, builder.profile.app)
            self.assertFalse(builder.app.exists())


if __name__ == "__main__":
    unittest.main()
