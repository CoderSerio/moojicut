#!/usr/bin/env python3
"""Close and relocate the private Linux media runtime, keeping desktop GLib shared.

Only the verified source-built SDK and explicitly owned Ubuntu codec packages
can provide bundled ELF files. System GStreamer/FFmpeg are never fallback inputs.
readelf/patchelf are build tools; neither is shipped or needed at application start.
"""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


LIB = Path("runtime/lib")
PLUGINS = Path("runtime/plugins")
SCANNER = Path("runtime/bin/gst-plugin-scanner")
INSPECTOR = Path("runtime/bin/gst-inspect-1.0")
PLUGIN_FACTORIES = {
    "coreelements": ("queue", "filesrc", "filesink", "fakesink", "capsfilter", "typefind"),
    "typefindfunctions": (), "app": ("appsink", "appsrc"),
    "playback": ("decodebin", "decodebin3", "uridecodebin", "uridecodebin3", "playsink"),
    "encoding": ("encodebin", "encodebin2"), "ges": ("gesdemux",),
    "nle": ("nlecomposition", "nlesource", "nleoperation"),
    "compositor": ("compositor",), "videoconvertscale": ("videoconvert", "videoscale"),
    "videorate": ("videorate",), "videocrop": ("videocrop",),
    "videotestsrc": ("videotestsrc",), "videobox": ("videobox",),
    "videofilter": ("videoflip",), "imagefreeze": ("imagefreeze",), "audioconvert": ("audioconvert",),
    "audioresample": ("audioresample",), "audiorate": ("audiorate",),
    "audiotestsrc": ("audiotestsrc",), "audiomixer": ("audiomixer",),
    "audiofx": ("scaletempo",), "volume": ("volume",), "soundtouch": ("pitch",),
    "isomp4": ("qtdemux", "mp4mux"), "videoparsersbad": ("h264parse",),
    "audioparsers": ("aacparse",), "libav": ("avdec_h264", "avdec_aac", "avenc_aac"),
    "openh264": ("openh264enc",), "matroska": ("matroskademux", "matroskamux"),
    "vpx": ("vp8dec", "vp8enc"), "flac": ("flacdec", "flacenc"),
    "autodetect": ("autoaudiosink",), "pulseaudio": ("pulsesink", "pulsesrc"),
    "ximagesrc": ("ximagesrc",), "pipewire": ("pipewiresrc", "pipewiresink"),
}
ROOT_LIBRARIES = (
    "libges-1.0.so.0", "libgstreamer-1.0.so.0", "libgstapp-1.0.so.0",
    "libgstpbutils-1.0.so.0", "libgstvideo-1.0.so.0", "libgstaudio-1.0.so.0",
    "libavformat.so.61", "libavcodec.so.61", "libavutil.so.59",
)
# These remain distribution-owned so GTK, portals, GLib and desktop services
# stay in one ABI universe. Exact SONAMEs, not directory or lib*.so wildcards.
SYSTEM_LIBRARIES = frozenset("""
ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1
libresolv.so.2 libutil.so.1 libgcc_s.so.1 libstdc++.so.6
libglib-2.0.so.0 libgobject-2.0.so.0 libgio-2.0.so.0 libgmodule-2.0.so.0 libgthread-2.0.so.0
libgtk-3.so.0 libgdk-3.so.0 libgdk_pixbuf-2.0.so.0 libpango-1.0.so.0 libpangocairo-1.0.so.0
libcairo.so.2 libcairo-gobject.so.2 libatk-1.0.so.0 libatk-bridge-2.0.so.0
libX11.so.6 libXext.so.6 libXfixes.so.3 libXdamage.so.1 libXrandr.so.2 libXi.so.6
libXv.so.1 libXrender.so.1 libXcomposite.so.1 libXcursor.so.1 libXinerama.so.1 libxcb.so.1
libwayland-client.so.0 libwayland-server.so.0 libwayland-cursor.so.0 libwayland-egl.so.1
libEGL.so.1 libGL.so.1 libGLX.so.0 libGLdispatch.so.0 libGLESv2.so.2 libvulkan.so.1
libdrm.so.2 libgbm.so.1 libudev.so.1 libsystemd.so.0 libdbus-1.so.3
libpipewire-0.3.so.0 libpulse.so.0 libpulse-mainloop-glib.so.0 libasound.so.2
""".split())
# Ubuntu 22.04 codec/parser dependencies: SONAME -> binary package, source
# package, archive component, common license texts. Each installed binary is
# checked against dpkg's recorded MD5 before its SHA256 is put in our manifest.
SYSTEM_BUNDLES = {
    "libvpx.so.7": ("libvpx7", "libvpx", "main", ()),
    "libFLAC.so.8": ("libflac8", "flac", "main", ()),
    "libogg.so.0": ("libogg0", "libogg", "main", ()),
    "libSoundTouch.so.1": ("libsoundtouch1", "soundtouch", "universe", ("LGPL-2.1",)),
    "libopenh264.so.6": ("libopenh264-6", "openh264", "universe", ()),
    "libxml2.so.2": ("libxml2", "libxml2", "main", ()),
    "libz.so.1": ("zlib1g", "zlib", "main", ()),
    "libbz2.so.1.0": ("libbz2-1.0", "bzip2", "main", ()),
    "liblzma.so.5": ("liblzma5", "xz-utils", "main", ()),
    "libicuuc.so.70": ("libicu70", "icu", "main", ()),
    "libicudata.so.70": ("libicu70", "icu", "main", ()),
    "libicui18n.so.70": ("libicu70", "icu", "main", ()),
    "libunwind.so.8": ("libunwind8", "libunwind", "main", ()),
    "libdw.so.1": ("libdw1", "elfutils", "main", ("LGPL-3", "GPL-2")),
    "libelf.so.1": ("libelf1", "elfutils", "main", ("LGPL-3", "GPL-2")),
}
PRIVATE_MEDIA = re.compile(r"lib(?:gst[^/]*|ges-1\.0|orc-0\.4|avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample)\.so(?:\..*)?$")
LIBAV_ABI = {"avformat": 61, "avcodec": 61, "avutil": 59, "swresample": 5, "swscale": 8, "avfilter": 10}


