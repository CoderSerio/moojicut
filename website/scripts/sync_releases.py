#!/usr/bin/env python3
"""Generate a static download snapshot when the website is deployed."""
import html
import json
import os
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = "CoderSerio/moojicut"
SUFFIXES = {"macos": "macos-arm64.zip", "windows": "windows-x64.zip", "linux": "linux-x64.tar.gz"}
ORIGIN = re.compile(r"https://(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:pages|workers)\.dev")


def version_key(tag):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?", tag)
    if not match:
        return None
    major, minor, patch, stage, serial = match.groups()
    return (int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, "rc": 2, None: 3}[stage], int(serial or 0))


def validate_mirrors(manifest):
    """Publisher-owned input; entries are added only after public byte verification."""
    if not isinstance(manifest, dict) or set(manifest) != {"schemaVersion", "mirrors"} or type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1:
        raise ValueError("Unsupported verified mirror manifest")
    if not isinstance(manifest["mirrors"], list):
        raise ValueError("Mirror manifest must contain an array")
    versions = set()
    for entry in manifest["mirrors"]:
        if not isinstance(entry, dict) or set(entry) != {"version", "origin", "downloads"}:
            raise ValueError("Unexpected mirror entry fields")
        version, origin, downloads = entry["version"], entry["origin"], entry["downloads"]
        if not isinstance(version, str) or version_key("v" + version) is None or version in versions:
            raise ValueError("Invalid or duplicate mirror version")
        versions.add(version)
        if not isinstance(origin, str) or len(origin) > 253 or not ORIGIN.fullmatch(origin):
            raise ValueError("Expected a canonical HTTPS Cloudflare mirror origin")
        if not isinstance(downloads, dict) or not downloads or set(downloads) - set(SUFFIXES):
            raise ValueError("Unexpected mirror platforms")
        for download in downloads.values():
            if not isinstance(download, dict) or set(download) != {"sha256", "size"}:
                raise ValueError("Unexpected mirror download fields")
            if not isinstance(download["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", download["sha256"]):
                raise ValueError("Expected a lowercase SHA256")
            if type(download["size"]) is not int or not 0 < download["size"] <= 2**53 - 1:
                raise ValueError("Expected an exact positive file size")
    return manifest["mirrors"]


def release_snapshot(releases, manifest):
    mirrors = validate_mirrors(manifest)
    candidates = sorted((r for r in releases if not r["draft"] and version_key(r["tag_name"]) is not None), key=lambda r: version_key(r["tag_name"]), reverse=True)
    for release in candidates:
        version = release["tag_name"][1:]
        assets = {a["name"]: a for a in release["assets"] if a["state"] == "uploaded" and a["size"] > 0}
        expected = {key: f"moojicut-{version}-{suffix}" for key, suffix in SUFFIXES.items()}
        if not all(name in assets for name in expected.values()):
            continue
        base = f"https://github.com/{REPO}/releases/download/v{version}/"
        downloads = {key: assets[name]["browser_download_url"] for key, name in expected.items()}
        if any(downloads[key] != base + name for key, name in expected.items()):
            raise ValueError("Unexpected release download URL")
        snapshot = {"version": version, "publishedAt": release["published_at"], "downloads": downloads}
        for entry in mirrors:
            if entry["version"] != version:
                continue
            for key, verified in entry["downloads"].items():
                asset = assets[expected[key]]
                # Missing GitHub digests cannot establish byte equality. Keep the
                # primary download available but omit this optional mirror.
                if asset.get("digest") != "sha256:" + verified["sha256"] or asset["size"] != verified["size"]:
                    continue
                snapshot.setdefault("mirrors", {})[key] = {
                    "url": f'{entry["origin"]}/v{version}/{expected[key]}',
                    **verified,
                }
        return snapshot
    raise RuntimeError("No published release has all three desktop downloads")


def render_downloads(content, snapshot):
    """Keep the no-JavaScript page and fetched snapshot on the same release."""
    version = snapshot["version"]
    content = re.sub(r"(?<=/releases/download/v)\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?/moojicut-\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?-", f"{version}/moojicut-{version}-", content)
    content = re.sub(r"(?<=/releases/tag/v)\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?", version, content)
    content = re.sub(r"(<span data-version>)[^<]+", lambda match: match[1] + version, content)
    for key in SUFFIXES:
        mirror = snapshot.get("mirrors", {}).get(key)
        attributes = f'href="{html.escape(mirror["url"], quote=True)}"' if mirror else "hidden"
        link = f'<a class="mirror-download" data-mirror="{key}" {attributes}>Cloudflare mirror</a>'
        content, count = re.subn(rf'<a class="mirror-download" data-mirror="{key}"[^>]*>Cloudflare mirror</a>', lambda _: link, content)
        if count != 1:
            raise ValueError(f"Expected exactly one {key} mirror placeholder")
    return content


def main():
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "MoojiCut-website-build", "X-GitHub-Api-Version": "2022-11-28"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases?per_page=100", headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        releases = json.load(response)
    manifest = json.loads((ROOT / "verified-mirrors.json").read_text())
    snapshot = release_snapshot(releases, manifest)
    page = ROOT / "index.html"
    content = render_downloads(page.read_text(), snapshot)
    (ROOT / "public" / "releases.json").write_text(json.dumps(snapshot, indent=2) + "\n")
    page.write_text(content)
    print("Website downloads:", snapshot["version"], f'(3 release assets, {len(snapshot.get("mirrors", {}))} checksum-matched mirrors)')


if __name__ == "__main__":
    main()
