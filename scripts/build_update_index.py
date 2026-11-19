#!/usr/bin/env python3
"""Project the public GitHub release list into the R2 updater index."""

import argparse
import json
from pathlib import Path
import subprocess


def build_index():
    payload = subprocess.check_output([
        "gh", "api", "repos/CoderSerio/moojicut/releases?per_page=100",
    ], timeout=30)
    releases = json.loads(payload)
    if not releases or len(releases) >= 100:
        raise ValueError("Expected a nonempty, complete public release list of fewer than 100 records.")
    index = []
    for release in releases:
        if release["draft"] or not release["published_at"]:
            continue
        record = {key: release[key] for key in ("draft", "prerelease", "tag_name", "html_url", "published_at")}
        revision = release["tag_name"].removeprefix("v")
        names = {"macos.xml", *(f"moojicut-{revision}-{suffix}" for suffix in (
            "macos-arm64.zip", "windows-x64.zip", "linux-x64.tar.gz",
        ))}
        record["assets"] = [
            {key: asset.get(key) for key in ("name", "state", "size", "digest", "browser_download_url")}
            for asset in release["assets"] if asset["name"] in names
        ]
        index.append(record)
    output = (json.dumps(index, separators=(",", ":")) + "\n").encode("utf-8")
    if not index or len(output) > 4 * 1024 * 1024:
        raise ValueError("The published release index is empty or too large.")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    arguments.output.write_bytes(build_index())
