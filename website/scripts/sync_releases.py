#!/usr/bin/env python3
"""Generate a static download snapshot when the website is deployed."""
import json
import os
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPO = "CoderSerio/moojicut"
SUFFIXES = {"macos": "macos-arm64.zip", "windows": "windows-x64.zip", "linux": "linux-x64.tar.gz"}


def version_key(tag):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?", tag)
    if not match:
        return None
    major, minor, patch, stage, serial = match.groups()
    return (int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, "rc": 2, None: 3}[stage], int(serial or 0))


def main():
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "MoojiCut-website-build", "X-GitHub-Api-Version": "2022-11-28"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases?per_page=100", headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        releases = json.load(response)
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
        (ROOT / "public" / "releases.json").write_text(json.dumps(snapshot, indent=2) + "\n")
        # Keep the no-JavaScript experience on the same release as the snapshot.
        page = ROOT / "index.html"
        content = page.read_text()
        content = re.sub(r"(?<=/releases/download/v)\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?/moojicut-\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?-", f"{version}/moojicut-{version}-", content)
        content = re.sub(r"(?<=/releases/tag/v)\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?", version, content)
        content = re.sub(r"(<span data-version>)[^<]+", lambda match: match[1] + version, content)
        page.write_text(content)
        print("Website downloads:", version, "(3 verified release assets)")
        return
    raise RuntimeError("No published release has all three desktop downloads")


if __name__ == "__main__":
    main()
