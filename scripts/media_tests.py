"""Build and run the real shared media fixtures on Windows/Linux.

Windows runs against a relocated minimal runtime, never the development SDK's
plugin directory. Linux uses the distribution's development/runtime packages.
All outputs are retained under a new private artifact directory for diagnosis.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

import install_gstreamer as sdk
import gstreamer_runtime as runtime
from native_modules import ROOT, native_sources, object_path


PACKAGES = ("gst-editing-services-1.0", "gstreamer-app-1.0", "gstreamer-pbutils-1.0",
            "gstreamer-video-1.0", "gstreamer-audio-1.0", "gio-2.0",
            "libavformat", "libavcodec", "libavutil")


class MediaTests:
    def __init__(self, directory, environment=None):
        if sys.platform not in ("win32", "linux"):
            raise RuntimeError("Target media fixtures require Windows or Linux")
        self.system = "windows" if sys.platform == "win32" else "linux"
        self.env = dict(os.environ if environment is None else environment)
        Path(directory).mkdir(parents=True, exist_ok=True)
        self.directory = Path(tempfile.mkdtemp(prefix="media-", dir=directory)).resolve()
        self.executables = self.directory / "bin"
        self.executables.mkdir()
        self.runtime_payload = None
        if self.system == "windows":
            home = self.env.get("MOOJICUT_GSTREAMER_SDK")
            if not home:
                raise RuntimeError("Set MOOJICUT_GSTREAMER_SDK to the verified private SDK directory")
            package = sdk.load_lock()
            self.includes, self.libraries = sdk.compiler_arguments(home, package)
            self.runtime_payload = self.directory / "runtime-payload"
            runtime.prepare_runtime(home, self.runtime_payload, package)
            shutil.copytree(self.runtime_payload, self.executables, dirs_exist_ok=True)
            self.runtime_env = runtime.runtime_environment(
                self.executables, self.directory / "registry.bin", self.env)
        else:
            raw = shlex.split(self.run("pkg-config", "--cflags", *PACKAGES))
            # Only third-party includes are system headers. Keep strict warnings
            # on our own code; some GES versions annotate const return values.
            self.includes = []
            for flag in raw:
                if flag.startswith("-I"):
                    self.includes.extend(("-isystem", flag[2:]))
                else:
                    self.includes.append(flag)
            self.libraries = shlex.split(self.run("pkg-config", "--libs", *PACKAGES))
            self.runtime_env = {key: value for key, value in self.env.items()
                                if not key.upper().startswith(("GST_", "GSTREAMER_"))}
            self.runtime_env.update(GST_PLUGIN_PATH_1_0="", GST_REGISTRY_1_0=str(self.directory / "registry.bin"))
        self.runtime_env.update(G_DEBUG="fatal-criticals", GST_DEBUG="0", LC_ALL="C", LANG="C")

    def run(self, *command, runtime=False, log=None):
        print("+", " ".join(map(str, command)), flush=True)
        try:
            result = subprocess.run(list(map(str, command)), cwd=ROOT,
                                    env=self.runtime_env if runtime else self.env,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600)
        except subprocess.TimeoutExpired as error:
            if log:
                def decoded(value):
                    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
                (self.directory / log).write_text(decoded(error.stdout) + decoded(error.stderr) + "\nTIMEOUT\n", encoding="utf-8")
            raise
        output = result.stdout + result.stderr
        if log:
            (self.directory / log).write_text(output, encoding="utf-8")
        if result.stdout:
            print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr, flush=True)
        if result.returncode:
            raise RuntimeError(f"Media command failed ({result.returncode}): {command[0]}")
        return result.stdout

    def compile(self):
        sources = native_sources(self.system, "shared.media_engine")
        objects = []
        for unit in sources:
            obj = object_path(self.directory, unit)
            obj.parent.mkdir(parents=True, exist_ok=True)
            if self.system == "windows":
                self.run("cl", "/nologo", "/utf-8", "/MT", "/O2", "/W4", "/WX", "/std:c11",
                         "/I" + str(ROOT), *self.includes, "/Fo" + str(obj), "/c", unit)
            else:
                self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                         "-I", ROOT, *self.includes, "-c", unit, "-o", obj)
            objects.append(obj)
        self.fixtures = {}
        for name in ("gst-media", "mp4-mux", "media-worker", "media-waveform"):
            fixture = ROOT / "test/native" / (name + ".c")
            executable = self.executables / (name + (".exe" if self.system == "windows" else ""))
            if self.system == "windows":
                obj = object_path(self.directory, fixture)
                obj.parent.mkdir(parents=True, exist_ok=True)
                self.run("cl", "/nologo", "/utf-8", "/MT", "/O2", "/W4", "/WX", "/std:c11",
                         "/I" + str(ROOT), *self.includes, "/Fo" + str(obj), "/c", fixture)
                self.run("cl", "/nologo", obj, *objects, "/Fe" + str(executable),
                         "/link", "/SUBSYSTEM:CONSOLE", *self.libraries)
            else:
                self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                         "-I", ROOT, *self.includes, fixture, *objects, *self.libraries, "-lm", "-o", executable)
            self.fixtures[name] = executable

    def host_test(self, core_archive, moon_home):
        sources = native_sources(self.system, "shared.editor_host")
        source = ROOT / "test/native/video-editor-host.c"
        executable = self.executables / ("video-editor-host.exe" if self.system == "windows" else "video-editor-host")
        if self.system == "windows":
            objects = []
            for unit in [*sources, source]:
                obj = object_path(self.directory / "host", unit)
                obj.parent.mkdir(parents=True, exist_ok=True)
                self.run("cl", "/nologo", "/utf-8", "/MT", "/O2", "/W4", "/WX", "/std:c11",
                         "/I" + str(ROOT), "/I" + str(Path(moon_home) / "include"), *self.includes,
                         "/Fo" + str(obj), "/c", unit)
                objects.append(obj)
            self.run("cl", "/nologo", *objects, core_archive, "/Fe" + str(executable),
                     "/link", "/SUBSYSTEM:CONSOLE", "/IMPLIB:" + str(self.directory / "host.lib"),
                     *self.libraries, "oldnames.lib", "advapi32.lib", "dbghelp.lib")
        else:
            self.run("cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", ROOT,
                     "-I", Path(moon_home) / "include", *self.includes, *sources, source, core_archive,
                     *self.libraries, "-lm", "-o", executable)
        self.run(executable, self.directory / "host-media", runtime=True, log="video-editor-host.log")

    def test(self, core_archive=None, moon_home=None):
        self.compile()
        media = self.directory / "media"
        self.run(self.fixtures["gst-media"], media, runtime=True, log="gst-media.log")
        # The mux test must receive the raw encoder intermediate, not an MP4
        # whose priming has already been compensated.
        self.run(self.fixtures["mp4-mux"], media / "identity-raw.mp4", self.directory / "mux",
                 runtime=True, log="mp4-mux.log")
        self.run(self.fixtures["media-worker"], self.directory / "worker", runtime=True, log="media-worker.log")
        self.run(self.fixtures["media-waveform"], self.directory / "waveform", runtime=True, log="media-waveform.log")
        if core_archive is not None:
            self.host_test(core_archive, moon_home)
        checks = [*self.fixtures, *(["video-editor-host"] if core_archive is not None else [])]
        result = {"platform": self.system, "checks": checks, "result": "passed",
                  "runtime": "relocated private subset" if self.system == "windows" else "distribution packages",
                  "scope": "Actual media and worker behavior; GUI, capture devices and permissions are separate gates."}
        (self.directory / "results.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        return result


if __name__ == "__main__":
    destination = Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT / ".artifacts/media"
    MediaTests(destination).test()
