#!/usr/bin/env python3
"""Build a pinned private Linux media SDK; never install into the OS.

Ubuntu 22's qtdemux 1.20.3 loses AAC tails across edit lists. This SDK builds
GStreamer/GES together against the same system GLib used by GTK. It never
scans system GStreamer plugins. Meson wraps, optional autodetection, FFmpeg
network/protocol/CLI/GPL components and privileged installation are disabled.

Install: --prefix /absolute/private/sdk --cache /absolute/source/cache
Tools must already exist: meson==1.8.3, ninja==1.13.0 (e.g. a caller's venv).
Only a successful ABI/factory check publishes moojicut-linux-sdk.json. Cached
installs require that receipt, identical configuration and a complete hash
inventory, followed by fresh runtime checks. Interrupted installs are refused,
not reused. Source archives are the only downloads performed by this script.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "build/linux-media-sdk.json"
REPORT = "moojicut-linux-sdk.json"
LICENSE_DIR = "share/licenses/moojicut-media"


def load_lock():
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if lock.get("schema_version") != 1 or lock.get("target") != "linux-x86_64":
        raise ValueError("Unsupported Linux media SDK lock")
    return lock


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            checksum.update(chunk)
    return checksum.hexdigest()


def configuration_digest(lock):
    return hashlib.sha256(json.dumps(lock, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def verified_archive(path, package):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size != package["bytes"] or digest(path) != package["sha256"]:
        raise ValueError("Source SHA256/size mismatch: " + str(path))
    return path


def download(package, cache):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / package["archive"]
    if target.exists() or target.is_symlink():
        return verified_archive(target, package)
    with tempfile.NamedTemporaryFile(dir=cache, suffix=".download", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            print("Downloading pinned source", package["url"], flush=True)
            with urlopen(package["url"], timeout=120) as response:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > package["bytes"]:
                        raise ValueError("Source archive exceeds locked size")
                    stream.write(chunk)
            stream.close()
            verified_archive(temporary, package)
            os.replace(temporary, target)
        finally:
            # Windows cannot unlink an open download on the oversize/error
            # path. Close before removing it on every platform.
            stream.close()
            temporary.unlink(missing_ok=True)
    return target


def unpack(archive, destination, package):
    """Validate the entire tar before writing, including internal symlinks.

    The official Gst monorepo contains a documentation symlink. We permit
    relative links inside its root, create them last, and forbid archive writes
    through a link. Devices, hardlinks, duplicates and traversal are rejected.
    """
    verified_archive(archive, package)
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Refusing to extract over an existing source directory")
    with tarfile.open(archive, "r:*") as tar:
        members = tar.getmembers()
        if len(members) > 50000:
            raise ValueError("Too many source archive entries")
        names, links, total = set(), set(), 0
        for entry in members:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.name or not path.parts or path.parts[0] != package["root"]:
                raise ValueError("Unsafe source archive path: " + entry.name)
            if path in names or not (entry.isfile() or entry.isdir() or entry.issym()):
                raise ValueError("Duplicate or unsupported archive entry: " + entry.name)
            names.add(path)
            total += entry.size
            if total > package["max_unpacked_bytes"] or entry.size < 0:
                raise ValueError("Source archive exceeds unpacked size limit")
            if entry.issym():
                target = PurePosixPath(entry.linkname)
                resolved = Path(os.path.normpath(str(path.parent / target)))
                if target.is_absolute() or "\\" in entry.linkname or not resolved.parts or resolved.parts[0] != package["root"] or ".." in resolved.parts:
                    raise ValueError("Source symlink escapes archive root")
                links.add(path)
        for path in names:
            if any(parent in links for parent in path.parents):
                raise ValueError("Source archive writes through symlink")
        destination.mkdir(parents=True)
        try:
            for entry in members:
                path = destination / entry.name
                if entry.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                elif entry.isfile():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(entry) as source, path.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    path.chmod(0o755 if entry.mode & 0o111 else 0o644)
            for entry in members:
                if entry.issym():
                    path = destination / entry.name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.symlink_to(entry.linkname)
        except BaseException:
            shutil.rmtree(destination)
            raise
    return destination / package["root"]


def sdk_environment(home, inherited=None):
    """Explicit SDK discovery; preserve display/DBus context, no global mutation."""
    home = Path(home).resolve()
    original = dict(os.environ if inherited is None else inherited)
    blocked = ("GST_", "GSTREAMER_", "PKG_CONFIG_")
    environment = {key: value for key, value in original.items()
                   if not key.upper().startswith(blocked) and key not in ("LD_PRELOAD", "LD_LIBRARY_PATH")}
    environment.update({
        "PATH": str(home / "bin") + os.pathsep + original.get("PATH", "/usr/bin:/bin"),
        "LD_LIBRARY_PATH": str(home / "lib"),
        "PKG_CONFIG_PATH": os.pathsep.join(str(home / part) for part in ("lib/pkgconfig", "share/pkgconfig")),
        "GST_PLUGIN_PATH_1_0": "",
        "GST_PLUGIN_SYSTEM_PATH_1_0": str(home / "lib/gstreamer-1.0"),
        "GST_PLUGIN_SCANNER_1_0": str(home / "libexec/gstreamer-1.0/gst-plugin-scanner"),
        "GST_REGISTRY_1_0": str(home / ".moojicut/registry.bin"),
        "LC_ALL": "C", "LANG": "C", "GST_DEBUG": "0",
    })
    return environment


def run(command, *, env=None, cwd=None):
    print("+", shlex.join(list(map(str, command))), flush=True)
    result = subprocess.run(list(map(str, command)), env=env, cwd=cwd, text=True,
                            encoding="utf-8", errors="replace", stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=3600)
    if result.returncode:
        raise RuntimeError("Command failed: " + str(command[0]) + "\n" + result.stdout)
    return result.stdout


def compiler_arguments(home, packages=None, execute=run):
    packages = packages or load_lock()["packages"]
    environment = sdk_environment(home)
    flags = shlex.split(execute(["pkg-config", "--cflags", *packages], env=environment))
    libraries = shlex.split(execute(["pkg-config", "--libs", *packages], env=environment))
    return flags, libraries


def private_file(home, relative):
    home = Path(home).resolve()
    path = home / relative
    if not path.resolve().is_relative_to(home) or not path.is_file():
        raise ValueError("Missing or non-private SDK file: " + str(path))
    return path


def inventory(home):
    """Stable payload only; registry and ABI scratch are intentionally mutable."""
    home = Path(home).resolve()
    result = []
    for path in sorted(home.rglob("*")):
        relative = path.relative_to(home).as_posix()
        if relative == REPORT or relative.startswith(".moojicut/") or relative == ".moojicut":
            continue
        component = "gstreamer"
        if (relative.startswith(LICENSE_DIR + "/orc/") or relative.startswith("include/orc-0.4/") or
                relative.startswith(("lib/liborc-", "lib/pkgconfig/orc-")) or relative == "bin/orcc"):
            component = "orc"
        elif relative == "lib/gstreamer-1.0/libgstpipewire.so" or relative.startswith(LICENSE_DIR + "/pipewire/"):
            component = "pipewire"
        elif (relative.startswith(LICENSE_DIR + "/ffmpeg/") or
              re.match(r"(?:include/lib|lib/(?:lib|pkgconfig/lib))(?:avcodec|avformat|avutil|avfilter|swscale|swresample)(?:/|[.])", relative)):
            component = "ffmpeg"
        entry = {"path": relative, "component": component}
        if path.is_symlink():
            if not path.resolve().is_relative_to(home) or not path.resolve().is_file():
                raise ValueError("SDK contains external or dangling symlink: " + relative)
            result.append({**entry, "symlink": os.readlink(path)})
        elif path.is_file():
            result.append({**entry, "sha256": digest(path), "bytes": path.stat().st_size,
                           "mode": stat.S_IMODE(path.stat().st_mode)})
        elif not path.is_dir():
            raise ValueError("SDK contains special file: " + relative)
    return result


PROBE = r'''#include <ges/ges.h>
#include <gst/app/gstappsink.h>
#include <gst/pbutils/pbutils.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavutil/avutil.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    gst_init(NULL, NULL);
    if (!ges_init()) return 1;
    guint a,b,c,d;
    gst_version(&a,&b,&c,&d);
    if (a != GST_VERSION_MAJOR || b != GST_VERSION_MINOR ||
        c != GST_VERSION_MICRO || d != 0 || a != 1 || b != 28 || c != 9) return 2;
    ges_version(&a,&b,&c,&d);
    if (a != GES_VERSION_MAJOR || b != GES_VERSION_MINOR ||
        c != GES_VERSION_MICRO || d != 0 || a != 1 || b != 28 || c != 9) return 3;
    if ((avformat_version() >> 16) != 61 || LIBAVFORMAT_VERSION_MAJOR != 61 ||
        (avcodec_version() >> 16) != 61 || LIBAVCODEC_VERSION_MAJOR != 61 ||
        (avutil_version() >> 16) != 59 || LIBAVUTIL_VERSION_MAJOR != 59 ||
        (avfilter_version() >> 16) != 10 || LIBAVFILTER_VERSION_MAJOR != 10) return 4;
    if (!av_find_input_format("mov") || !av_guess_format("mp4", NULL, NULL) ||
        !avcodec_find_encoder(AV_CODEC_ID_AAC) ||
        !avcodec_find_decoder(AV_CODEC_ID_AAC) || !avcodec_find_decoder(AV_CODEC_ID_H264)) return 5;
    if (strcmp(avformat_license(), "LGPL version 2.1 or later") ||
        strcmp(avcodec_license(), "LGPL version 2.1 or later")) return 6;
    void *state = NULL;
    if (avio_enum_protocols(&state, 0)) return 7;
    state = NULL;
    if (avio_enum_protocols(&state, 1)) return 8;
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!sink || !GST_IS_APP_SINK(sink)) return 9;
    gst_object_unref(sink);
    GError *error = NULL;
    GstDiscoverer *discoverer = gst_discoverer_new(GST_SECOND, &error);
    if (!discoverer) { g_clear_error(&error); return 10; }
    g_object_unref(discoverer);
    printf("GStreamer/GES 1.28.9; FFmpeg ABI 61/61/59/10; LGPL2.1; no protocols\n");
    printf("FFmpeg configuration: %s\n", avformat_configuration());
    printf("GLib runtime %u.%u.%u; headers %u.%u.%u\n", glib_major_version,
        glib_minor_version, glib_micro_version, GLIB_MAJOR_VERSION, GLIB_MINOR_VERSION, GLIB_MICRO_VERSION);
    return 0;
}
'''


def plugin_metadata(output, home, lock):
    fields = {}
    # Match only Plugin Details, not Factory Details' versionless name.
    if "Plugin Details:" not in output:
        raise ValueError("Factory lacks Plugin Details")
    section = output.split("Plugin Details:", 1)[1]
    for name in ("Name", "Filename", "Version", "License", "Source module", "Origin URL"):
        match = re.search(r"^[ \t]+" + re.escape(name) + r"[ \t]+([^\r\n]*)", section, re.M)
        if match:
            fields[name] = match[1].strip()
    version = lock["plugin_versions"].get(fields.get("Name"), lock["version"])
    if fields.get("Version") != version or fields.get("License") not in ("LGPL", "MIT/X11", "LGPLv2+", "BSD"):
        raise ValueError("Unexpected plugin version/license: " + repr(fields))
    path = Path(fields.get("Filename", "")).resolve()
    home = Path(home).resolve()
    if not path.is_relative_to(home):
        raise ValueError("Plugin resolved outside private SDK: " + str(path))
    fields["Filename"] = path.relative_to(home).as_posix()
    private_file(home, fields["Filename"])
    return fields


def verify_sdk(home, lock=None, *, execute=run, require_receipt=True):
    home = Path(home).resolve()
    lock = lock or load_lock()
    receipt = None
    if require_receipt:
        path = home / REPORT
        if path.is_symlink() or not path.is_file():
            raise ValueError("SDK has no successful build receipt; incomplete installs are never reused")
        receipt = json.loads(path.read_text(encoding="utf-8"))
        if (receipt.get("lock_sha256") != digest(LOCK) or receipt.get("configuration_sha256") != configuration_digest(lock)
                or receipt.get("prefix") != str(home)):
            raise ValueError("SDK receipt configuration/prefix mismatch")
        if receipt.get("files") != inventory(home):
            raise ValueError("SDK payload hash inventory mismatch")
    for relative in lock["required_files"]:
        private_file(home, relative)
    for library, major in lock["abi_majors"].items():
        private_file(home, f"lib/lib{library}.so.{major}")
    for source, paths in lock["licenses"].items():
        for relative in paths:
            private_file(home, LICENSE_DIR + "/" + source + "/" + relative)
    # Never let private GLib diverge from the GTK process's system GLib.
    if any(home.glob("lib/libglib*")) or any(home.glob("lib/libgobject*")) or any(home.glob("lib/libgio*")):
        raise ValueError("Private GLib is forbidden; use GTK's system GLib")
    environment = sdk_environment(home)
    scratch = home / ".moojicut"
    if scratch.is_symlink() or (scratch.exists() and not scratch.is_dir()):
        raise ValueError("SDK scratch must be a private directory")
    scratch.mkdir(exist_ok=True)
    environment["G_DEBUG"] = "fatal-criticals"
    packages = lock["packages"] + ["libavfilter", "gstreamer-1.0"]
    versions = {}
    for name in packages:
        prefix = execute(["pkg-config", "--variable=prefix", name], env=environment).strip()
        if name != "gio-2.0" and Path(prefix).resolve() != home:
            raise ValueError("Media pkg-config escaped private prefix: " + name)
        versions[name] = execute(["pkg-config", "--modversion", name], env=environment).strip()
        if (name.startswith("gstreamer-") or name.startswith("gst-editing-")) and versions[name] != lock["version"]:
            raise ValueError("GStreamer pkg-config version mismatch: " + name)
    factories = {}
    for factory in lock["required_factories"]:
        output = execute([home / "bin/gst-inspect-1.0", factory], env=environment)
        factories[factory] = plugin_metadata(output, home, lock)
    source = scratch / "sdk-probe.c"
    binary = scratch / "sdk-probe"
    source.write_text(PROBE, encoding="utf-8")
    cflags, libraries = compiler_arguments(home, packages, execute)
    execute(["cc", "-std=c11", *cflags, source, "-o", binary, *libraries], env=environment)
    probe = execute([binary], env=environment)
    sources = [{"id": name, **package,
                "license_files": [LICENSE_DIR + "/" + name + "/" + path for path in lock["licenses"][name]]}
               for name, package in lock["sources"].items()]
    return {"schema_version": 1, "version": lock["version"], "target": lock["target"], "prefix": str(home),
            "lock_sha256": digest(LOCK), "configuration_sha256": configuration_digest(lock), "sources": sources,
            "configuration": {"tools": lock["tools"], "tool_versions": lock["tool_versions"],
                              "tool_artifacts": lock["tool_artifacts"],
                              "orc_options": lock["orc_options"], "meson_options": lock["meson_options"],
                              "ffmpeg_options": lock["ffmpeg_options"], "pipewire_sources": lock["pipewire_sources"]},
            "licenses": lock["licenses"], "license_root": LICENSE_DIR,
            "pkgconfig_versions": versions, "factories": factories, "abi_probe": probe,
            "files": inventory(home)}


def tool_environment(home, lock, execute=run):
    tools = {}
    for name, version in lock["tools"].items():
        path = shutil.which(name)
        if not path or execute([path, "--version"]).strip() != lock["tool_versions"][name]:
            raise ValueError(f"Install pinned build tool {name}=={version} in an explicit venv")
        expected_hash = lock["tool_artifacts"][name].get("executable_sha256")
        if expected_hash and digest(path) != expected_hash:
            raise ValueError("Build tool differs from the pinned Linux x86_64 wheel: " + name)
        tools[name] = str(Path(path).absolute())
    environment = sdk_environment(home)
    # Drop injection into configure/compiler invocations. Use system GCC/GLib,
    # while retaining the caller's exact pinned Meson/Ninja executables.
    for name in ("CC", "CXX", "CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "DESTDIR"):
        environment.pop(name, None)
    paths = list(dict.fromkeys(str(Path(path).parent) for path in tools.values()))
    environment["PATH"] = os.pathsep.join(paths + [str(Path(home) / "bin"), "/usr/bin", "/bin"])
    return tools, environment


def build_sdk(home, sources, work, lock, jobs, execute=run):
    tools, environment = tool_environment(home, lock, execute)
    # Enforce the GLib boundary before any compilation. Meson repeats the real
    # >=2.64 checks; --wrap-mode=nofallback prevents silently building a new one.
    execute(["pkg-config", "--atleast-version=2.64", "glib-2.0", "gio-2.0"], env=environment)
    orc_build = work / "orc-build"
    execute([tools["meson"], "setup", orc_build, sources["orc"], "--prefix=" + str(home),
             "--libdir=lib", "--wrap-mode=nofallback", *["-D" + option for option in lock["orc_options"]]], env=environment)
    execute([tools["ninja"], "-C", orc_build, "-j", str(jobs)], env=environment)
    execute([tools["meson"], "install", "-C", orc_build, "--no-rebuild"], env=environment)
    ffmpeg_build = work / "ffmpeg-build"
    ffmpeg_build.mkdir()
    execute([sources["ffmpeg"] / "configure", "--prefix=" + str(home), "--libdir=" + str(home / "lib"),
             *lock["ffmpeg_options"]], env=environment, cwd=ffmpeg_build)
    execute(["make", "-j", str(jobs)], env=environment, cwd=ffmpeg_build)
    execute(["make", "install"], env=environment, cwd=ffmpeg_build)
    gst_build = work / "gst-build"
    execute([tools["meson"], "setup", gst_build, sources["gstreamer"], "--prefix=" + str(home),
             "--libdir=lib", "--libexecdir=libexec", "--wrap-mode=nofallback",
             *["-D" + option for option in lock["meson_options"]]], env=environment)
    execute([tools["ninja"], "-C", gst_build, "-j", str(jobs)], env=environment)
    execute([tools["meson"], "install", "-C", gst_build, "--no-rebuild"], env=environment)
    # PipeWire's plugin is a separate upstream project. Compile its unmodified
    # source list against OS client/SPA headers and our private Gst. Building a
    # second daemon/client/SPA stack would conflict with portal integration.
    pw = sources["pipewire"]
    config = work / "pipewire-config"
    config.mkdir()
    version = lock["sources"]["pipewire"]["version"]
    (config / "config.h").write_text('#define PACKAGE "pipewire"\n#define PACKAGE_VERSION "' + version +
                                    '"\n#define HAVE_GSTREAMER_DEVICE_PROVIDER 1\n', encoding="utf-8")
    packages = ["libpipewire-0.3", "libspa-0.2", "gstreamer-video-1.0", "gstreamer-audio-1.0",
                "gstreamer-allocators-1.0", "gstreamer-net-1.0"]
    execute(["pkg-config", "--atleast-version=0.3.48", "libpipewire-0.3"], env=environment)
    flags, libraries = compiler_arguments(home, packages, execute)
    execute(["cc", "-shared", "-fPIC", "-O2", "-std=gnu11", "-D_GNU_SOURCE",
             "-I" + str(config), "-I" + str(pw / "src"), *flags,
             *[pw / "src/gst" / name for name in lock["pipewire_sources"]],
             "-o", home / "lib/gstreamer-1.0/libgstpipewire.so", *libraries], env=environment)
    for project, paths in lock["licenses"].items():
        for relative in paths:
            target = home / LICENSE_DIR / project / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(sources[project] / relative, target)
    # The receipt links every distributed component to these exact source
    # archives and options. Packagers retain it with their ELF closure report.
    (home / LICENSE_DIR / "sources.json").write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")


@contextmanager
def install_lock(home):
    # Keep the lock inode in place so waiters cannot lock a replacement inode.
    import fcntl
    path = home.parent / ("." + home.name + ".install.lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def install(home, cache, lock=None, *, jobs=None, execute=run, verify=verify_sdk, build=build_sdk):
    home = Path(home)
    if not home.is_absolute() or home.is_symlink():
        raise ValueError("Pass an absolute, non-symlink private SDK prefix")
    home = home.resolve()
    if home == Path("/") or any(home.is_relative_to(Path(path)) for path in ("/usr", "/bin", "/sbin", "/lib", "/etc")):
        raise ValueError("Refusing a system installation prefix")
    lock = lock or load_lock()
    jobs = jobs or max(1, min(8, os.cpu_count() or 1))
    if not 1 <= jobs <= 128:
        raise ValueError("jobs must be between 1 and 128")
    home.parent.mkdir(parents=True, exist_ok=True)
    with install_lock(home):
        if home.exists():
            # Preserve an invalid/partial existing prefix for inspection. Only
            # the caller may explicitly remove it; never delete user content.
            return verify(home, lock, execute=execute)
        archives = {name: download(package, cache) for name, package in lock["sources"].items()}
        with tempfile.TemporaryDirectory(prefix=".linux-media-build-", dir=home.parent) as temporary:
            work = Path(temporary)
            sources = {name: unpack(archives[name], work / name, package)
                       for name, package in lock["sources"].items()}
            home.mkdir()
            try:
                build(home, sources, work, lock, jobs, execute)
                result = verify(home, lock, execute=execute, require_receipt=False)
                temporary_receipt = home / ".moojicut" / "receipt.tmp"
                temporary_receipt.parent.mkdir(exist_ok=True)
                with temporary_receipt.open("w", encoding="utf-8") as stream:
                    json.dump(result, stream, indent=2)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary_receipt, home / REPORT)
                return result
            except BaseException:
                shutil.rmtree(home)
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--jobs", type=int)
    parser.add_argument("--verify-only", action="store_true")
    arguments = parser.parse_args()
    if sys.platform != "linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        parser.error("Build and ABI verification require Linux x86_64")
    if arguments.verify_only:
        report = verify_sdk(arguments.prefix)
    else:
        if arguments.cache is None or not arguments.cache.is_absolute():
            parser.error("--cache must be an explicit absolute directory")
        report = install(arguments.prefix, arguments.cache, jobs=arguments.jobs)
    print("Verified private Linux media SDK:", report["prefix"], report["lock_sha256"], flush=True)


if __name__ == "__main__":
    main()