def sha256(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def clean_environment(inherited=None):
    source = os.environ if inherited is None else inherited
    result = {k: v for k, v in source.items()
              if not k.upper().startswith(("GST_", "GSTREAMER_", "GIO_", "LD_"))
              and k.upper() not in {"GI_TYPELIB_PATH", "GSETTINGS_SCHEMA_DIR", "LIBRARY_PATH", "PKG_CONFIG_PATH"}}
    result.update(PATH="/usr/bin:/bin", LC_ALL="C", LANG="C")
    return result


def run(command, env=None):
    return subprocess.run([str(x) for x in command], check=True, capture_output=True,
                          text=True, timeout=120, env=clean_environment() if env is None else env).stdout


def runtime_environment(bundle, registry_path, inherited=None):
    root, registry = Path(bundle).resolve(), Path(registry_path).resolve()
    if registry.is_relative_to(root):
        raise ValueError("Registry must be outside the read-only application payload")
    environment = clean_environment(inherited)
    environment.update(LD_LIBRARY_PATH=str(root / LIB),
                       GST_PLUGIN_SYSTEM_PATH_1_0=str(root / PLUGINS), GST_PLUGIN_PATH_1_0="",
                       GST_PLUGIN_SCANNER_1_0=str(root / SCANNER), GST_REGISTRY_1_0=str(registry))
    return environment


def library_basename(name):
    if not re.fullmatch(r"[A-Za-z0-9_+.-]+\.so(?:\.[0-9]+)*", name):
        raise ValueError("Invalid ELF dependency basename: " + repr(name))
    return name


def library_name(name):
    library_basename(name)
    if any(x in name.lower() for x in ("x264", "x265", "fdk", "faac", "faad", "vo-aac", "voaac", "dvdcss")):
        raise ValueError("Unapproved codec dependency: " + name)
    match = re.fullmatch(r"lib(av\w+|swscale|swresample)\.so\.(\d+)", name)
    if match and LIBAV_ABI.get(match[1]) != int(match[2]):
        raise ValueError("Wrong private FFmpeg ABI: " + name)
    return name


@dataclass(frozen=True)
class Elf:
    needed: frozenset
    soname: str | None
    runpath: str | None


def elf_info(path, execute=run):
    path = Path(path)
    with path.open("rb") as stream:
        header = stream.read(20)
    if (len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or
            int.from_bytes(header[18:20], "little") != 62):
        raise ValueError("Expected x86_64 little-endian ELF64: " + str(path))
    text = execute(["readelf", "--wide", "--dynamic", path])
    needed, sonames, paths = set(), [], []
    for line in text.splitlines():
        match = re.search(r"\((NEEDED|SONAME|RPATH|RUNPATH)\).*\[([^\]]*)\]", line)
        if not match:
            if re.search(r"\((NEEDED|SONAME|RPATH|RUNPATH)\)", line):
                raise ValueError("Malformed ELF dynamic entry: " + line)
            continue
        kind, value = match.groups()
        if kind == "NEEDED": needed.add(library_name(value))
        elif kind == "SONAME": sonames.append(library_name(value))
        else: paths.append(value)
    if len(sonames) > 1 or len(paths) > 1:
        raise ValueError("Ambiguous ELF SONAME/search path: " + str(path))
    return Elf(frozenset(needed), sonames[0] if sonames else None, paths[0] if paths else None)


def private_file(home, relative):
    relative = Path(relative)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Invalid private SDK path")
    resolved = (home / relative).resolve(strict=True)
    if not resolved.is_relative_to(home) or not resolved.is_file():
        raise ValueError("SDK file escapes its prefix: " + str(relative))
    return resolved


def sdk_index(home):
    result = {}
    for path in (home / "lib").glob("*.so*"):
        # Index the verified SDK without approving every installed library for
        # distribution. elf_info applies codec/ABI policy to actual roots and
        # DT_NEEDED entries when the runtime closure selects them.
        name = library_basename(path.name)
        if name in SYSTEM_LIBRARIES:
            raise ValueError("Private SDK must not replace desktop/system ABI: " + name)
        resolved = private_file(home, path.relative_to(home))
        if name in result and result[name] != resolved:
            raise ValueError("SDK library basename collision: " + name)
        result[name] = resolved
    return result


def system_library(name, execute=run):
    if name not in SYSTEM_BUNDLES:
        raise ValueError("Unreviewed non-SDK dependency: " + name)
    matches = set()
    for line in execute(["/sbin/ldconfig", "-p"]).splitlines():
        match = re.match(r"\s*(\S+)\s+\(([^)]*)\)\s+=>\s+(\S+)\s*$", line)
        if match and match[1] == name and "x86-64" in match[2]:
            path = Path(match[3]).resolve(strict=True)
            if not any(path.is_relative_to(Path(base)) for base in ("/usr/lib", "/lib")):
                raise ValueError("System dependency resolves outside distribution libraries")
            matches.add(path)
    if len(matches) != 1:
        raise ValueError("Missing/ambiguous distribution dependency: " + name)
    return matches.pop()


def dependency_closure(home, seeds, execute=run, resolve_system=system_library):
    home = Path(home).resolve()
    index, result, system = sdk_index(home), {}, set()
    pending = [(Path(path), None) for path in seeds]
    while pending:
        path, required_name = pending.pop()
        path = path.resolve(strict=True)
        info = elf_info(path, execute)
        name = required_name or info.soname or path.name
        if required_name and info.soname != required_name:
            raise ValueError("ELF SONAME mismatch for " + required_name)
        if name in result:
            if result[name][0] != path:
                raise ValueError("ELF runtime basename collision: " + name)
            continue
        if path.is_relative_to(home):
            private_file(home, path.relative_to(home))
        elif name not in SYSTEM_BUNDLES or PRIVATE_MEDIA.fullmatch(name):
            raise ValueError("Non-SDK media library or seed: " + str(path))
        result[name] = (path, info)
        for dependency in sorted(info.needed):
            if dependency in SYSTEM_LIBRARIES:
                if dependency in index:
                    raise ValueError("SDK shadows system ABI: " + dependency)
                system.add(dependency)
            elif dependency in index:
                pending.append((index[dependency], dependency))
            elif PRIVATE_MEDIA.fullmatch(dependency):
                raise ValueError("Private media dependency is missing; system fallback forbidden: " + dependency)
            else:
                pending.append((resolve_system(dependency, execute), dependency))
    return result, system


def dpkg_provenance(path, name, execute=run):
    release = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            release[key] = value.strip('"')
    if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "22.04":
        raise ValueError("Codec provenance is pinned to the Ubuntu 22.04 build baseline")
    package, source, component, common = SYSTEM_BUNDLES[name]
    # Query both canonical and usr-merged spelling; require one package owner.
    owners = set()
    for spelling in {str(path), str(path).removeprefix("/usr")}:
        try: listing = execute(["dpkg-query", "--search", spelling])
        except subprocess.CalledProcessError: continue
        for line in listing.splitlines():
            if ": " in line and line.rsplit(": ", 1)[1] == spelling:
                owners.add(line.rsplit(": ", 1)[0])
    if not owners or any(owner.split(":")[0] != package for owner in owners):
        raise ValueError("Unapproved dpkg owner for " + str(path))
    identity = execute(["dpkg-query", "--show", "--showformat=${binary:Package}\n${Version}\n${source:Package}\n${source:Version}\n${Architecture}\n", package]).splitlines()
    if len(identity) != 5 or identity[0].split(":")[0] != package or identity[2] != source or identity[4] != "amd64":
        raise ValueError("Distribution package identity/source mismatch: " + name)
    md5file = Path("/var/lib/dpkg/info") / (identity[0] + ".md5sums")
    if not md5file.is_file(): md5file = md5file.with_name(package + ".md5sums")
    expected = []
    for line in md5file.read_text().splitlines():
        digest, relative = line.split(maxsplit=1)
        if (Path("/") / relative).resolve() == path: expected.append(digest)
    with path.open("rb") as stream: actual = hashlib.file_digest(stream, "md5").hexdigest()
    if expected != [actual]:
        raise ValueError("Installed codec differs from dpkg package checksum: " + name)
    copyright_file = (Path("/usr/share/doc") / package / "copyright").resolve(strict=True)
    if not copyright_file.is_relative_to(Path("/usr/share/doc")):
        raise ValueError("Distribution copyright path escapes documentation")
    licenses = [copyright_file, *(Path("/usr/share/common-licenses") / x for x in common)]
    if any(not p.is_file() for p in licenses): raise ValueError("Missing distribution license text")
    prefix = source[:4] if source.startswith("lib") else source[:1]
    return {"origin": "ubuntu-dpkg", "package": identity[0], "version": identity[1],
            "source_package": source, "source_version": identity[3], "installed_md5": actual,
            "source_url": f"https://archive.ubuntu.com/ubuntu/pool/{component}/{prefix}/{source}/"}, licenses


def _receipt_entries(home, report):
    sources = {entry["id"]: entry for entry in report["sources"]}
    files = {}
    for entry in report["files"]:
        if "symlink" in entry:
            continue
        path = private_file(home, entry["path"])
        if sha256(path) != entry["sha256"] or entry["component"] not in sources:
            raise ValueError("SDK receipt hash/component mismatch: " + entry["path"])
        if path in files and files[path] != entry:
            # Symlink aliases may describe the same verified physical file.
            previous = files[path]
            if (previous["sha256"], previous["component"]) != (entry["sha256"], entry["component"]):
                raise ValueError("Conflicting SDK ownership")
        files[path] = entry
    for entry in report["files"]:
        if "symlink" not in entry:
            continue
        alias = home / entry["path"]
        path = private_file(home, entry["path"])
        if (not alias.is_symlink() or os.readlink(alias) != entry["symlink"] or
                path not in files or entry["component"] != files[path]["component"]):
            raise ValueError("SDK symlink has no matching verified physical file")
    for entry in sources.values():
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) or not entry["url"].startswith("https://"):
            raise ValueError("Unverified SDK source provenance")
        if not entry["license_files"]: raise ValueError("SDK component has no license evidence")
    return sources, files


