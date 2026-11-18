"""Release byte identity and fallback links, using local GitHub response fixtures."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sync_releases", ROOT / "scripts" / "sync_releases.py")
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)
VERSION = "0.1.0-alpha.22"
SHA = "a" * 64
ORIGIN = "https://mirror-fixture.pages.dev"


def release(version=VERSION):
    return {
        "draft": False, "tag_name": "v" + version, "published_at": "2026-11-18T10:00:00Z",
        "assets": [{"name": f"moojicut-{version}-{suffix}", "state": "uploaded", "size": 1234,
                    "digest": "sha256:" + SHA,
                    "browser_download_url": f"https://github.com/{sync.REPO}/releases/download/v{version}/moojicut-{version}-{suffix}"}
                   for suffix in sync.SUFFIXES.values()],
    }


def manifest():
    return {"schemaVersion": 1, "mirrors": [{"version": VERSION, "origin": ORIGIN,
            "downloads": {key: {"sha256": SHA, "size": 1234} for key in sync.SUFFIXES}}]}


class ReleaseDownloads(unittest.TestCase):
    def test_matching_assets_and_missing_digest_fail_closed_per_platform(self):
        github = release()
        result = sync.release_snapshot([github], manifest())
        self.assertEqual(set(result["mirrors"]), set(sync.SUFFIXES))
        self.assertEqual(result["mirrors"]["macos"]["url"], f"{ORIGIN}/v{VERSION}/moojicut-{VERSION}-macos-arm64.zip")
        for field, value in [("digest", None), ("digest", "sha256:" + "b" * 64), ("size", 1235)]:
            altered = copy.deepcopy(github)
            altered["assets"][0][field] = value
            checked = sync.release_snapshot([altered], manifest())
            self.assertNotIn("macos", checked.get("mirrors", {}))
            self.assertEqual(set(checked["mirrors"]), {"windows", "linux"})
            self.assertEqual(checked["downloads"]["macos"], github["assets"][0]["browser_download_url"])

    def test_new_release_never_inherits_mirror_and_incomplete_release_is_not_selected(self):
        newer = release("0.1.0-alpha.23")
        self.assertNotIn("mirrors", sync.release_snapshot([release(), newer], manifest()))
        newer["assets"].pop()
        self.assertEqual(sync.release_snapshot([newer, release()], manifest())["version"], VERSION)

    def test_manifest_rejects_duplicate_version_urls_and_invalid_sizes(self):
        invalid = []
        duplicate = manifest()
        duplicate["mirrors"].append(copy.deepcopy(duplicate["mirrors"][0]))
        invalid.append(duplicate)
        boolean_schema = manifest()
        boolean_schema["schemaVersion"] = True
        invalid.append(boolean_schema)
        for origin in ["http://mirror-fixture.pages.dev", ORIGIN + "/", ORIGIN + "@evil.example", ORIGIN + "/next", "https://mirror-fixture.pages.dev.evil.example"]:
            value = manifest()
            value["mirrors"][0]["origin"] = origin
            invalid.append(value)
        for size in [True, 0, "1234", 2**53]:
            value = manifest()
            value["mirrors"][0]["downloads"]["macos"]["size"] = size
            invalid.append(value)
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                sync.release_snapshot([release()], value)

    def test_real_html_removes_stale_links_in_no_javascript_fallback(self):
        page = (ROOT / "index.html").read_text()
        mirrored = sync.release_snapshot([release()], manifest())
        shown = sync.render_downloads(page, mirrored)
        self.assertEqual(shown.count(f'href="{ORIGIN}/v{VERSION}/'), 3)
        self.assertEqual(shown.count('data-mirror-size="1234"'), 3)
        self.assertEqual(shown.count('data-fallback="https://github.com/'), 3)
        self.assertEqual(sync.render_downloads(shown, mirrored), shown)
        next_release = sync.release_snapshot([release("0.1.0-alpha.23")], manifest())
        hidden = sync.render_downloads(shown, next_release)
        self.assertNotIn(ORIGIN, hidden)
        self.assertNotIn('data-fallback=', hidden)
        self.assertNotIn('data-mirror-size=', hidden)
        for key in sync.SUFFIXES:
            self.assertIn(f'href="{next_release["downloads"][key]}"', hidden)
        self.assertIn("<span data-version>0.1.0-alpha.23</span>", hidden)

    def test_unexpected_primary_url_is_not_published(self):
        github = release()
        github["assets"][0]["browser_download_url"] = "https://example.com/fake.zip"
        with self.assertRaises(ValueError):
            sync.release_snapshot([github], manifest())


if __name__ == "__main__":
    unittest.main()
