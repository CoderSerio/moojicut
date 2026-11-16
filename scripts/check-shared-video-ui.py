#!/usr/bin/env python3
"""Build and exercise the isolated MoonBit UI + native media vertical slice.

Never installs or signs an application and never reads production drafts.
The optional --interactive flag opens only the generated synthetic fixture.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interactive", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The shared component is portable; this media/input host test requires macOS.")
    moon_home = ROOT / ".tools/moon"
    if not (moon_home / "bin/moon").is_file():
        moon_home = Path(os.environ.get("MOON_HOME", ""))
    if not (moon_home / "bin/moon").is_file():
        parser.error("Use the pinned MoonBit toolchain in .tools/moon or MOON_HOME.")
    env = dict(os.environ, MOON_HOME=str(moon_home))
    output = ROOT / ".artifacts/shared-video-ui.noindex"
    output.mkdir(parents=True, exist_ok=True)

    def run(*command, capture=False):
        print("+", " ".join(map(str, command)), flush=True)
        return subprocess.run(list(map(str, command)), cwd=ROOT, env=env, check=True,
                              text=True, stdout=subprocess.PIPE if capture else None).stdout

    moon = moon_home / "bin/moon"
    target = output / "moon"
    run(moon, "--target-dir", target, "test", "--target", "native", "--deny-warn")
    result = run(moon, "--target-dir", target, "build", "--target", "native", "--release",
                 "--deny-warn", "--output-json", capture=True)
    archive = None
    for line in result.splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if item.get("$message_type") == "artifact" and item.get("package") == "moojicut/core":
            candidate = ROOT / item["path"]
            if candidate.suffix == ".a" and candidate.is_file():
                archive = candidate
    if archive is None:
        raise RuntimeError("MoonBit did not report its native archive")
    common = ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT,
              "-I", moon_home / "include"]
    media = ROOT / "plugins/feature/video_editor/macos/MCVideoMedia.m"
    frameworks = ["-framework", "Foundation", "-framework", "AVFoundation", "-framework", "CoreMedia",
                  "-framework", "CoreVideo", "-framework", "CoreGraphics"]
    media_test = output / "video-media"
    run(*common, ROOT / "test/native/video-media.m", media, archive, *frameworks, "-o", media_test)
    # Unique runs preserve earlier evidence and prevent export overwrites.
    run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    waveform_test = output / "audio-waveform"
    run(*common, ROOT / "test/native/audio-waveform.m",
        ROOT / "components/media_analysis/macos/MCAudioWaveform.m", *frameworks, "-o", waveform_test)
    run(waveform_test, run_dir / "waveform")
    run(media_test, run_dir)
    project_media_test = output / "video-project-media"
    run(*common, ROOT / "test/native/video-project-media.m", media,
        *frameworks, "-o", project_media_test)
    run(project_media_test, run_dir / "project-media")
    harness = output / "shared-video-ui"
    run(*common, ROOT / "test/native/shared-video-ui.m", media,
        ROOT / "components/shared_canvas/macos/MCSharedCanvas.m", archive, *frameworks,
        "-framework", "AppKit", "-framework", "QuartzCore", "-o", harness)
    run(harness, run_dir / "source.mp4", run_dir)
    run(harness, run_dir / "source.mp4", run_dir / "project-ui", "--project")
    (output / "latest-run.txt").write_text(str(run_dir) + "\n")
    print("Evidence:", run_dir, flush=True)
    if args.interactive:
        run(harness, run_dir / "source.mp4", run_dir / "manual", "--project", "--interactive")


if __name__ == "__main__":
    main()
