#!/usr/bin/env python3
"""Build and package native desktop previews; requires only Python's stdlib."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


class DesktopBuild:
    def __init__(self, version):
        if sys.platform not in ("win32", "linux"):
            raise RuntimeError("This host supports Windows or Linux; macOS uses the AppKit builder.")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version):
            raise RuntimeError("Invalid release version.")
        self.version = version
        self.system = "windows" if sys.platform == "win32" else "linux"
        if platform.machine().lower() not in ("amd64", "x86_64"):
            raise RuntimeError("These preview packages currently target x86-64 only.")
        self.exe_name = "MoojiCut.exe" if self.system == "windows" else "moojicut"
        self.directory = ROOT / ".artifacts" / self.system
        self.bundle = ROOT / "dist" / (self.system + "-app") / "MoojiCut"
        self.executable = self.bundle / self.exe_name
        self.directory.mkdir(parents=True, exist_ok=True)
        suffix = ".exe" if self.system == "windows" else ""
        local = ROOT / ".tools/moon"
        if (local / "bin" / ("moon" + suffix)).is_file():
            self.home = local.resolve()
        elif os.environ.get("MOON_HOME"):
            self.home = Path(os.environ["MOON_HOME"]).resolve()
        else:
            binary = shutil.which("moon")
            if not binary:
                raise RuntimeError("Install MoonBit or set MOON_HOME.")
            self.home = Path(binary).resolve().parent.parent
        self.moon = self.home / "bin" / ("moon" + suffix)
        self.env = dict(os.environ, MOON_HOME=str(self.home), MOONBIT_NEW_NATIVE="0")
        manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
        self.module = re.search(r'^name\s*=\s*"([^"]+)"', manifest, re.M).group(1)
        self.compiler = self.run(self.home / "bin" / ("moonc" + suffix), "-v").strip()

    def run(self, *args, cwd=ROOT):
        print("+", " ".join(str(arg) for arg in args), flush=True)
        result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=self.env,
                                text=True, encoding="utf-8", errors="replace",
                                capture_output=True, timeout=240)
        if result.stdout:
            print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr, flush=True)
        if result.returncode:
            raise RuntimeError("{} failed (exit {}).".format(args[0], result.returncode))
        return result.stdout

    def moon_command(self, *args):
        return self.run(self.moon, "-C", ROOT, "--target-dir", self.directory / "moon", *args)

    def core_tests(self):
        self.moon_command("check", "--target", "native", "--deny-warn")
        self.moon_command("test", "--target", "native", "--release", "--deny-warn")

    def build(self):
        output = self.moon_command("build", "--target", "native", "--release", "--deny-warn", "--output-json")
        archive = None
        for line in output.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (item.get("$message_type") == "artifact" and item.get("package") == self.module
                    and item.get("target_backend") == "native"):
                candidate = ROOT / item["path"]
                if candidate.suffix in (".a", ".lib") and candidate.is_file():
                    archive = candidate
        if archive is None:
            raise RuntimeError("MoonBit did not produce the native static library.")
        with tempfile.TemporaryDirectory(prefix="build-", dir=self.directory) as name:
            staging = Path(name) / "MoojiCut"
            staging.mkdir()
            executable = staging / self.exe_name
            source = ROOT / "native" / self.system
            if self.system == "windows":
                resource = Path(name) / "app.res"
                self.run("rc", "/nologo", "/fo" + str(resource), "resources.rc", cwd=source)
                self.run("cl", "/nologo", "/std:c11", "/utf-8", "/MT", "/O2", "/W4",
                         "/DUNICODE", "/D_UNICODE", '/DMOOJICUT_VERSION="' + self.version + '"',
                         "/I" + str(self.home / "include"), *sorted(source.glob("*.c")), archive, resource,
                         "/Fo" + str(Path(name)) + os.sep, "/Fe" + str(executable),
                         "/link", "/SUBSYSTEM:WINDOWS", "/ENTRY:wWinMainCRTStartup", "/MANIFEST:NO",
                         "comctl32.lib", "shell32.lib", "user32.lib", "kernel32.lib", "oldnames.lib",
                         "gdi32.lib", "advapi32.lib", "ole32.lib", "uuid.lib", "dbghelp.lib")
                dependencies = self.run("dumpbin", "/nologo", "/dependents", executable)
            else:
                flags = shlex.split(self.run("pkg-config", "--cflags", "--libs", "gtk+-3.0", "ayatana-appindicator3-0.1"))
                self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                         '-DMOOJICUT_VERSION="' + self.version + '"', "-I", self.home / "include",
                         source / "main.c", archive, *flags, "-lm", "-o", executable)
                self.run("strip", executable)
                dependencies = self.run("ldd", executable)
                if "not found" in dependencies:
                    raise RuntimeError("Native Linux dependency is missing.")
                shutil.copy2(source / "launch.sh", staging / "launch.sh")
                (staging / "launch.sh").chmod(0o755)
            if re.search(r"Electron|Chromium|WebKit|libnode", dependencies, re.I):
                raise RuntimeError("Unexpected browser runtime in desktop binary.")
            shutil.copy2(ROOT / "assets/brand/mooji-cut/app-icon-rounded-preview.png", staging / "moojicut.png")
            revision = self.run("git", "rev-parse", "HEAD").strip()
            dirty = bool(self.run("git", "status", "--porcelain").strip())
            self.metadata = {"version": self.version, "platform": self.system, "arch": "x64",
                             "commit": revision, "workingTreeDirty": dirty,
                             "compilerVersion": self.compiler, "signing": "unsigned",
                             "minimumOS": "Windows 10" if self.system == "windows" else "Ubuntu 22.04 (glibc 2.35)",
                             "scope": "Native tray, preferences and shortcut configuration; capture and recording are not connected.",
                             "dependencies": dependencies}
            (staging / "build.json").write_text(json.dumps(self.metadata, indent=2) + "\n", encoding="utf-8")
            (staging / "README.txt").write_text(self.instructions(), encoding="utf-8")
            self.bundle.parent.mkdir(parents=True, exist_ok=True)
            previous = Path(name) / "previous"
            if self.bundle.exists():
                self.bundle.rename(previous)
            try:
                staging.rename(self.bundle)
            except OSError:
                if previous.exists():
                    previous.rename(self.bundle)
                raise

    def instructions(self):
        shared = ("Mooji Cut " + self.version + "\n\n"
                  "原生桌面预览版：托盘、设置、快捷键配置及 MoonBit 编辑核心。\n"
                  "截图、录屏、标注/剪辑和复制导出的完整流程尚未接通。\n"
                  "关闭设置会保留托盘；从托盘菜单选择退出以结束应用。\n\n")
        if self.system == "windows":
            return shared + ("适用 Windows 10/11 x64（Intel/AMD）。解压全部文件，双击 MoojiCut.exe。\n"
                             "在任务栏隐藏图标区找到 Mooji Cut，双击或右键打开设置。\n"
                             "免安装，无需 Node、Python 或 MoonBit 工具链。程序未进行代码签名，\n"
                             "Windows 可能显示未知发布者提示。仅从项目 Release 下载并核对 SHA256。\n"
                             "命令行 MoojiCut.exe --preferences 可直接打开设置。\n")
        return shared + ("适用 Ubuntu 22.04/24.04 x86_64 及兼容发行版（glibc >= 2.35）。\n"
                         "需要 GTK 3 和 Ayatana AppIndicator：\n"
                         "  sudo apt install libgtk-3-0 libayatana-appindicator3-1\n"
                         "解压后运行 ./launch.sh 打开设置；./moojicut 仅启动托盘。\n"
                         "部分 GNOME 桌面需要 AppIndicator 扩展才能显示托盘；没有扩展也可用\n"
                         "./launch.sh 重新打开设置。包不自动安装依赖或修改桌面配置。\n")

    def verify_binary(self, executable):
        self.run(executable, "--self-test")

    def smoke(self):
        self.verify_binary(self.executable)
        self.run(self.executable, "--smoke")

    def test(self):
        self.core_tests()
        self.build()
        self.verify_binary(self.executable)

    def release(self):
        self.core_tests()
        self.build()
        self.smoke()
        releases = ROOT / "dist/releases"
        releases.mkdir(parents=True, exist_ok=True)
        stem = "moojicut-{}-{}-x64".format(self.version, self.system)
        suffix = ".zip" if self.system == "windows" else ".tar.gz"
        with tempfile.TemporaryDirectory(prefix="package-", dir=self.directory) as name:
            archive = Path(name) / (stem + suffix)
            if self.system == "windows":
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
                    for path in sorted(self.bundle.rglob("*")):
                        if path.is_file():
                            output.write(path, path.relative_to(self.bundle.parent).as_posix())
            else:
                with tarfile.open(archive, "w:gz") as output:
                    output.add(self.bundle, arcname="MoojiCut")
            extracted = Path(name) / "unpacked"
            extracted.mkdir()
            if self.system == "windows":
                with zipfile.ZipFile(archive) as package:
                    if package.testzip():
                        raise RuntimeError("Release ZIP failed integrity check.")
                    package.extractall(extracted)
            else:
                with tarfile.open(archive) as package:
                    package.extractall(extracted, filter="data")
            self.verify_binary(extracted / "MoojiCut" / self.exe_name)
            if (extracted / "MoojiCut" / self.exe_name).read_bytes() != self.executable.read_bytes():
                raise RuntimeError("Packaged executable differs from the tested binary.")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            metadata = dict(self.metadata, archive=archive.name, sha256=checksum,
                            checks=["moon-check", "moon-tests", "native-core", "native-ui-smoke", "unpacked-native-core"])
            shutil.copy2(archive, releases / archive.name)
            (releases / (archive.name + ".sha256")).write_text(checksum + "  " + archive.name + "\n", encoding="utf-8")
            (releases / (stem + ".build.json")).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        print("Release:", releases / archive.name, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "dev", "test", "smoke", "release"))
    parser.add_argument("--release-version", default="0.1.0-alpha.2")
    args = parser.parse_args()
    if sys.platform == "darwin":
        from native import NativeBuild
        native = NativeBuild(args.release_version)
        if args.command == "dev":
            native.build()
            native.run("/usr/bin/open", native_path(), "--args", "--preferences")
        else:
            getattr(native, args.command)()
        return
    native = DesktopBuild(args.release_version)
    if args.command == "dev":
        native.build()
        subprocess.Popen([str(native.executable), "--preferences"], cwd=native.bundle, env=native.env)
    elif args.command == "smoke":
        native.build()
        native.smoke()
    else:
        getattr(native, args.command)()


def native_path():
    from native import APP
    return APP


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit("Error: {}".format(error))