def plugin_metadata(text, expected_path, version):
    match = re.search(r"^Plugin Details:[ \t]*\n(.*?)(?:\n\S|\Z)", text, re.M | re.S)
    if not match: raise ValueError("gst-inspect did not identify the plugin")
    result = dict(re.findall(r"^[ \t]+(Name|Filename|Version|License|Source module)[ \t]+([^\n]+?)[ \t]*$", match[1], re.M))
    if (set(result) != {"Name", "Filename", "Version", "License", "Source module"} or
            Path(result["Filename"]).resolve() != expected_path.resolve() or result["Version"] != version):
        raise ValueError("Wrong plugin version/path: " + repr(result))
    if result["License"] not in {"LGPL", "LGPLv2", "LGPLv2+", "LGPLv2.1", "LGPLv2.1+", "MIT", "MIT/X11", "BSD"}:
        raise ValueError("Unapproved plugin license: " + result["License"])
    return result


def prepare_runtime(sdk_home, destination, package=None, execute=run):
    import install_linux_gstreamer as sdk
    home, destination = Path(sdk_home).resolve(), Path(destination).absolute()
    package = sdk.load_lock() if package is None else package
    report = sdk.verify_sdk(home, package)
    if report.get("version") != "1.28.9" or report.get("target") != "linux-x86_64":
        raise ValueError("Runtime needs the verified Linux x86_64 GStreamer 1.28.9 SDK")
    sources, receipts = _receipt_entries(home, report)
    if destination.exists() or destination.is_symlink() or destination.resolve().is_relative_to(home):
        raise ValueError("Refusing to overwrite payload or modify SDK")
    index = sdk_index(home)
    seeds = [index[name] for name in ROOT_LIBRARIES]
    plugin_sources = {name: private_file(home, "lib/gstreamer-1.0/libgst" + name + ".so") for name in PLUGIN_FACTORIES}
    scanner = private_file(home, "libexec/gstreamer-1.0/gst-plugin-scanner")
    inspector = private_file(home, "bin/gst-inspect-1.0")
    seeds += [scanner, *plugin_sources.values()]
    closure, system = dependency_closure(home, seeds, execute)
    inspection_closure, _ = dependency_closure(home, [*seeds, inspector], execute)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".linux-media-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "payload"
        files, licenses, copied = [], {}, {}
        for name, (path, info) in sorted(inspection_closure.items()):
            relative = (SCANNER if path == scanner else INSPECTOR if path == inspector else
                        PLUGINS / path.name if path in plugin_sources.values() else LIB / name)
            if path in receipts:
                source = sources[receipts[path]["component"]]
                provenance = {"origin": "private-sdk", "component": source["id"],
                              "source_version": source["version"], "source_url": source["url"],
                              "source_sha256": source["sha256"]}
                texts = [private_file(home, p) for p in source["license_files"]]
            else:
                if path.is_relative_to(home): raise ValueError("SDK ELF has no verified receipt: " + str(path))
                provenance, texts = dpkg_provenance(path, name, execute)
            output = stage / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, output)
            search = "$ORIGIN" if relative.parent == LIB else "$ORIGIN/../lib"
            execute(["patchelf", "--set-rpath", search, output])
            patched = elf_info(output, execute)
            if patched.needed != info.needed or patched.soname != info.soname or patched.runpath != search:
                raise ValueError("ELF relocation changed dependency identity or retained a foreign search path")
            evidence = []
            for text in texts:
                digest = sha256(text)
                license_relative = Path("runtime/licenses") / (digest + "-" + text.name)
                if digest not in licenses:
                    (stage / license_relative).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(text, stage / license_relative)
                    licenses[digest] = license_relative.as_posix()
                evidence.append(licenses[digest])
            record = {"path": relative.as_posix(), "sha256": sha256(output), "source_file_sha256": sha256(path),
                      "needed": sorted(info.needed), "soname": info.soname, "runpath": search,
                      "licenses": evidence, **provenance}
            copied[name] = output
            if name in closure: files.append(record)
        registry = Path(temporary) / "registry.bin"
        environment = runtime_environment(stage, registry)
        plugins = {}
        for name, factories in PLUGIN_FACTORIES.items():
            expected = stage / PLUGINS / plugin_sources[name].name
            expected_version = package.get("plugin_versions", {}).get(name, report["version"])
            entry = plugin_metadata(execute([stage / INSPECTOR, name], env=environment), expected, expected_version)
            for factory in factories:
                actual = plugin_metadata(execute([stage / INSPECTOR, factory], env=environment), expected, expected_version)
                if actual["Name"] != entry["Name"]: raise ValueError("Factory belongs to unexpected plugin")
            entry["Filename"] = expected.relative_to(stage).as_posix()
            plugins[name] = {"metadata": entry, "required_factories": list(factories)}
        for name, output in copied.items():
            if name not in closure: output.unlink()
        manifest = {"schema_version": 1, "target": "linux-x86_64", "gstreamer_version": "1.28.9",
                    "sdk_lock_sha256": report.get("lock_sha256"), "files": files,
                    "system_dependencies": sorted(system), "plugins": plugins,
                    "licenses": [{"path": path, "sha256": digest} for digest, path in sorted(licenses.items())]}
        (stage / "runtime/manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        stage.rename(destination)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk_home", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    result = prepare_runtime(args.sdk_home, args.destination)
    print(f"Prepared {len(result['files'])} private Linux media files in {args.destination}")


if __name__ == "__main__":
    main()
