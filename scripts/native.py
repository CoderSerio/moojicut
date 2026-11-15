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
from install_sparkle import install as install_sparkle, VERSION as SPARKLE_VERSION
from install_extism import install as install_extism, VERSION as EXTISM_VERSION
from native_modules import native_sources


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
        self.signing_identity = self.select_signing_identity()
        manifest = (ROOT / "moon.mod").read_text()
        self.name = self.manifest_value(manifest, "name")
        self.version = self.manifest_value(manifest, "version")
        self.release_version = release_version or self.version + "-alpha.12"
        version = re.fullmatch(r"([0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?",
                               self.release_version)
        if not version:
            raise RuntimeError("Release version must be X.Y.Z with an optional prerelease suffix, "
                               "for example 0.1.0-alpha.1.")
        self.short_version = version.group(1)
        suffix = self.release_version[len(self.short_version):]
        prerelease = re.fullmatch(r"-(alpha|beta|rc)\.([1-9][0-9]{0,2})", suffix)
        if suffix and (not prerelease or int(prerelease.group(2)) > 255):
            raise RuntimeError("macOS previews require -alpha.N, -beta.N or -rc.N (N: 1–255).")
        self.bundle_version = self.short_version + (
            {"alpha": "a", "beta": "b", "rc": "fc"}[prerelease.group(1)] + prerelease.group(2)
            if prerelease else "")
        self.compiler = self.run(home / "bin/moonc", "-v", quiet=True).strip()
        self.clang = self.run("xcrun", "clang", "--version", quiet=True).splitlines()[0]
        print("MoonBit compiler:", self.compiler, flush=True)
        print(self.clang, flush=True)
        print("Signing:", "ad-hoc (permissions may need renewing after updates)" if self.signing_identity == "-"
              else "development/configured certificate", flush=True)

    @staticmethod
    def select_signing_identity():
        # A hash-only ad-hoc identity changes on every build and invalidates TCC
        # grants. Reuse an existing development certificate for local builds;
        # never create/import a certificate or change keychain access settings.
        configured = os.environ.get("MOOJICUT_SIGNING_IDENTITY")
        if configured:
            return configured
        identities = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                                    text=True, capture_output=True, timeout=30)
        matches = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "Apple Development: [^"]+"',
                             identities.stdout, re.M) if identities.returncode == 0 else []
        if len(matches) > 1:
            raise RuntimeError("Multiple Apple Development certificates found; set MOOJICUT_SIGNING_IDENTITY "
                               "to the desired certificate SHA-1, or '-' for an ad-hoc build.")
        return matches[0] if matches else "-"

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
        self.run(sys.executable, ROOT / "scripts/generate_icons.py", "--check", quiet=True)
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

    def build_plugin_worker(self, contents):
        """Keep the Wasm engine in a separate, bounded helper process."""
        runtime = install_extism(platform.machine())
        frameworks, helpers, resources = (contents / name for name in ("Frameworks", "Helpers", "Resources"))
        for directory in (frameworks, helpers, resources):
            directory.mkdir(parents=True, exist_ok=True)
        library = frameworks / "libextism.dylib"
        helper = helpers / "MoojiPluginWorker"
        shutil.copy2(runtime / "libextism.dylib", library)
        self.run("/usr/bin/install_name_tool", "-id", "@rpath/libextism.dylib", library)
        self.run("xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-I", runtime, ROOT / "native/tools/plugin-worker.m", library, "-framework", "Foundation",
                 "-Wl,-rpath,@executable_path/../Frameworks", "-o", helper)
        self.binary_platform(helper)
        self.run("/usr/bin/codesign", "--force", "--sign", self.signing_identity, "--timestamp=none", library)
        # Match the app's existing non-hardened signing policy. Wasmtime 49's
        # allocator does not use MAP_JIT: allow-jit alone is insufficient under
        # Hardened Runtime. Notarization needs a separately verified helper-only
        # executable-memory exception; never relax the UI process or library
        # validation here. Ad-hoc signatures also have no matching Team ID.
        # https://github.com/bytecodealliance/wasmtime/issues/11989
        self.run("/usr/bin/codesign", "--force", "--sign", self.signing_identity, "--timestamp=none", helper)
        for binary in (library, helper):
            self.run("/usr/bin/codesign", "--verify", "--strict", binary)
        shutil.copy2(runtime / "extism-1.41.0-LICENSE", resources / "Extism-LICENSE.txt")
        shutil.copy2(runtime / "wasmtime-49.0.0-LICENSE", resources / "Wasmtime-LICENSE.txt")
        return helper

    def build(self):
        sparkle = install_sparkle()
        directory = ARTIFACTS / "native-app"
        archive = self.archive(directory)
        native = ROOT / "native/macos"
        sources = native_sources("macos")
        brand = ROOT / "assets/brand/mooji-cut"
        with tempfile.TemporaryDirectory(prefix="staging-", dir=directory) as staging_name:
            staging = Path(staging_name)
            staged_app = staging / APP.name
            contents = staged_app / "Contents"
            resources = contents / "Resources"
            executable = contents / "MacOS" / EXECUTABLE_NAME
            executable.parent.mkdir(parents=True)
            resources.mkdir()
            frameworks = contents / "Frameworks"
            frameworks.mkdir()
            self.build_plugin_worker(contents)
            embedded_sparkle = frameworks / "Sparkle.framework"
            shutil.copytree(sparkle / "Sparkle.framework", embedded_sparkle, symlinks=True)
            shutil.copy2(sparkle / "LICENSE", resources / "Sparkle-LICENSE.txt")
            shutil.copy2(ROOT / "LICENSE", resources / "LICENSE.txt")
            shutil.copy2(ROOT / "assets/icons/lucide/LICENSE", resources / "Lucide-LICENSE.txt")
            self.run("xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra", "-Werror",
                     "-I", self.include, "-I", ROOT, "-I", native, "-F", sparkle, *sources, archive,
                     "-framework", "Sparkle", "-larchive", "-lz", "-Wl,-rpath,@executable_path/../Frameworks",
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
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": self.short_version,
                "CFBundleVersion": self.bundle_version, "MoonBitCoreVersion": self.version,
                "MoojiCutReleaseVersion": self.release_version, "LSMinimumSystemVersion": minimum_macos,
                "NSPrincipalClass": "NSApplication", "LSUIElement": True, "NSHighResolutionCapable": True,
                "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
                "SUAllowsAutomaticUpdates": False, "SUEnableSystemProfiling": False,
                "SUShowReleaseNotes": False, "SUEnableJavaScript": False,
                "SUVerifyUpdateBeforeExtraction": True,
                "SURequireSignedFeed": True,
            }
            update_config = native / "updates/feed.json"
            if update_config.is_file():
                feed = json.loads(update_config.read_text())
                info["SUFeedURL"] = feed["feedURL"]
                info["SUPublicEDKey"] = feed["publicKey"]
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
                        "sparkleVersion": SPARKLE_VERSION, "extismVersion": EXTISM_VERSION,
                        "pluginWorkerHardenedRuntime": False,
                        "signing": "ad-hoc" if self.signing_identity == "-" else "certificate", "notarized": False}
            (resources / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
            # Sign nested code inside out; do not weaken the host's requirements.
            version_dir = embedded_sparkle / "Versions/B"
            for component in (version_dir / "XPCServices/Downloader.xpc",
                              version_dir / "XPCServices/Installer.xpc",
                              version_dir / "Updater.app", version_dir / "Autoupdate", embedded_sparkle):
                self.run("/usr/bin/codesign", "--force", "--sign", self.signing_identity,
                         "--timestamp=none", "--preserve-metadata=entitlements", component)
            self.run("/usr/bin/codesign", "--force", "--sign", self.signing_identity, "--timestamp=none", staged_app)
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
        print("Executable: {:.0f} KiB; {} Objective-C files + MoonBit static core; {} signed."
              .format((APP / "Contents/MacOS" / EXECUTABLE_NAME).stat().st_size / 1024, len(sources),
                      "ad-hoc" if self.signing_identity == "-" else "certificate"), flush=True)

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
                    "Resources/MoojiCutStatusTemplate@2x.png", "_CodeSignature/CodeResources",
                    "Resources/LICENSE.txt", "Resources/Sparkle-LICENSE.txt", "Resources/Lucide-LICENSE.txt",
                    "Frameworks/Sparkle.framework/Versions/B/Sparkle", "Frameworks/libextism.dylib",
                    "Helpers/MoojiPluginWorker", "Resources/Extism-LICENSE.txt", "Resources/Wasmtime-LICENSE.txt")}
                missing = required - set(packaged.namelist())
                if missing:
                    raise RuntimeError("Release ZIP is missing files: {}.".format(sorted(missing)))
            extracted = staging / "unpacked"
            self.run("/usr/bin/ditto", "-x", "-k", archive, extracted)
            self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", extracted / APP.name)
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
        self.run(sys.executable, "-m", "unittest", "discover", "-s", ROOT / "test/build", "-v")
        directory = ARTIFACTS / "native-core"
        directory.mkdir(parents=True, exist_ok=True)
        self.moon_command(directory, "test", "--target", "native", "--deny-warn")
        archive = self.archive(directory)
        executable = directory / "core-embedding"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 "-I", ROOT, ROOT / "test/native/core-embedding.m", archive, "-framework", "Foundation", "-o", executable)
        self.run(executable)
        shortcuts = ARTIFACTS / "native-shortcuts"
        shortcuts.mkdir(parents=True, exist_ok=True)
        preferences = ROOT / "native/macos/preferences"
        user_plugins = native_sources("macos", "system.user_plugins")
        executable = shortcuts / "shortcut-settings"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT, "-I", preferences,
                 ROOT / "test/native/shortcut-settings.m", preferences / "MCShortcutStore.m",
                 preferences / "MCSystemShortcutCheck.m", "-framework", "AppKit", "-framework", "Carbon",
                 "-o", executable)
        self.run(executable)
        pin_shortcuts = shortcuts / "pin-shortcuts"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT, "-I", ROOT / "native/macos", "-I", self.include,
                 ROOT / "test/native/pin-shortcuts.m", preferences / "MCPinShortcutStore.m",
                 preferences / "MCShortcutStore.m", preferences / "MCShortcutRecorder.m", preferences / "MCSystemShortcutCheck.m",
                 preferences / "MCPreferencesController.m", preferences / "MCToolRegistryStore.m",
                 preferences / "MCPluginManagementController.m", *user_plugins, archive,
                 "-framework", "AppKit", "-framework", "Carbon", "-framework", "UniformTypeIdentifiers",
                 "-larchive", "-lz", "-o", pin_shortcuts)
        self.run(pin_shortcuts)
        pinned_image = shortcuts / "pinned-image"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT, "-I", ROOT / "native/macos",
                 "-DRegisterEventHotKey=MCTestRegisterPinHotKey", "-DUnregisterEventHotKey=MCTestUnregisterPinHotKey",
                 ROOT / "test/native/pinned-image.m", *native_sources("macos", "feature.pin"),
                 "-I", self.include, preferences / "MCToolRegistryStore.m", archive, "-framework", "AppKit", "-framework", "Carbon", "-o", pinned_image)
        self.run(pinned_image)
        global_shortcuts = shortcuts / "global-shortcuts"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT, "-I", ROOT / "native/macos",
                 ROOT / "test/native/global-shortcuts.m", preferences / "MCShortcutStore.m",
                 preferences / "MCSystemShortcutCheck.m", ROOT / "native/macos/shortcuts/MCGlobalShortcutManager.m",
                 "-framework", "AppKit", "-framework", "Carbon", "-o", global_shortcuts)
        self.run(global_shortcuts)
        capture_permission = shortcuts / "capture-permission"
        selection = shortcuts / "selection"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT, "-I", self.include,
                 ROOT / "test/native/selection.m", *native_sources("macos", "feature.select"), archive,
                 "-framework", "Foundation", "-o", selection)
        self.run(selection)
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 "-I", ROOT, "-I", ROOT / "native/macos", "-DCGPreflightScreenCaptureAccess=MCFakePreflight",
                 "-DCGRequestScreenCaptureAccess=MCFakeRequest", ROOT / "test/native/capture-permission.m",
                 *native_sources("macos", "feature.capture"), archive,
                 "-framework", "AppKit", "-framework", "CoreGraphics", "-framework", "ScreenCaptureKit", "-o", capture_permission)
        self.run(capture_permission)
        inline_text = shortcuts / "inline-text"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 "-I", ROOT, "-I", ROOT / "native/macos", ROOT / "test/native/inline-text.m",
                 *native_sources("macos", "feature.image_editor"), archive, "-framework", "AppKit", "-o", inline_text)
        self.run(inline_text)
        capture_overlay = shortcuts / "capture-overlay"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 "-I", ROOT, "-I", ROOT / "native/macos", ROOT / "test/native/capture-overlay.m",
                 *native_sources("macos", "feature.image_editor"), archive, "-framework", "AppKit", "-o", capture_overlay)
        self.run(capture_overlay)
        tool_layout = shortcuts / "tool-layout"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 "-I", ROOT, "-I", ROOT / "native/macos", ROOT / "test/native/tool-layout.m",
                 *native_sources("macos", "feature.capture"), archive,
                 "-framework", "AppKit", "-framework", "CoreGraphics", "-framework", "ScreenCaptureKit", "-o", tool_layout)
        self.run(tool_layout)
        tool_settings = shortcuts / "tool-registry-settings"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", self.include,
                 "-I", ROOT, "-I", ROOT / "native/macos", ROOT / "test/native/tool-registry-settings.m",
                 preferences / "MCToolRegistryStore.m", preferences / "MCPluginManagementController.m",
                 preferences / "MCPreferencesController.m", preferences / "MCPinShortcutStore.m",
                 preferences / "MCShortcutStore.m", preferences / "MCShortcutRecorder.m", preferences / "MCSystemShortcutCheck.m",
                 *user_plugins, archive, "-framework", "AppKit", "-framework", "Carbon",
                 "-framework", "UniformTypeIdentifiers", "-larchive", "-lz", "-o", tool_settings)
        self.run(tool_settings)
        plugin_directory = ARTIFACTS / "native-plugins"
        plugin_worker = self.build_plugin_worker(plugin_directory / "Contents")
        worker_test = plugin_directory / "plugin-worker"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT,
                 ROOT / "test/native/plugin-worker.m", ROOT / "native/macos/plugins/MCPluginWorker.m",
                 "-framework", "Foundation", "-o", worker_test)
        self.run(worker_test, plugin_worker)
        package_test = plugin_directory / "plugin-package"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT,
                 ROOT / "test/native/plugin-package.m", ROOT / "native/macos/plugins/MCPluginPackageStore.m",
                 "-framework", "Foundation", "-larchive", "-lz", "-o", package_test)
        self.run(package_test)
        sample = ROOT / "plugins/examples/capture-info"
        sample_zip = plugin_directory / "capture-info.zip"
        # Reuse resolved dependencies locally; a fresh checkout resolves the
        # example's pinned PDK before compiling the real Wasm integration input.
        offline = ("--offline",) if (sample / ".mooncakes/.moon-lock").is_file() else ()
        self.run(sys.executable, ROOT / "scripts/package_plugin.py", sample, "--output", sample_zip, *offline)
        manager_test = plugin_directory / "plugin-manager"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", ROOT, "-I", self.include,
                 ROOT / "test/native/plugin-manager.m", *user_plugins, preferences / "MCToolRegistryStore.m", archive,
                 "-framework", "AppKit", "-framework", "UniformTypeIdentifiers", "-framework", "Carbon",
                 "-larchive", "-lz", "-o", manager_test)
        self.run(manager_test, plugin_worker, sample_zip)
        sparkle = install_sparkle()
        updater = shortcuts / "updater-smoke"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-F", sparkle,
                 "-I", ROOT, "-I", self.include, "-I", ROOT / "native/macos", ROOT / "test/native/updater-smoke.m",
                 ROOT / "native/macos/updates/MCUpdateController.m",
                 ROOT / "native/macos/updates/MCReleaseSource.m", archive,
                 "-framework", "AppKit", "-framework", "Security", "-framework", "Sparkle",
                 "-Wl,-rpath," + str(sparkle), "-o", updater)
        self.run(updater, sparkle / "bin/sign_update")
        update_source = shortcuts / "update-source"
        self.run("xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-F", sparkle,
                 "-I", ROOT, "-I", self.include, ROOT / "test/native/update-source.m",
                 ROOT / "native/macos/updates/MCUpdateController.m",
                 ROOT / "native/macos/updates/MCReleaseSource.m", archive,
                 "-framework", "AppKit", "-framework", "Sparkle",
                 "-Wl,-rpath," + str(sparkle), "-o", update_source)
        self.run(update_source)

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
                        help="Release label (default: <moon.mod version>-alpha.12).")
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
