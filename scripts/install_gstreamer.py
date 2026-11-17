#!/usr/bin/env python3
"""Acquire and verify the pinned private Windows GStreamer/GES development SDK.

Run from an x64 MSVC developer shell. The verified official installer supports
PORTABLE=1: no uninstaller, environment/registry changes, Visual Studio template
registration, or VC redistributable installation. Nothing is appended to PATH or
GITHUB_ENV. Build callers explicitly use sdk_environment()/compiler_arguments().
The full development SDK is never copied into an application release here.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "build/gstreamer-sdk.json"
REPORT = "moojicut-sdk.json"


def load_lock():
    data = json.loads(LOCK.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("Unsupported GStreamer SDK lock schema")
    return data["windows-x86_64"]


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(package, cache):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / Path(urlparse(package["url"]).path).name
    if target.exists():
        if target.is_symlink() or target.stat().st_size != package["bytes"] or digest(target) != package["sha256"]:
            raise ValueError("Cached SDK checksum mismatch; remove the invalid cached file explicitly: " + str(target))
        return target
    print("Downloading pinned GStreamer SDK", package["url"], flush=True)
    with tempfile.NamedTemporaryFile(dir=cache, suffix=".download", delete=False) as stream:
        temporary = Path(stream.name)
        total, checksum = 0, hashlib.sha256()
        try:
            with urlopen(package["url"], timeout=120) as response:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > package["bytes"]:
                        raise ValueError("GStreamer SDK exceeds the locked archive size")
                    checksum.update(chunk)
                    stream.write(chunk)
            if total != package["bytes"] or checksum.hexdigest() != package["sha256"]:
                raise ValueError("GStreamer SDK SHA256/size mismatch")
        except BaseException:
            stream.close()
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.rename(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def installer_command(archive, destination, log):
    return [str(archive), "/PORTABLE=1", "/CURRENTUSER", "/TYPE=devel", "/TASKS=",
            "/NOICONS", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-",
            "/DIR=" + str(destination), "/LOG=" + str(log)]


def sdk_environment(home, inherited=None):
    """Private runtime discovery; never discover plugins from another install."""
    home = Path(home).resolve()
    original = dict(os.environ if inherited is None else inherited)
    environment = {key: value for key, value in original.items()
                   if not key.upper().startswith(("GST_", "GSTREAMER_"))}
    windows = Path(original.get("SystemRoot", r"C:\Windows"))
    environment.update({
        "PATH": os.pathsep.join(map(str, (home / "bin", windows / "System32", windows))),
        "GST_PLUGIN_PATH_1_0": "",
        "GST_PLUGIN_SYSTEM_PATH_1_0": str(home / "lib/gstreamer-1.0"),
        "GST_PLUGIN_SCANNER_1_0": str(home / "libexec/gstreamer-1.0/gst-plugin-scanner.exe"),
        "GST_REGISTRY_1_0": str(home / ".moojicut/registry-x86_64.bin"),
        "GST_DEBUG": "0", "LC_ALL": "C", "LANG": "C",
    })
    return environment


def compiler_arguments(home, package):
    home = Path(home).resolve()
    return (["/external:W0", *["/external:I" + str(home / item) for item in package["include_dirs"]]],
            ["/LIBPATH:" + str(home / "lib"), *package["link_libraries"]])


def require_private_file(home, relative):
    home = Path(home).resolve()
    path = home / relative
    if not path.resolve().is_relative_to(home) or not path.is_file() or path.is_symlink():
        raise ValueError("Missing or non-private SDK file: " + str(path))
    return path


def plugin_metadata(output, home, package):
    fields = {}
    # Factory output starts with Factory Details, then Plugin Details. These
    # unlocalized field names are forced by the subprocess C locale.
    for key in ("Name", "Filename", "Version", "License", "Source module", "Binary package", "Origin URL"):
        match = re.search(r"^[ \t]+" + re.escape(key) + r"[ \t]+([^\r\n]+)\r?$", output, re.M)
        if match:
            fields[key] = match[1].strip()
    # Component versions in the SHA-locked SDK can differ from GStreamer.
    # Keep exact versions; a shared prefix is not sufficient.
    version = package.get("component_versions", {}).get(fields.get("Source module"), package["version"])
    if fields.get("Version") != version or not fields.get("License") or not fields.get("Filename"):
        raise ValueError("SDK factory lacks the expected version/license/path: " + repr(fields))
    path = Path(fields["Filename"]).resolve()
    home = Path(home).resolve()
    if not path.is_relative_to(home):
        raise ValueError("Factory resolved outside the private SDK: " + str(path))
    fields["Filename"] = path.relative_to(home).as_posix()
    require_private_file(home, fields["Filename"])
    return fields


def run(command, *, env=None, cwd=None):
    result = subprocess.run(list(map(str, command)), env=env, cwd=cwd, text=True,
                            encoding="utf-8", errors="replace", stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=300)
    if result.returncode:
        raise RuntimeError("Command failed: " + str(command[0]) + "\n" + result.stdout)
    return result.stdout


PROBE = r'''#include <ges/ges.h>
#include <gst/app/gstappsink.h>
#include <gst/pbutils/pbutils.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <stdio.h>
#if !defined(_M_X64) || defined(_M_ARM64EC)
#error The pinned GStreamer SDK requires the MSVC x64 target
#endif
int main(void) {
    gst_init(NULL, NULL);
    if (!ges_init()) return 1;
    guint major, minor, micro, nano;
    gst_version(&major, &minor, &micro, &nano);
    printf("GStreamer ABI %u.%u.%u.%u\n", major, minor, micro, nano);
    printf("GStreamer headers %u.%u.%u.%u\n", (guint)GST_VERSION_MAJOR,
        (guint)GST_VERSION_MINOR, (guint)GST_VERSION_MICRO, (guint)GST_VERSION_NANO);
    if (major != GST_VERSION_MAJOR || minor != GST_VERSION_MINOR ||
        micro != GST_VERSION_MICRO || nano != GST_VERSION_NANO) return 7;
    ges_version(&major, &minor, &micro, &nano);
    printf("GES %u.%u.%u.%u\n", major, minor, micro, nano);
    printf("GES headers %u.%u.%u.%u\n", (guint)GES_VERSION_MAJOR,
        (guint)GES_VERSION_MINOR, (guint)GES_VERSION_MICRO, (guint)GES_VERSION_NANO);
    if (major != GES_VERSION_MAJOR || minor != GES_VERSION_MINOR ||
        micro != GES_VERSION_MICRO || nano != GES_VERSION_NANO) return 6;
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!sink || !GST_IS_APP_SINK(sink)) return 2;
    gst_object_unref(sink);
    GError *error = NULL;
    GstDiscoverer *probe = gst_discoverer_new(5 * GST_SECOND, &error);
    if (!probe) { if (error) g_error_free(error); return 3; }
    g_object_unref(probe);
    if ((avformat_version() >> 16) != LIBAVFORMAT_VERSION_MAJOR ||
        (avcodec_version() >> 16) != LIBAVCODEC_VERSION_MAJOR ||
        (avutil_version() >> 16) != LIBAVUTIL_VERSION_MAJOR) return 4;
    if (!av_find_input_format("mov") || !av_guess_format("mp4", NULL, NULL)) return 5;
    printf("libav ABI %u %u %u; mov demux/mp4 mux available\n",
        avformat_version() >> 16, avcodec_version() >> 16, avutil_version() >> 16);
    printf("libavformat license: %s\nlibavcodec license: %s\nlibavutil license: %s\n",
        avformat_license(), avcodec_license(), avutil_license());
    printf("libavformat configuration: %s\n", avformat_configuration());
    void *protocol_state = NULL; const char *protocol;
    printf("libav input protocols:");
    while ((protocol = avio_enum_protocols(&protocol_state, 0)) != NULL) printf(" %s", protocol);
    printf("\n");
    return 0;
}
'''


def verify_sdk(home, package, execute=run):
    home = Path(home).resolve()
    if list(home.glob("unins*.exe")):
        raise ValueError("Unexpected uninstaller: the SDK must be installed in portable mode")
    errors, missing = [], set()
    required = package["required_files"] + ["lib/" + name for name in package["link_libraries"]]
    for relative in required:
        try:
            require_private_file(home, relative)
        except ValueError as error:
            errors.append(str(error))
            missing.add(relative)
    print("SDK required files:", len(required) - len(missing), "present; missing/unusable:",
          ", ".join(sorted(missing)) or "none", flush=True)
    license_root = home / "share/licenses"
    actual_license_dirs = sorted(path.name for path in license_root.iterdir() if path.is_dir()) if license_root.is_dir() else []
    print("SDK license directories:", ", ".join(actual_license_dirs) or "none", flush=True)
    for relative in package["required_license_dirs"]:
        directory = license_root / relative
        if not directory.is_dir() or not any(path.is_file() for path in directory.rglob("*")):
            errors.append("Missing SDK license inventory: " + str(directory))
    scratch = home / ".moojicut"
    scratch.mkdir(exist_ok=True)
    environment = sdk_environment(home)
    inspector = home / "bin/gst-inspect-1.0.exe"
    can_inspect = "bin/gst-inspect-1.0.exe" not in missing
    if can_inspect:
        try:
            version_output = execute([inspector, "--version"], env=environment)
            print("SDK inspector:\n" + version_output.rstrip(), flush=True)
            if not re.search(r"\bGStreamer\s+" + re.escape(package["version"]) + r"(?:\s|$)", version_output):
                errors.append("Unexpected private GStreamer version: " + version_output)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            errors.append("SDK inspector cannot run: " + str(error))
            can_inspect = False
    factories = {}

    def inspect_factory(factory, optional=False):
        if not can_inspect:
            return False
        try:
            text = execute([inspector, factory], env=environment)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            message = "SDK factory " + factory + " unavailable: " + str(error)
            print(message, flush=True)
            if not optional:
                errors.append(message)
            return False
        try:
            metadata = plugin_metadata(text, home, package)
        except ValueError as error:
            message = "SDK factory " + factory + ": " + str(error)
            print(message, flush=True)
            errors.append(message)
            return False
        print("SDK factory " + factory + ": " + json.dumps(metadata, sort_keys=True), flush=True)
        factories[factory] = metadata
        return True

    for factory in package["required_factories"]:
        inspect_factory(factory)
    codecs = {}
    for codec, candidates in package["encoder_alternatives"].items():
        codecs[codec] = []
        for candidate in candidates:
            if inspect_factory(candidate, optional=True):
                codecs[codec].append(candidate)
        if not codecs[codec]:
            errors.append("No private SDK encoder available for " + codec)
    source = scratch / "sdk-probe.c"
    source.write_text(PROBE, encoding="utf-8")
    executable = scratch / "sdk-probe.exe"
    includes, libraries = compiler_arguments(home, package)
    # Use the developer shell only for compilation. Running the resulting EXE
    # uses the isolated runtime environment, so installed plugins cannot hide
    # missing files. Allocations are freed by the matching GLib/GStreamer APIs.
    probe_output = ""
    if not any(path.startswith("include/") or path.endswith(".lib") for path in missing):
        try:
            execute(["cl", "/nologo", "/std:c11", "/MD", "/W4", "/WX", *includes, source,
                     "/Fo" + str(scratch / "sdk-probe.obj"), "/Fe" + str(executable),
                     "/link", *libraries], cwd=scratch)
            probe_output = execute([executable], env=environment)
            print("SDK ABI probe:\n" + probe_output.rstrip(), flush=True)
            gst_version = package["component_versions"]["gstreamer"]
            if not re.search(r"^GStreamer ABI " + re.escape(gst_version) + r"\s*$", probe_output, re.M):
                errors.append("Wrong GStreamer ABI/runtime version: " + probe_output)
            ges_version = package["component_versions"]["gst-editing-services"]
            if not re.search(r"^GES " + re.escape(ges_version) + r"\s*$", probe_output, re.M):
                errors.append("Wrong GES ABI/runtime version: " + probe_output)
            majors = package["libav"]["abi_majors"]
            expected = "libav ABI " + " ".join(str(majors[name]) for name in ("avformat", "avcodec", "avutil"))
            if expected + "; mov demux/mp4 mux available" not in probe_output:
                errors.append("Expected private libav headers/import libraries/MP4 support unavailable: " + probe_output)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            errors.append("SDK ABI probe failed: " + str(error))
    else:
        print("SDK ABI probe unavailable: required headers/import libraries are missing", flush=True)
    if errors:
        raise ValueError("SDK verification failed:\n" + "\n".join(errors))
    licenses = []
    for path in sorted((home / "share/licenses").rglob("*")):
        if path.is_file():
            relative = path.relative_to(home).as_posix()
            require_private_file(home, relative)
            licenses.append({"path": relative, "sha256": digest(path)})
    return {"schema_version": 1, "version": package["version"], "archive_sha256": package["sha256"],
            "compiler": "MSVC x64", "probe": probe_output.strip(), "factories": factories,
            "encoder_candidates": codecs, "licenses": licenses,
            "redistribution_approved": False,
            "scope": "Header/link/ABI and local factory availability only; no media correctness or hardware claim."}


def install(home, archive, package, execute=run, verify=verify_sdk):
    home = Path(home).absolute()
    if home.exists():
        raise ValueError("Refusing to overwrite an existing SDK directory: " + str(home))
    if Path(archive).stat().st_size != package["bytes"] or digest(archive) != package["sha256"]:
        raise ValueError("Refusing to execute an unverified GStreamer installer")
    home.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".gstreamer-sdk-", dir=home.parent) as temporary:
        stage = Path(temporary) / "sdk"
        execute(installer_command(archive, stage, Path(temporary) / "install.log"))
        verify(stage, package)
        # No overwrite/fallback to an unverified SDK after a failed install.
        if home.exists():
            raise ValueError("SDK destination appeared while preparing it: " + str(home))
        stage.rename(home)
        try:
            # The official SDK is relocatable. Prove this at the destination:
            # stale registry cache paths from staging must not satisfy probes.
            report = verify(home, package)
            (home / REPORT).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        except BaseException:
            home.rename(stage)
            raise
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--cache", type=Path, help="Verified installer cache (default: DESTINATION.parent/downloads)")
    parser.add_argument("--download-only", action="store_true", help="Verify official archive on any host; do not execute it")
    parser.add_argument("--verify-only", action="store_true", help="Recheck an existing SDK with MSVC and isolated runtime discovery")
    args = parser.parse_args()
    package = load_lock()
    if args.download_only and args.verify_only:
        parser.error("Choose either --download-only or --verify-only")
    # Some CI shells export PATH/INCLUDE/LIB but not VSCMD_ARG_TGT_ARCH. The
    # actual compile probe, rather than that optional variable, enforces x64.
    if not args.download_only and sys.platform != "win32":
        parser.error("Installation/verification requires an x64 MSVC developer shell on Windows")
    if args.verify_only:
        report = verify_sdk(args.destination, package)
        (args.destination / REPORT).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    else:
        archive = download(package, args.cache or args.destination.absolute().parent / "downloads")
        if args.download_only:
            print("Verified", archive, package["sha256"], flush=True)
            return
        report = install(args.destination, archive, package)
    print("Verified private GStreamer/GES", report["version"], "at", args.destination.resolve(), flush=True)
    print("SDK report:", (args.destination / REPORT).resolve(), flush=True)


if __name__ == "__main__":
    main()
