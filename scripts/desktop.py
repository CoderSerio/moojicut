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
from install_extism import VERSION as EXTISM_VERSION, digest, install as install_extism, notice_names
from native_modules import native_sources, object_path

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
        self.plugin_worker_name = "MoojiPluginWorker.exe" if self.system == "windows" else "MoojiPluginWorker"
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
        self.env["MOOJICUT_MEDIA_CACHE_DIR"] = str(self.directory / "media-cache")
        manifest = (ROOT / "moon.mod").read_text(encoding="utf-8")
        self.module = re.search(r'^name\s*=\s*"([^"]+)"', manifest, re.M).group(1)
        self.compiler = self.run(self.home / "bin" / ("moonc" + suffix), "-v").strip()

    def run(self, *args, cwd=ROOT, env=None, timeout=240, log=None):
        print("+", " ".join(str(arg) for arg in args), flush=True)
        def output(stdout, stderr, suffix=""):
            # TimeoutExpired may retain bytes even with text=True. Preserve
            # the last real fixture step before raising the original failure.
            def decoded(value):
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
            stdout, stderr = decoded(stdout), decoded(stderr)
            if stdout:
                print(stdout, end="", flush=True)
            if stderr or suffix:
                print(stderr + suffix, end="", file=sys.stderr, flush=True)
            if log is not None:
                Path(log).write_text(stdout + "\nSTDERR:\n" + stderr + suffix, encoding="utf-8")
        try:
            result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=self.env if env is None else env,
                                    text=True, encoding="utf-8", errors="replace",
                                    capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            output(error.stdout, error.stderr, "\nTIMEOUT after " + str(timeout) + " seconds\n")
            raise
        output(result.stdout, result.stderr)
        if result.returncode:
            raise RuntimeError("{} failed (exit {}).".format(args[0], result.returncode))
        return result.stdout

    def moon_command(self, *args):
        return self.run(self.moon, "-C", ROOT, "--target-dir", self.directory / "moon", *args)

    def core_tests(self):
        self.run(sys.executable, "-m", "unittest", "discover", "-s", ROOT / "test/build", "-v")
        self.moon_command("check", "--target", "native", "--deny-warn")
        self.moon_command("test", "--target", "native", "--release", "--deny-warn")
        if self.system == "linux":
            # Private GTestDBus server: verifies the Wayland shortcut protocol
            # without contacting a desktop portal or requesting user permission.
            fixture = self.directory / "portal-shortcuts-test"
            flags = shlex.split(self.run("pkg-config", "--cflags", "--libs", "gio-2.0"))
            self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", ROOT,
                     ROOT / "test/native/linux-global-shortcuts-portal.c",
                     ROOT / "platform/linux/input/portal_shortcuts.c", *flags, "-o", fixture)
            self.run(fixture)

    def media_tests(self):
        self.prepare_media()
        self.media.test(self.core_archive, self.home)

    def prepare_media(self):
        if hasattr(self, "media"):
            return
        from media_tests import MediaTests
        self.media = MediaTests(self.directory / "media-tests", self.env)
        if self.system == "linux":
            # GTK/GIO remain the system's libraries; all GStreamer/libav .pc
            # files must resolve through the same private SDK used by fixtures.
            self.env["PKG_CONFIG_PATH"] = self.media.env["PKG_CONFIG_PATH"]

    def link_plugin_program(self, sources, executable, *, cwd, link_flags=(), includes=()):
        if self.system == "windows":
            self.run("cl", "/nologo", "/utf-8", "/MT", "/O2", "/std:c11", "/W4", "/WX",
                     "/I" + str(ROOT), *("/I" + str(path) for path in includes), *sources,
                     "/Fe" + str(executable), "/link", "/SUBSYSTEM:CONSOLE", *link_flags, cwd=cwd)
        else:
            include_flags = [flag for path in includes for flag in ("-I", path)]
            self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", ROOT,
                     *include_flags, *sources, *link_flags, "-o", executable, cwd=cwd)

    def build_plugin_worker(self, bundle, directory):
        windows = self.system == "windows"
        target = "x86_64-pc-windows-msvc" if windows else "x86_64-unknown-linux-gnu"
        sdk = install_extism(target)
        # Keep libextism.so out of runtime/plugins, which GStreamer scans.
        library_path = "extism.dll" if windows else "runtime/extism/libextism.so"
        library = bundle / library_path
        relative_files = {library_path, self.plugin_worker_name}
        notices = {"runtime/licenses/extism/" + name: sdk / name for name in notice_names(target)}
        relative_files.update(notices)
        if any((bundle / path).exists() for path in relative_files):
            raise RuntimeError("Plugin runtime collides with a desktop bundle file.")
        library.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sdk / library.name, library)
        for path, source in notices.items():
            destination = bundle / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        worker = bundle / self.plugin_worker_name
        flags = [sdk / "extism.dll.lib"] if windows else [
            "-L", library.parent, "-lextism", "-Wl,-rpath,$ORIGIN/runtime/extism"]
        self.link_plugin_program(native_sources(self.system, "shared.plugin_host.worker"), worker, cwd=directory,
                                 link_flags=flags, includes=[sdk])
        if windows:
            from gstreamer_runtime import CRT_DLLS, pe_dependencies

            if "extism.dll" not in pe_dependencies(worker):
                raise RuntimeError("Plugin worker did not link the private Extism DLL.")
            for name in pe_dependencies(library) & CRT_DLLS:
                # The media payload already supplies signed VS Redist files
                # with provenance and checksum. Require the same local CRT.
                if not (self.media.runtime_payload / name).is_file():
                    raise RuntimeError("Plugin runtime requires an unbundled Microsoft CRT file: " + name)
        else:
            dependencies = self.run("ldd", worker, env=self.app_test_environment())
            selected = re.search(r"^\s*libextism\.so\s+=>\s+(.+?)\s+\(0x[\da-f]+\)\s*$", dependencies, re.M)
            if not selected or Path(selected[1]).resolve() != library.resolve() or "not found" in dependencies:
                raise RuntimeError("Plugin worker did not resolve its private Extism library.")
        self.plugin_payload = {path: digest(bundle / path) for path in sorted(relative_files)}

    def build(self):
        self.run(sys.executable, ROOT / "scripts/check_module_boundaries.py")
        self.run(sys.executable, ROOT / "scripts/generate_icons.py", "--check")
        sources = native_sources(self.system)
        self.prepare_media()
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
        self.core_archive = archive
        with tempfile.TemporaryDirectory(prefix="build-", dir=self.directory) as name:
            staging = Path(name) / "MoojiCut"
            staging.mkdir()
            executable = staging / self.exe_name
            source = ROOT / "native" / self.system
            if self.system == "windows":
                # MoonBit exports make LINK emit .lib/.exp sidecars. Keep all
                # linker output outside the end-user bundle and copy only EXE.
                linked_executable = Path(name) / self.exe_name
                resource = Path(name) / "app.res"
                self.run("rc", "/nologo", "/fo" + str(resource), "resources.rc", cwd=source)
                common = ["/nologo", "/utf-8", "/MT", "/O2", "/W4", "/DUNICODE", "/D_UNICODE",
                          '/DMOOJICUT_VERSION="' + self.version + '"', "/I" + str(self.home / "include"),
                          "/I" + str(ROOT), *self.media.includes]
                objects = []
                for unit in sources:
                    obj = object_path(name, unit)
                    obj.parent.mkdir(parents=True, exist_ok=True)
                    language = ["/std:c++17", "/EHsc"] if unit.suffix == ".cpp" else ["/std:c11"]
                    self.run("cl", *common, *language, "/Fo" + str(obj), "/c", unit)
                    objects.append(obj)
                self.run("cl", "/nologo", *objects, archive, resource, "/Fe" + str(linked_executable),
                         "/link", "/SUBSYSTEM:WINDOWS", "/ENTRY:wWinMainCRTStartup", "/MANIFEST:NO",
                         "/IMPLIB:" + str(Path(name) / "MoojiCut.lib"),
                         "comctl32.lib", "shell32.lib", "user32.lib", "kernel32.lib", "oldnames.lib",
                         "gdi32.lib", "gdiplus.lib", "advapi32.lib", "ole32.lib", "uuid.lib", "dbghelp.lib",
                         "mfplat.lib", "mfreadwrite.lib", "mfuuid.lib", "mf.lib", "propsys.lib",
                         "winhttp.lib", "bcrypt.lib", "comdlg32.lib", "imm32.lib", "oleacc.lib", "oleaut32.lib",
                         *self.media.libraries)
                shutil.copy2(linked_executable, executable)
                shutil.copytree(self.media.runtime_payload, staging, dirs_exist_ok=True)
                dependencies = self.run("dumpbin", "/nologo", "/dependents", executable)
            else:
                flags = shlex.split(self.run("pkg-config", "--cflags", "--libs", "gtk+-3.0", "ayatana-appindicator3-0.1", "libcurl",
                                            "gstreamer-1.0", "gstreamer-pbutils-1.0", "libportal-gtk3", "gio-unix-2.0", "x11"))
                self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                         '-DMOOJICUT_VERSION="' + self.version + '"', "-I", self.home / "include",
                         "-I", ROOT, *self.media.includes, *sources, archive, *flags,
                         *self.media.libraries, "-lm", "-o", executable)
                self.run("strip", executable)
                shutil.copytree(self.media.runtime_payload, staging, dirs_exist_ok=True)
                dependencies = self.run("ldd", executable, env=self.app_test_environment())
                if "not found" in dependencies:
                    raise RuntimeError("Native Linux dependency is missing.")
                shutil.copy2(source / "launch.sh", staging / "launch.sh")
                (staging / "launch.sh").chmod(0o755)
            if re.search(r"Electron|Chromium|WebKit|libnode", dependencies, re.I):
                raise RuntimeError("Unexpected browser runtime in desktop binary.")
            if re.search(r"extism", dependencies, re.I):
                raise RuntimeError("The GUI executable must not link the plugin engine.")
            self.build_plugin_worker(staging, Path(name))
            shutil.copy2(ROOT / "assets/brand/mooji-cut/app-icon-rounded-preview.png", staging / "moojicut.png")
            revision = self.run("git", "rev-parse", "HEAD").strip()
            dirty = bool(self.run("git", "status", "--porcelain").strip())
            self.metadata = {"version": self.version, "platform": self.system, "arch": "x64",
                             "commit": revision, "workingTreeDirty": dirty,
                             "compilerVersion": self.compiler, "signing": "unsigned",
                             "minimumOS": "Windows 10" if self.system == "windows" else "Ubuntu 22.04 (glibc 2.35)",
                             "scope": self.scope(),
                             "pluginWorker": {"extismVersion": EXTISM_VERSION, "files": self.plugin_payload},
                             "dependencies": dependencies}
            (staging / "build.json").write_text(json.dumps(self.metadata, indent=2) + "\n", encoding="utf-8")
            (staging / "README.txt").write_text(self.instructions(), encoding="utf-8")
            shutil.copy2(ROOT / "LICENSE", staging / "LICENSE.txt")
            shutil.copy2(ROOT / "assets/icons/lucide/LICENSE", staging / "Lucide-LICENSE.txt")
            self.verify_bundle(staging)
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

    def scope(self):
        if self.system == "windows":
            return ("Native tray and configurable global shortcuts; frozen-desktop inline screenshot editing, "
                    "editable text, RGBA annotation styles, in-place pinned images with configurable zoom/opacity "
                    "and global hide/recover/click-through keys, confirmed image copy; "
                    "silent selected-region recording; shared MoonBit v2 timeline with non-destructive edits, "
                    "gaps, linked/independent audio, waveform, speed, crop, recoverable drafts and MP4 export.")
        return ("Native tray and preferences; X11 frozen-desktop inline editing or Wayland portal image editing; "
                "editable text, RGBA annotation styles, pinned images with configurable zoom/opacity keys "
                "and X11 global hide/recover/click-through keys, confirmed image copy. "
                "Wayland positioning/keep-above is compositor-dependent; click-through is disabled. "
                "Silent X11 selected-region or Wayland ScreenCast/PipeWire recording to WebM; "
                "shared countdown/stop controls. Screenshot/record/stop shortcuts use native X11 registration "
                "or the Wayland GlobalShortcuts portal when provided by the compositor. Shared MoonBit v2 editor "
                "with embedded preview, non-destructive timeline/gaps/audio/speed/crop, waveform, saved drafts and MP4 export.")

    def verify_bundle(self, directory):
        expected = {self.exe_name, "moojicut.png", "build.json", "README.txt", "LICENSE.txt", "Lucide-LICENSE.txt"}
        if self.system == "linux":
            expected.add("launch.sh")
        directories = set()
        for item in self.media.runtime_payload.rglob("*"):
            relative = item.relative_to(self.media.runtime_payload).as_posix()
            if item.is_dir():
                directories.add(relative)
            else:
                expected.add(relative)
                copied = directory / relative
                if not copied.is_file() or hashlib.sha256(copied.read_bytes()).digest() != hashlib.sha256(item.read_bytes()).digest():
                    raise RuntimeError("Packaged media runtime differs from verified payload: " + relative)
        for relative, checksum in self.plugin_payload.items():
            expected.add(relative)
            parent = Path(relative).parent
            directories.update(path.as_posix() for path in (parent, *parent.parents) if path != Path("."))
            copied = directory / relative
            if not copied.is_file() or digest(copied) != checksum:
                raise RuntimeError("Packaged plugin worker or runtime differs from the tested build: " + relative)
        actual = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()}
        if actual != expected:
            raise RuntimeError("Unexpected package contents: extra={}, missing={}.".format(
                sorted(actual - expected), sorted(expected - actual)))
        actual_directories = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_dir()}
        if actual_directories != directories or any(path.is_symlink() or not (path.is_file() or path.is_dir())
                                                   for path in directory.rglob("*")):
            raise RuntimeError("Package contains an unexpected directory, symlink or special file.")

    def instructions(self):
        shared = ("Mooji Cut " + self.version + "\n\n"
                  "以 MoonBit 为核心的本地截图与录屏工具。\n"
                  "截图后可添加矩形、箭头、文字和实心遮挡，确认后才复制图片。\n"
                  "框选后直接标注；点击文字工具后在画面输入，双击已有文字继续编辑。\n"
                  "选中文字可拖动、拖拽控制点缩放；工具条第二行可调整颜色、不透明度、字号或线宽。\n"
                  "各工具分别记住本次编辑中的样式；修改已选标注不会改变新建标注的默认样式。\n"
                  "点击图钉将结果固定在当前选区的位置。双击或选中后按 Esc 关闭。\n"
                  "选中贴图后按 + / - 缩放，Ctrl + / - 调透明度。贴图按键可在设置中更改。\n"
                  "Windows / Linux X11：Ctrl + Shift + H 切换选中贴图的隐藏状态；\n"
                  "没有选中时，若有隐藏项则恢复，否则隐藏全部。恢复时保留原来的不透明度。\n"
                  "Ctrl + Shift + P 切换鼠标穿透；穿透期间仅响应解除穿透，不响应 Esc 等操作。\n"
                  "隐藏和穿透恢复键支持全局响应，托盘菜单也提供恢复入口。\n"
                  "设置中可停用贴图：关闭当前全部贴图并释放按键，重新启用会保留配置。\n"
                  "设置 → 更新可检查 GitHub Releases、下载并校验更新包。\n"
                  "下载完成后请退出旧版本，再手动解压并运行新版本。\n"
                  "关闭设置会保留托盘；从托盘菜单选择退出以结束应用。\n\n")
        if self.system == "windows":
            return shared + ("适用 Windows 10/11 x64（Intel/AMD）。解压全部文件，双击 MoojiCut.exe。\n"
                             "在任务栏隐藏图标区找到 Mooji Cut，双击或右键打开设置。\n"
                             "从托盘菜单或可配置的全局快捷键启动截图、开始录屏和停止录屏。\n"
                             "录屏先自由框选区域，3 秒倒计时后开始；倒计时可按 Esc 取消。\n"
                             "最高 1920 × 1080 / 15 fps；本版不录声音。托盘或停止快捷键结束录制。\n"
                             "停止后打开共享时间线：分割、拖动片段留空隙、修剪、变速、裁画面与撤销。\n"
                             "编辑只影响预览和草稿；点击保存选择 MP4 导出位置，原始录制保留。\n"
                             "已有音轨支持波形、分离与独立移动；本版新录制仍不含声音。\n"
                             "草稿保存在 %LOCALAPPDATA%\\MoojiCut\\Drafts，可从托盘继续编辑上次录屏。\n"
                             "Windows N 版录屏需要系统媒体功能包。\n\n"
                             "免安装，无需 Node、Python 或 MoonBit 工具链。程序未进行代码签名，\n"
                             "Windows 可能显示未知发布者提示。仅从项目 Release 下载并核对 SHA256。\n"
                             "命令行 MoojiCut.exe --preferences 可直接打开设置。\n")
        return shared + ("本包针对 Ubuntu 22.04 x86_64 构建，随包提供固定版本的媒体运行库。\n"
                         "请完整解压，保留 runtime 文件夹。其它发行版的实际运行按发布说明验收。\n"
                         "需要 GTK 3、Ayatana AppIndicator、libcurl、libportal 和系统音频服务：\n"
                         "  sudo apt install libgtk-3-0 libayatana-appindicator3-1 libcurl4 libportal1 libportal-gtk3-1 libpulse0 libpipewire-0.3-0\n"
                         "解压后运行 ./launch.sh 打开设置；./moojicut 仅启动托盘。\n"
                         "从托盘菜单或设置中启动截图，也可运行 ./moojicut --capture。\n"
                         "X11 支持桌面框选；Wayland 使用系统截图门户，需要可用的\n"
                         "xdg-desktop-portal 和当前桌面对应的后端。\n"
                         "Wayland 门户返回图片后在无边框界面编辑；窗口位置、跨工作区与置顶效果\n"
                         "由桌面合成器决定，无法保证与 X11 的桌面原位编辑完全相同。\n"
                         "Wayland 暂不启用鼠标穿透；全局贴图恢复按键仅支持 X11。\n"
                         "录屏：X11 自由框选区域；Wayland 通过系统录屏门户选择屏幕/窗口，\n"
                         "需要当前桌面的 ScreenCast portal 后端与 PipeWire。3 秒倒计时后开始，\n"
                         "可从托盘停止，保存静音 WebM 原片；最高 1920×1080 / 15fps。\n"
                         "停止后打开共享时间线，可分割、移动、修剪、变速和裁画面，保存时导出 MP4。\n"
                         "原片与 edit-v2.json 草稿保存在视频目录的 Mooji Cut 子目录；托盘可继续编辑上次录屏。\n"
                         "截图/录屏快捷键在 X11 直接注册；Wayland 需要\n"
                         "桌面的 GlobalShortcuts portal，在设置中申请授权，实际组合由系统确认。\n"
                         "后端不支持时仍可从托盘操作，或在桌面设置中将快捷键绑定到解压目录下\n"
                         "moojicut --capture、--record 或 --stop 的完整路径。\n"
                         "部分 GNOME 桌面需要 AppIndicator 扩展才能显示托盘；没有扩展也可用\n"
                         "./launch.sh 重新打开设置。包不自动安装依赖或修改桌面配置。\n")

    def verify_binary(self, executable):
        self.run(executable, "--self-test", cwd=self.directory, env=self.app_test_environment())

    def app_test_environment(self):
        environment = dict(self.env)
        for key in tuple(environment):
            if key.startswith(("GST_", "GSTREAMER_", "LD_")):
                environment.pop(key)
        invalid = str(self.directory / "unavailable-system-sdk")
        environment.update(GST_PLUGIN_PATH_1_0=invalid, GST_PLUGIN_SYSTEM_PATH_1_0=invalid,
                           GST_PLUGIN_SCANNER_1_0=invalid, GST_REGISTRY_1_0=invalid,
                           GST_REGISTRY_UPDATE="no", GST_PLUGIN_FEATURE_RANK="openh264enc:NONE,avenc_aac:NONE")
        if self.system == "windows":
            windows = Path({key.casefold(): value for key, value in environment.items()}.get("systemroot", r"C:\Windows"))
            environment["PATH"] = os.pathsep.join(map(str, (windows / "System32", windows)))
            # Production bootstrap must override these itself. Do not supply
            # the Python runtime_environment used by lower-level fixtures.
            invalid = str(self.directory / "unavailable-system-sdk")
            environment.update(GST_PLUGIN_PATH_1_0=invalid, GST_PLUGIN_SYSTEM_PATH_1_0=invalid,
                               GST_PLUGIN_SCANNER_1_0=invalid, GST_REGISTRY_1_0=invalid,
                               GST_REGISTRY_UPDATE="no", GST_PLUGIN_FEATURE_RANK="openh264enc:NONE,avenc_aac:NONE",
                               GIO_MODULE_DIR=invalid, GIO_EXTRA_MODULES=invalid,
                               GSETTINGS_SCHEMA_DIR=invalid)
        else:
            # Prove the packaged app and window fixture cannot borrow an SDK
            # helper through the inherited build PATH.
            environment["PATH"] = "/usr/bin:/bin"
            environment.pop("MOOJICUT_LINUX_MEDIA_SDK", None)
        return environment

    def smoke(self):
        self.verify_binary(self.executable)
        self.run(self.executable, "--smoke", env=self.app_test_environment())
        self.canvas_smoke()
        self.video_smoke()
        self.plugin_worker_smoke(self.bundle)
        self.plugin_store_smoke()

    def plugin_sample_path(self):
        if not hasattr(self, "plugin_sample"):
            fixture_path = self.env.get("MOOJICUT_PLUGIN_FIXTURE")
            if fixture_path:
                self.plugin_sample = (ROOT / fixture_path).resolve()
            else:
                directory = Path(tempfile.mkdtemp(prefix="plugin-sample-", dir=self.directory))
                sample = directory / "capture-info.zip"
                project = ROOT / "plugins/examples/capture-info"
                self.run(sys.executable, ROOT / "scripts/package_plugin.py", project, "--output", sample)
                self.plugin_sample = sample
        return self.plugin_sample

    def plugin_worker_smoke(self, bundle):
        from plugin_worker_fixture import prepare_sample, verify_results

        directory = Path(tempfile.mkdtemp(prefix="plugin-worker-", dir=self.directory))
        if not hasattr(self, "plugin_fixture_executable"):
            windows = self.system == "windows"
            adapter = "platform.plugin_host" if windows else "shared.plugin_host.posix"
            executable = self.media.executables / ("plugin-worker-host.exe" if windows else "plugin-worker-host")
            self.link_plugin_program(
                [*native_sources(self.system, adapter), ROOT / "test/native/plugin-worker-host.c"],
                executable, cwd=directory, link_flags=[] if windows else ["-pthread"])
            self.plugin_fixture_executable = executable
        sample = self.plugin_sample_path()
        output = directory / "sample with spaces"
        wasm = prepare_sample(sample, output)
        print("Packaged MoonBit plugin fixture SHA-256:", digest(sample), flush=True)
        self.run(self.plugin_fixture_executable, bundle / self.plugin_worker_name, wasm, output,
                 cwd=directory, env=self.app_test_environment(), timeout=45, log=directory / "run.log")
        verify_results(output)

    def plugin_store_smoke(self):
        directory = Path(tempfile.mkdtemp(prefix="plugin-store-", dir=self.directory))
        windows = self.system == "windows"
        adapter = "platform.plugin_host" if windows else "shared.plugin_host.storage"
        fixture = ROOT / "test/native" / ("plugin-package-store-windows.c" if windows else "plugin-package-store-posix.c")
        executable = directory / ("plugin-package-store.exe" if windows else "plugin-package-store")
        self.link_plugin_program([*native_sources(self.system, adapter), fixture], executable, cwd=directory)
        sample = self.plugin_sample_path()
        self.run(executable, sample, digest(sample), cwd=directory, env=self.app_test_environment(),
                 timeout=45, log=directory / "run.log")

    def video_smoke(self, prepared=False):
        if not hasattr(self.media, "fixtures"):
            if prepared:
                raise RuntimeError("Media fixtures did not compile; cannot run the editor window fixture.")
            self.media_tests()
        directory = Path(tempfile.mkdtemp(prefix="video-editor-", dir=self.directory))
        sources = native_sources(self.system, "platform.app", "platform.media")
        fixture = ROOT / "test/native" / (self.system + "-video-editor.c")
        executable = self.media.executables / ("video-editor.exe" if self.system == "windows" else "video-editor")
        if self.system == "windows":
            objects = []
            for unit in [*sources, fixture]:
                obj = object_path(directory, unit); obj.parent.mkdir(parents=True, exist_ok=True)
                self.run("cl", "/nologo", "/utf-8", "/MT", "/O2", "/W4", "/WX", "/std:c11",
                         "/DUNICODE", "/D_UNICODE", "/I" + str(self.home / "include"),
                         "/I" + str(ROOT), *self.media.includes, "/Fo" + str(obj), "/c", unit)
                objects.append(obj)
            self.run("cl", "/nologo", *objects, self.core_archive, "/Fe" + str(executable),
                     "/link", "/SUBSYSTEM:CONSOLE", "/MANIFEST:EMBED",
                     "/MANIFESTINPUT:" + str(ROOT / "native/windows/app.manifest"),
                     "/IMPLIB:" + str(directory / "video-editor.lib"),
                     *self.media.libraries, "user32.lib", "kernel32.lib", "gdi32.lib", "comctl32.lib",
                     "ole32.lib", "oleacc.lib", "oleaut32.lib", "imm32.lib", "uuid.lib", "oldnames.lib",
                     "advapi32.lib", "dbghelp.lib", "shell32.lib")
        else:
            flags = shlex.split(self.run("pkg-config", "--cflags", "--libs", "gtk+-3.0"))
            self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                     "-I", self.home / "include", "-I", ROOT, *self.media.includes,
                     *sources, fixture, self.core_archive, *flags, *self.media.libraries, "-lm", "-o", executable)
        self.run(executable, self.media.directory / "media/generated-source.mkv", directory,
                 cwd=self.directory, env=self.app_test_environment(), log=directory / "run.log")

    def canvas_smoke(self):
        # Exercise the shared v2 editor through real native input/painting and
        # accessibility. This standalone fixture is not a shipped editor host.
        # Its sources use the same explicit ownership/dependency manifest.
        directory = self.directory / "shared-canvas"
        directory.mkdir(exist_ok=True)
        sources = native_sources(self.system, "platform.graphics")
        fixture = ROOT / "test/native" / (self.system + "-shared-canvas.c")
        executable = directory / ("shared-canvas.exe" if self.system == "windows" else "shared-canvas")
        if self.system == "windows":
            objects = []
            for unit in [*sources, fixture]:
                obj = object_path(directory, unit)
                obj.parent.mkdir(parents=True, exist_ok=True)
                self.run("cl", "/nologo", "/utf-8", "/MT", "/O2", "/W4", "/WX", "/std:c11",
                         "/DUNICODE", "/D_UNICODE", "/I" + str(self.home / "include"),
                         "/I" + str(ROOT), "/Fo" + str(obj), "/c", unit)
                objects.append(obj)
            self.run("cl", "/nologo", *objects, self.core_archive, "/Fe" + str(executable),
                     "/link", "/SUBSYSTEM:CONSOLE", "/IMPLIB:" + str(directory / "shared-canvas.lib"),
                     "user32.lib", "kernel32.lib", "gdi32.lib", "comctl32.lib", "ole32.lib",
                     "oleacc.lib", "oleaut32.lib", "imm32.lib", "uuid.lib", "oldnames.lib", "advapi32.lib", "dbghelp.lib")
        else:
            flags = shlex.split(self.run("pkg-config", "--cflags", "--libs", "gtk+-3.0"))
            self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                     "-I", self.home / "include", "-I", ROOT, *sources, fixture,
                     self.core_archive, *flags, "-lm", "-o", executable)
        self.run(executable, directory)

    def test(self):
        self.core_tests()
        self.build()
        self.runtime_tests()

    def runtime_tests(self, app_smoke=False):
        # Each gate owns its process/window/output. Run independent GUI checks
        # even if one media fixture fails, then reject the whole build. This
        # collects target-platform failures in one CI run without shipping a
        # partially tested package or recompiling a failed fixture twice.
        checks = [("media", self.media_tests),
                  ("native-core", lambda: self.verify_binary(self.executable))]
        if app_smoke:
            checks.append(("native-ui-smoke", lambda: self.run(self.executable, "--smoke", env=self.app_test_environment())))
        checks.extend((("shared-canvas", self.canvas_smoke),
                       ("video-editor", lambda: self.video_smoke(prepared=True)),
                       ("plugin-worker", lambda: self.plugin_worker_smoke(self.bundle)),
                       ("plugin-store", self.plugin_store_smoke)))
        results, failures = {}, []
        for name, action in checks:
            try:
                action()
            except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                results[name] = {"result": "failed", "error": str(error)}
                failures.append(name)
                print("FAILED " + name + ": " + str(error), file=sys.stderr, flush=True)
            else:
                results[name] = {"result": "passed"}
        report = {"result": "failed" if failures else "passed", "checks": results}
        (self.directory / "runtime-checks.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if failures:
            raise RuntimeError("Desktop runtime checks failed: " + ", ".join(failures))

    def release(self):
        self.core_tests()
        self.build()
        self.runtime_tests(app_smoke=True)
        self.verify_bundle(self.bundle)
        releases = ROOT / "dist/releases"
        releases.mkdir(parents=True, exist_ok=True)
        stem = "moojicut-{}-{}-x64".format(self.version, self.system)
        suffix = ".zip" if self.system == "windows" else ".tar.gz"
        with tempfile.TemporaryDirectory(prefix="package-", dir=self.directory) as name:
            archive = Path(name) / (stem + suffix)
            if self.system == "windows":
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
                    for path in sorted(self.bundle.rglob("*")):
                        if path.is_file() or path.is_dir():
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
            self.verify_bundle(extracted / "MoojiCut")
            self.verify_binary(extracted / "MoojiCut" / self.exe_name)
            self.plugin_worker_smoke(extracted / "MoojiCut")
            if (extracted / "MoojiCut" / self.exe_name).read_bytes() != self.executable.read_bytes():
                raise RuntimeError("Packaged executable differs from the tested binary.")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            metadata = dict(self.metadata, archive=archive.name, sha256=checksum,
                            checks=["moon-check", "moon-tests", "gst-media", "mp4-mux", "media-worker", "media-waveform", "video-editor-host",
                                    "native-core", "native-ui-smoke", "shared-canvas", "video-editor", "plugin-worker", "plugin-store",
                                    "unpacked-native-core", "unpacked-plugin-worker"])
            shutil.copy2(archive, releases / archive.name)
            (releases / (archive.name + ".sha256")).write_text(checksum + "  " + archive.name + "\n", encoding="utf-8")
            (releases / (stem + ".build.json")).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        print("Release:", releases / archive.name, flush=True)
        if self.system == "linux" and self.env.get("MOOJICUT_COMPATIBILITY_KIT") == "1":
            # CI reuses these exact Ubuntu 22 binaries against the same release
            # runtime on Ubuntu 24. Test executables never enter the user bundle.
            from linux_package_check import write_fixture_kit
            kit = self.directory / "compatibility/fixture-kit.tar.gz"
            if kit.exists():
                kit.unlink()
            write_fixture_kit(kit, releases / archive.name, self.metadata["commit"], self.media.executables,
                              self.plugin_sample)


def main():
    if sys.platform == "darwin":
        from native import main as native_main
        native_main()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "dev", "test", "smoke", "release"))
    parser.add_argument("--release-version", default="0.1.0-alpha.16")
    args = parser.parse_args()
    native = DesktopBuild(args.release_version)
    if args.command == "dev":
        native.build()
        subprocess.Popen([str(native.executable), "--preferences"], cwd=native.bundle, env=native.env)
    elif args.command == "smoke":
        native.build()
        native.smoke()
    else:
        getattr(native, args.command)()


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        sys.exit("Error: {}".format(error))
