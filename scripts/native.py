#!/usr/bin/env python3
"""Build-time adapter for MoonBit's static library and the macOS application.

Only Python's standard library is used. No Python runtime is shipped in the app.
The MoonBit module, version and source directory are defined by root moon.mod.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Mooji Cut"
EXECUTABLE_NAME = "MoojiCut"
APP = ROOT / "dist/native-app.noindex" / (APP_NAME + ".app")
ARTIFACTS = ROOT / ".artifacts"
FRAMEWORKS = ["AppKit", "Foundation", "Carbon", "ScreenCaptureKit", "AVKit",
              "AVFoundation", "CoreMedia", "CoreVideo", "CoreGraphics", "UniformTypeIdentifiers"]


class NativeBuild:
    def __init__(self, release_version=None):
        if sys.platform != "darwin":
            raise RuntimeError("The AppKit host requires macOS and Xcode Command Line Tools.")
        local = ROOT / ".tools/moon"
        if (local / "bin/moon").is_file():
            home = local.resolve()
        elif os.environ.get("MOON_HOME"):
            home = Path(os.environ["MOON_HOME"]).expanduser().resolve()
        else:
            binary = shutil.which("moon")
            if not binary:
                raise RuntimeError("Install MoonBit on PATH, set MOON_HOME, or provide .tools/moon.")
            home = Path(binary).resolve().parent.parent
        self.moon = home / "bin/moon"
        self.include = home / "include"
        if not self.moon.is_file() or not (self.include / "moonbit.h").is_file():
            raise RuntimeError("MoonBit native headers are missing; use a complete matching toolchain.")
        self.env = dict(os.environ, MOON_HOME=str(home))
        manifest = (ROOT / "moon.mod").read_text()
        self.name = self.manifest_value(manifest, "name")
        self.version = self.manifest_value(manifest, "version")
        self.release_version = release_version or self.version + "-alpha.1"
        version = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?",
                               self.release_version)
        if not version:
            raise RuntimeError("Release version must be X.Y.Z with an optional prerelease suffix, "
                               "for example 0.1.0-alpha.1.")
        self.bundle_version = version.group(1)
        self.compiler = self.run(home / "bin/moonc", "-v", quiet=True).strip()
        self.clang = self.run("xcrun", "clang", "--version", quiet=True).splitlines()[0]
        print("MoonBit compiler:", self.compiler, flush=True)
        print(self.clang, flush=True)

    @staticmethod
    def manifest_value(manifest, key):
        match = re.search(r'^\s*' + re.escape(key) + r'\s*=\s*"([^"\n]+)"\s*$', manifest, re.M)
        if not match:
            raise RuntimeError("Missing {} in root moon.mod.".format(key))
        return match.group(1)

    def run(self, *args, quiet=False, env=None):
        result = subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env or self.env,
                                text=True, capture_output=True, timeout=120)
        if result.stdout and (not quiet or result.returncode):
            print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr, flush=True)
        if result.returncode:
            raise RuntimeError("{} failed (exit {}).".format(args[0], result.returncode))
        return result.stdout

    def moon_command(self, directory, *args, quiet=False):
        return self.run(self.moon, "-C", ROOT, "--target-dir", directory / "moon", *args, quiet=quiet)

    def archive(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        output = self.moon_command(directory, "build", "--target", "native", "--release",
                                   "--deny-warn", "--output-json", quiet=True)
        for line in output.splitlines():
            try:
                artifact = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (artifact.get("$message_type") == "artifact" and
                    artifact.get("package") == self.name and artifact.get("target_backend") == "native"):
                path = ROOT / artifact["path"]
                if path.suffix == ".a" and path.is_file():
                    return path
        raise RuntimeError("MoonBit did not report the module's native foreign_library archive.")

    def source_revision(self):
        git = shutil.which("git")
        if not git:
            return {"commit": None, "workingTreeDirty": None}
        revision = subprocess.run([git, "rev-parse", "--verify", "HEAD"], cwd=ROOT,
                                  env=self.env, text=True, capture_output=True, timeout=30)
        if revision.returncode:
            return {"commit": None, "workingTreeDirty": None}
        status = subprocess.run([git, "status", "--porcelain", "--untracked-files=normal"],
                                cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=30)
        return {"commit": revision.stdout.strip(),
                "workingTreeDirty": bool(status.stdout.strip()) if not status.returncode else None}

    def binary_platform(self, executable):
        arch = platform.machine()
        architectures = self.run("/usr/bin/lipo", "-archs", executable, quiet=True).split()
        if architectures != [arch]:
            raise RuntimeError("Expected a {} binary; found {}.".format(arch, architectures))
        commands = self.run("/usr/bin/otool", "-l", executable, quiet=True)
        for command in commands.split("Load command "):
            if re.search(r"\bcmd LC_BUILD_VERSION\b", command):
                key = "minos"
            elif re.search(r"\bcmd LC_VERSION_MIN_MACOSX\b", command):
                key = "version"
            else:
                continue
            minimum = re.search(r"^\s*" + key + r"\s+([0-9]+(?:\.[0-9]+)+)\s*$", command, re.M)
            if minimum:
                return arch, minimum.group(1)
        raise RuntimeError("Cannot determine the built executable's minimum macOS version.")

    def build(self):
        directory = ARTIFACTS / "native-app"
        archive = self.archive(directory)
        native = ROOT / "native/macos"
        sources = sorted(native.rglob("*.m"))
        if not sources:
            raise RuntimeError("No AppKit source files found in native/macos.")
        brand = ROOT / "assets/brand/mooji-cut"
        with tempfile.TemporaryDirectory(prefix="staging-", dir=directory) as staging_name:
            staging = Path(staging_name)
            staged_app = staging / APP.name
            contents = staged_app / "Contents"
            resources = contents / "Resources"
            executable = contents / "MacOS" / EXECUTABLE_NAME
            executable.parent.mkdir(parents=True)
            resources.mkdir()
            self.run("xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                     "-I", self.include, "-I", native, *sources, archive,
                     *(argument for framework in FRAMEWORKS for argument in ("-framework", framework)),
                     "-o", executable)
            arch, minimum_macos = self.binary_platform(executable)
            generator = directory / "generate-app-icon"
            iconset = staging / "MoojiCut.iconset"
            self.run("xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                     ROOT / "native/tools/generate-app-icon.m", "-framework", "AppKit", "-o", generator)
            self.run(generator, brand / "app-icon-rounded-preview.png", iconset)
            self.run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources / "MoojiCut.icns")
            shutil.copy2(brand / "menubar-18.png", resources / "MoojiCutStatusTemplate.png")
            shutil.copy2(brand / "menubar-18@2x.png", resources / "MoojiCutStatusTemplate@2x.png")
            info = {
                "CFBundleDevelopmentRegion": "zh_CN", "CFBundleName": APP_NAME,
                "CFBundleDisplayName": APP_NAME, "CFBundleIdentifier": "dev.moojicut.native",
                "CFBundleExecutable": EXECUTABLE_NAME, "CFBundleIconFile": "MoojiCut.icns",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": self.bundle_version,
                "CFBundleVersion": self.bundle_version, "MoonBitCoreVersion": self.version,
                "MoojiCutReleaseVersion": self.release_version, "LSMinimumSystemVersion": minimum_macos,
                "NSPrincipalClass": "NSApplication", "LSUIElement": True, "NSHighResolutionCapable": True,
            }
            (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
            self.run("/usr/bin/plutil", "-lint", contents / "Info.plist", quiet=True)
            dependencies = self.run("/usr/bin/otool", "-L", executable, quiet=True)
            if re.search(r"Electron|Chromium|WebKit|libnode", dependencies, re.I):
                raise RuntimeError("Unexpected browser or Node runtime in the native application.")
            metadata = {"version": self.release_version, "bundleVersion": self.bundle_version,
                        "coreVersion": self.version, **self.source_revision(),
                        "compilerVersion": self.compiler, "clangVersion": self.clang,
                        "arch": arch, "minimumMacOSVersion": minimum_macos,
                        "frameworks": FRAMEWORKS,
                        "signing": "ad-hoc", "notarized": False}
            (resources / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
            self.run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", staged_app)
            self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged_app)
            APP.parent.mkdir(parents=True, exist_ok=True)
            # A failed compilation or bundle check must not remove the last good app.
            previous = staging / "previous.app"
            if APP.exists():
                APP.rename(previous)
            try:
                staged_app.rename(APP)
            except OSError:
                if previous.exists():
                    previous.rename(APP)
                raise
        print("Native app:", APP, flush=True)
        print("Executable: {:.0f} KiB; {} Objective-C files + MoonBit static core; ad-hoc signed."
              .format((APP / "Contents/MacOS" / EXECUTABLE_NAME).stat().st_size / 1024, len(sources)), flush=True)

    def release(self):
        self.build()
        metadata = json.loads((APP / "Contents/Resources/build.json").read_text())
        filename = "moojicut-{}-macos-{}.zip".format(self.release_version, metadata["arch"])
        directory = ROOT / "dist/releases"
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".staging-", dir=directory) as staging_name:
            staging = Path(staging_name)
            archive = staging / filename
            self.run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", APP, archive)
            with zipfile.ZipFile(archive) as packaged:
                corrupt = packaged.testzip()
                if corrupt:
                    raise RuntimeError("Corrupt file in release ZIP: {}.".format(corrupt))
                required = {str(Path(APP.name) / "Contents" / relative) for relative in (
                    "Info.plist", "MacOS/" + EXECUTABLE_NAME, "Resources/build.json",
                    "Resources/MoojiCut.icns", "Resources/MoojiCutStatusTemplate.png",
                    "Resources/MoojiCutStatusTemplate@2x.png", "_CodeSignature/CodeResources")}
                missing = required - set(packaged.namelist())
                if missing:
                    raise RuntimeError("Release ZIP is missing files: {}.".format(sorted(missing)))
            digest = hashlib.sha256()
            with archive.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            checksum = staging / (filename + ".sha256")
            checksum.write_text("{}  {}\n".format(digest.hexdigest(), filename))
            build_info = archive.with_suffix(".build.json")
            build_info.write_text(json.dumps({**metadata, "archive": filename,
                                              "sha256": digest.hexdigest()}, indent=2) + "\n")
            for artifact in (archive, checksum, build_info):
                artifact.replace(directory / artifact.name)
        print("Release ZIP:", directory / filename, flush=True)
        print("SHA256:", directory / checksum.name, flush=True)
        print("Build metadata:", directory / build_info.name, flush=True)

    def test(self):
        directory = ARTIFACTS / "native-core"
        directory.mkdir(parents=True, exist_ok=True)
        self.moon_command(directory, "test", "--target", "native", "--deny-warn")
        archive = self.archive(directory)
        executable = directory / "core-embedding"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 ROOT / "test/native/core-embedding.m", archive, "-framework", "Foundation", "-o", executable)
        self.run(executable)
        shortcuts = ARTIFACTS / "native-shortcuts"
        shortcuts.mkdir(parents=True, exist_ok=True)
        preferences = ROOT / "native/macos/preferences"
        executable = shortcuts / "shortcut-settings"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", preferences,
                 ROOT / "test/native/shortcut-settings.m", preferences / "MCShortcutStore.m",
                 preferences / "MCSystemShortcutCheck.m", "-framework", "AppKit", "-framework", "Carbon",
                 "-o", executable)
        self.run(executable)
        global_shortcuts = shortcuts / "global-shortcuts"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT / "native/macos",
                 ROOT / "test/native/global-shortcuts.m", preferences / "MCShortcutStore.m",
                 preferences / "MCSystemShortcutCheck.m", ROOT / "native/macos/shortcuts/MCGlobalShortcutManager.m",
                 "-framework", "AppKit", "-framework", "Carbon", "-o", global_shortcuts)
        self.run(global_shortcuts)

    def smoke(self):
        self.build()
        output = ARTIFACTS / "native-app/smoke"
        output.mkdir(parents=True, exist_ok=True)
        report = output / "report.json"
        if report.exists():
            report.unlink()
        env = dict(self.env, MOOJICUT_NATIVE_OUTPUT=str(output),
                   MOOJICUT_NATIVE_DEFAULTS_DOMAIN="dev.moojicut.native.smoke")
        self.run(APP / "Contents/MacOS" / EXECUTABLE_NAME, "--smoke", env=env)
        if not report.is_file() or not json.loads(report.read_text()).get("smokePassed"):
            raise RuntimeError("Native UI smoke did not produce a passing report.")
        self.run(APP / "Contents/MacOS" / EXECUTABLE_NAME, "--capture-smoke", env=env)
        self.run(APP / "Contents/MacOS" / EXECUTABLE_NAME, "--recording-smoke", env=env)
        print("Smoke report:", report, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "dev", "test", "smoke", "release"))
    parser.add_argument("--release-version", metavar="VERSION",
                        help="Release label (default: <moon.mod version>-alpha.1).")
    args = parser.parse_args()
    native = NativeBuild(args.release_version)
    if args.command == "dev":
        native.build()
        native.run("/usr/bin/open", APP, "--args", "--preferences")
    else:
        getattr(native, args.command)()


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit("Error: {}".format(error))
