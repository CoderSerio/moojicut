#!/usr/bin/env python3
"""Build a closed Windows media runtime from the verified private SDK.

The output is a payload to merge beside the application EXE: every dependent
DLL and the plugin scanner live at that level, so the Windows loader can find
them before main(). Only selected plugins live in runtime/gstreamer/plugins.
The application must set the equivalent runtime_environment before gst_init.
MSVC CRT imports come only from the active VS toolchain's signed Redist files.
No SDK-wide plugin scan, system DLL harvesting, dumpbin, or FFmpeg CLI is used.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import tempfile

import install_gstreamer as sdk


PLUGIN_DIR = Path("runtime/gstreamer/plugins")
SCANNER = "gst-plugin-scanner.exe"
INSPECTOR = "gst-inspect-1.0.exe"

# Plugin filenames here are a bounded discovery list, not proof of their
# contents. The actual Plugin Details and each required factory are inspected
# after copying to an isolated registry/plugin directory.
PLUGIN_FACTORIES = {
    "coreelements": ("queue", "filesrc", "filesink", "fakesink", "typefind", "capsfilter"),
    "typefindfunctions": (),
    "app": ("appsink", "appsrc"),
    "playback": ("decodebin", "decodebin3", "uridecodebin", "uridecodebin3", "playsink"),
    "encoding": ("encodebin", "encodebin2"),
    "ges": ("gesdemux",),
    "nle": ("nlecomposition", "nlesource", "nleoperation"),
    "compositor": ("compositor",),
    "videoconvertscale": ("videoconvert", "videoscale"),
    "videorate": ("videorate",),
    "videocrop": ("videocrop",),
    "videotestsrc": ("videotestsrc",),
    "videobox": ("videobox",),
    "videofilter": ("videoflip",),
    "audioconvert": ("audioconvert",),
    "audioresample": ("audioresample",),
    "audiorate": ("audiorate",),
    "audiotestsrc": ("audiotestsrc",),
    "audiomixer": ("audiomixer",),
    "audiofx": ("scaletempo",),
    "volume": ("volume",),
    "soundtouch": ("pitch",),
    "isomp4": ("qtdemux", "mp4mux"),
    "videoparsersbad": ("h264parse",),
    "audioparsers": ("aacparse",),
    "libav": ("avdec_h264", "avdec_aac", "avenc_aac"),
    "openh264": ("openh264enc",),
    "matroska": ("matroskademux", "matroskamux"),
    "vpx": ("vp8dec", "vp8enc"),
    "flac": ("flacdec", "flacenc"),
    "autodetect": ("autoaudiosink",),
}
ROOT_DLLS = (
    "ges-1.0-0.dll", "gstreamer-1.0-0.dll", "gstapp-1.0-0.dll",
    "gstpbutils-1.0-0.dll", "gstvideo-1.0-0.dll", "gstaudio-1.0-0.dll",
    "glib-2.0-0.dll", "gobject-2.0-0.dll", "gio-2.0-0.dll",
    "avformat-61.dll", "avcodec-61.dll", "avutil-59.dll",
)

# Windows 10 OS components, not arbitrary DLLs installed on the build machine.
# In particular, vcruntime/msvcp redistributables are NOT OS files: the active
# Visual Studio Redist directory is their only separately verified provider.
SYSTEM_DLLS = frozenset("""
advapi32.dll avrt.dll bcrypt.dll bcryptprimitives.dll cabinet.dll cfgmgr32.dll
comctl32.dll comdlg32.dll crypt32.dll cryptbase.dll d2d1.dll d3d9.dll d3d11.dll
d3d12.dll d3dcompiler_47.dll dcomp.dll dnsapi.dll dsound.dll dwmapi.dll dwrite.dll
dxgi.dll dxva2.dll gdi32.dll gdiplus.dll glu32.dll hid.dll imm32.dll iphlpapi.dll
kernel32.dll kernelbase.dll ksuser.dll mf.dll mfplat.dll mfreadwrite.dll
mfuuid.dll mmdevapi.dll msacm32.dll msimg32.dll msvcrt.dll netapi32.dll
ncrypt.dll normaliz.dll ntdll.dll ole32.dll oleaut32.dll opengl32.dll
powrprof.dll propsys.dll psapi.dll rpcrt4.dll rtworkq.dll secur32.dll
setupapi.dll shell32.dll shlwapi.dll user32.dll userenv.dll uxtheme.dll
ucrtbase.dll version.dll winhttp.dll wininet.dll winmm.dll winspool.drv
wintrust.dll winusb.dll ws2_32.dll wsock32.dll wtsapi32.dll
""".split())
BANNED_DLL_PARTS = ("x264", "x265", "fdk", "faac", "faad", "voaac", "vo-aac",
                    "mpeg2", "lame", "dvdcss")
SHARED_GSTREAMER_LICENSE = "share/licenses/gstreamer-1.0/LGPL-2.0-or-later.txt"
# Cerbero adds common licenses to files_devel; the good/libav packages select
# plugin categories without that directory. Their recipes use the same
# LGPLv2Plus enum/text as core. Preserve their source component in the report.
SHARED_GSTREAMER_LICENSE_COMPONENTS = frozenset(("gst-plugins-good-1.0", "gst-libav-1.0"))
CRT_DLLS = frozenset("""
vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll
msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll concrt140.dll
""".split())
CRT_COMPONENT = "microsoft-vc143-crt"


class MSVCRedist:
    """Lazy, bounded access to the build toolchain's official desktop x64 CRT.

    No PATH/System32 search. Authenticode, numeric file version and SHA256 are
    recorded before copying; only dependency-reachable files are distributed.
    """
    def __init__(self, package, execute=sdk.run, environment=None):
        self.policy = package["msvc_redist"]
        self.execute = execute
        self.environment = dict(os.environ if environment is None else environment)
        # os.environ itself is case-insensitive on Windows; dict(os.environ)
        # contains uppercase keys and no longer has that lookup behavior.
        self.environment_lookup = {key.casefold(): value for key, value in self.environment.items()}
        self.directory = None
        self.records = {}
        self.failure = None

    def _directory(self):
        if self.directory is not None:
            return self.directory
        if self.failure:
            raise ValueError(self.failure)
        try:
            value = self.environment_lookup.get("vctoolsinstalldir")
            if not value:
                raise ValueError("VCToolsInstallDir is required to locate official VS Redist CRT files")
            tools = Path(value).resolve()
            if (not re.fullmatch(r"14\.\d+\.\d+(?:\.\d+)?", tools.name) or
                    tools.parent.name.casefold() != "msvc" or tools.parent.parent.name.casefold() != "tools"):
                raise ValueError("Unexpected Visual Studio C++ toolchain directory: " + str(tools))
            vc = tools.parent.parent.parent
            root = vc / "Redist/MSVC"
            marker = vc / "Auxiliary/Build/Microsoft.VCRedistVersion.default.txt"
            if marker.is_file():
                version = marker.read_text(encoding="utf-8-sig").strip()
                if not re.fullmatch(r"14\.\d+\.\d+(?:\.\d+)?", version):
                    raise ValueError("Invalid Visual Studio default Redist version marker")
                version_root = root / version
            elif (root / "v143").is_dir():
                version_root = root / "v143"
            else:
                versions = [p for p in root.iterdir() if p.is_dir() and re.fullmatch(r"14\.\d+\.\d+(?:\.\d+)?", p.name)]
                if not versions:
                    raise ValueError("No desktop VC143 redistributables in " + str(root))
                version_root = max(versions, key=lambda p: tuple(map(int, p.name.split("."))))
            directory = version_root / "x64/Microsoft.VC143.CRT"
            if not directory.is_dir() or not directory.resolve().is_relative_to(root.resolve()):
                raise ValueError("Missing or non-private VS desktop x64 CRT directory: " + str(directory))
            self.directory = directory.resolve()
            self.tool_version = tuple(map(int, tools.name.split(".")))
            self.source_root = vc.resolve()
            return self.directory
        except (OSError, ValueError) as error:
            self.failure = str(error)
            raise ValueError(self.failure) from error

    def resolve(self, name):
        if name not in CRT_DLLS:
            raise ValueError("Not an approved desktop CRT dependency: " + name)
        directory = self._directory()
        source = directory / name
        if not source.is_file() or source.is_symlink() or source.resolve().parent != directory:
            raise ValueError("Missing official VS Redist dependency: " + str(source))
        if name not in self.records:
            powershell = Path(self.environment_lookup.get("systemroot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            # pwsh 7 -> Python -> powershell.exe otherwise inherits PS7's
            # incompatible modules. Use only this Windows PowerShell's modules,
            # removing every case variant before setting the child-only value.
            environment = {key: value for key, value in self.environment.items()
                           if key.casefold() != "psmodulepath"}
            environment.update(MOOJICUT_CRT_FILE=str(source), PSMODULEPATH=str(powershell.parent / "Modules"))
            script = ("$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); "
                      "$env:PSModulePath=$PSHOME+'\\Modules'; "
                      "Import-Module ($PSHOME+'\\Modules\\Microsoft.PowerShell.Security\\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop; "
                      "$p=$env:MOOJICUT_CRT_FILE; $s=Get-AuthenticodeSignature -LiteralPath $p; "
                      "$v=(Get-Item -LiteralPath $p).VersionInfo; "
                      "@{status=$s.Status.ToString(); signer=$s.SignerCertificate.Subject; "
                      "thumbprint=$s.SignerCertificate.Thumbprint; company=$v.CompanyName; copyright=$v.LegalCopyright; "
                      "version=(@($v.FileMajorPart,$v.FileMinorPart,$v.FileBuildPart,$v.FilePrivatePart) -join '.')} "
                      "| ConvertTo-Json -Compress")
            metadata = json.loads(self.execute([powershell, "-NoProfile", "-NonInteractive", "-Command", script], env=environment))
            version = metadata.get("version", "")
            if (metadata.get("status") != "Valid" or metadata.get("company") != "Microsoft Corporation" or
                    not re.search(r"(?:^|,\s*)CN=Microsoft Corporation(?:,|$)", metadata.get("signer", "")) or
                    not metadata.get("thumbprint") or not re.fullmatch(r"14\.\d+\.\d+\.\d+", version) or
                    tuple(map(int, version.split("."))) < self.tool_version):
                raise ValueError("Unverified/outdated Microsoft CRT " + str(source) + ": " + repr(metadata))
            self.records[name] = {"source_path": str(source),
                                  "redist_path": source.relative_to(self.source_root).as_posix(),
                                  "sha256": sdk.digest(source), **metadata}
        return source

    def owns(self, path):
        return path.name.casefold() in self.records and Path(self.records[path.name.casefold()]["source_path"]) == path


def _system(name):
    return name in SYSTEM_DLLS or bool(re.fullmatch(r"(?:api|ext)-ms-win-[a-z0-9-]+\.dll", name))


def _dll_name(value):
    name = value.casefold()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.+-]*\.(?:dll|drv)", name):
        raise ValueError("Invalid PE dependency basename: " + repr(value))
    if any(part in name for part in BANNED_DLL_PARTS):
        raise ValueError("Disallowed GPL/nonfree/alternate AAC dependency: " + name)
    return name


def pe_dependencies(path):
    """Read normal and delay imports from a bounded PE32+ AMD64 image.

    Public PE layout, including RVA/VA delay-import descriptors; no execution
    or toolchain-specific disassembler is necessary for the released runtime.
    """
    data = Path(path).read_bytes()
    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError("Truncated PE structure: " + str(path))
        return struct.unpack_from(fmt, data, offset)
    if data[:2] != b"MZ":
        raise ValueError("Not a PE image: " + str(path))
    pe, = unpack("<I", 0x3c)
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Invalid PE signature: " + str(path))
    machine, sections, _, _, _, optional_size, _ = unpack("<HHIIIHH", pe + 4)
    optional = pe + 24
    magic, = unpack("<H", optional)
    if machine != 0x8664 or magic != 0x20b:
        raise ValueError("Runtime requires x64 PE32+: " + str(path))
    if not 1 <= sections <= 96 or optional_size < 112:
        raise ValueError("Invalid PE header size: " + str(path))
    unpack("<" + "B" * optional_size, optional)
    image_base, = unpack("<Q", optional + 24)
    headers_size, = unpack("<I", optional + 60)
    directories, = unpack("<I", optional + 108)
    if directories > (optional_size - 112) // 8 or headers_size > len(data):
        raise ValueError("Invalid PE directory/header bounds: " + str(path))
    ranges = []
    for i in range(sections):
        entry = optional + optional_size + i * 40
        _, virtual_size, address, raw_size, raw, _, _, _, _, _ = unpack("<8sIIIIIIHHI", entry)
        if raw + raw_size > len(data) or address + max(virtual_size, raw_size) > 0x100000000:
            raise ValueError("Invalid PE section bounds: " + str(path))
        ranges.append((address, raw_size, raw))
    def offset(rva, size):
        if rva < 0 or size < 0:
            raise ValueError("Invalid PE RVA")
        if rva < headers_size and rva + size <= headers_size:
            return rva
        found = [raw + rva - address for address, length, raw in ranges
                 if address <= rva and rva + size <= address + length]
        if len(found) != 1:
            raise ValueError("Unmapped/ambiguous PE RVA: " + str(path))
        return found[0]
    def name_at(rva):
        value = bytearray()
        for i in range(260):
            byte = data[offset(rva + i, 1)]
            if not byte:
                try:
                    return _dll_name(value.decode("ascii"))
                except UnicodeDecodeError as error:
                    raise ValueError("Non-ASCII PE dependency") from error
            value.append(byte)
        raise ValueError("Unterminated PE dependency name")
    result = set()
    for directory, descriptor_size in ((1, 20), (13, 32)):
        if directories <= directory:
            continue
        rva, size = unpack("<II", optional + 112 + directory * 8)
        if not rva and not size:
            continue
        if not rva or size < descriptor_size or size // descriptor_size > 8192:
            raise ValueError("Invalid PE import directory")
        terminated = False
        for i in range(size // descriptor_size):
            values = unpack("<" + "I" * (descriptor_size // 4), offset(rva + i * descriptor_size, descriptor_size))
            if not any(values):
                terminated = True
                break
            if directory == 1:
                name_rva = values[3]
            else:
                if values[0] & ~1:
                    raise ValueError("Unsupported delay import attributes")
                name_rva = values[1] if values[0] & 1 else values[1] - image_base
            result.add(name_at(name_rva))
        if not terminated:
            raise ValueError("Unterminated PE import directory")
    return result


def _bin_index(home):
    found = {}
    for path in (Path(home) / "bin").iterdir():
        if path.suffix.casefold() != ".dll":
            continue
        name = path.name.casefold()
        if name in found:
            raise ValueError("Case-insensitive SDK DLL collision: " + name)
        found[name] = path
    return found


def dependency_closure(sdk_home, seeds, redist=None):
    """SDK/bin plus explicitly verified VS CRT; never search PATH/System32."""
    home = Path(sdk_home).resolve()
    index = _bin_index(home)
    pending, result, problems = list(seeds), {}, set()
    while pending:
        path = Path(pending.pop())
        if not (redist and redist.owns(path)):
            try:
                relative = (path.parent.resolve() / path.name).relative_to(home).as_posix()
            except ValueError as error:
                raise ValueError("Dependency is outside private SDK or verified VS Redist") from error
            path = sdk.require_private_file(home, relative)
        name = path.name.casefold()
        if path.suffix.casefold() == ".dll":
            _dll_name(path.name)
        if name in result:
            if result[name] != path:
                raise ValueError("Runtime DLL basename collision: " + name)
            continue
        result[name] = path
        for dependency in sorted(pe_dependencies(path)):
            if _system(dependency):
                continue
            if dependency in CRT_DLLS and redist:
                try:
                    pending.append(redist.resolve(dependency))
                except (OSError, ValueError) as error:
                    problems.add(str(error) + " (required by " + path.name + ")")
                continue
            if dependency not in index:
                problems.add("Missing private SDK dependency " + dependency + " required by " + path.name)
                continue
            pending.append(index[dependency])
    if problems:
        raise ValueError("Runtime dependency closure failed:\n" + "\n".join(sorted(problems)))
    return result


def runtime_environment(bundle, registry_path, inherited=None):
    root = Path(bundle).resolve()
    original = dict(os.environ if inherited is None else inherited)
    environment = {key: value for key, value in original.items()
                   if not key.upper().startswith(("GST_", "GSTREAMER_", "GIO_"))
                   and key.upper() not in ("GSETTINGS_SCHEMA_DIR", "GI_TYPELIB_PATH")}
    lookup = {key.casefold(): value for key, value in original.items()}
    windows = Path(lookup.get("systemroot", r"C:\Windows"))
    environment.update({
        "PATH": os.pathsep.join(map(str, (root, windows / "System32", windows))),
        "GST_PLUGIN_PATH_1_0": "", "GST_PLUGIN_SYSTEM_PATH_1_0": str(root / PLUGIN_DIR),
        "GST_PLUGIN_SCANNER_1_0": str(root / SCANNER),
        "GST_REGISTRY_1_0": str(Path(registry_path).resolve()),
        "GIO_MODULE_DIR": str(root / "runtime/gio-modules"), "GIO_EXTRA_MODULES": "",
        "GIO_USE_VFS": "local", "GIO_USE_PROXY_RESOLVER": "dummy",
        "GSETTINGS_SCHEMA_DIR": str(root / "runtime/schemas"),
        "GST_DEBUG": "0", "LC_ALL": "C", "LANG": "C",
    })
    return environment


def _component(path, plugin_metadata=None):
    if plugin_metadata:
        modules = {"gstreamer": "gstreamer-1.0", "gst-plugins-base": "gst-plugins-base-1.0",
                   "gst-plugins-good": "gst-plugins-good-1.0", "gst-plugins-bad": "gst-plugins-bad-1.0",
                   "gst-libav": "gst-libav-1.0", "gst-editing-services": "gst-editing-services-1.0"}
        module = plugin_metadata.get("Source module")
        if module not in modules:
            raise ValueError("Unknown plugin license/source component: " + str(module))
        return (modules[module],)
    name = path.name.casefold()
    if name in (SCANNER, INSPECTOR):
        return ("gstreamer-1.0",)
    base = name.removeprefix("lib")
    if base == "ges-1.0-0.dll":
        return ("gst-editing-services-1.0",)
    if re.fullmatch(r"(?:gstreamer|gstbase|gstcontroller|gstnet)-1\.0-0\.dll", base):
        return ("gstreamer-1.0",)
    if re.fullmatch(r"gst(?:app|pbutils|video|audio|tag|riff|rtp|rtsp|sdp|fft|allocators|gl)-1\.0-0\.dll", base):
        return ("gst-plugins-base-1.0",)
    if re.fullmatch(r"gst(?:codecparsers|play|player|photography|transcoder|insertbin)-1\.0-0\.dll", base):
        return ("gst-plugins-bad-1.0",)
    if re.fullmatch(r"gstvalidate(?:-.*)?\.dll", base):
        return ("gst-devtools-1.0",)
    if re.fullmatch(r"(?:glib|gobject|gio|gmodule|gthread)-2\.0-0\.dll", base):
        return ("glib",)
    if re.fullmatch(r"(?:avformat-61|avcodec-61|avutil-59|avfilter-10|swscale-8|swresample-5)\.dll", base):
        return ("ffmpeg",)
    patterns = (
        (r"ffi(?:-\d+)?\.dll", ("libffi",)),
        (r"pcre2-[0-9-]+\.dll", ("pcre2",)),
        (r"(?:z|zlib1)\.dll", ("zlib",)),
        (r"bz2(?:-\d+)?\.dll", ("bzip2",)),
        (r"intl(?:-[0-9.]+)?\.dll", ("proxy-libintl",)),
        (r"(?:gettextlib|gettextsrc)(?:-[0-9.]+)?\.dll", ("gettext",)),
        (r"iconv(?:-\d+)?\.dll", ("libiconv",)),
        (r"xml2(?:-\d+)?\.dll", ("libxml2",)),
        (r"orc-0\.4-0\.dll", ("orc",)),
        (r"soundtouch(?:-[0-9.]+)?\.dll", ("soundtouch",)),
        (r"openh264(?:-[0-9.]+)?\.dll", ("openh264",)),
        (r"vpx(?:-[0-9.]+)?\.dll", ("vpx", "libvpx")),
        (r"flac(?:-[0-9.]+)?\.dll", ("flac",)),
        (r"ogg(?:-[0-9.]+)?\.dll", ("libogg", "ogg")),
        (r"json-glib-1\.0-0\.dll", ("json-glib",)),
        (r"png16(?:-[0-9]+)?\.dll", ("libpng",)),
        (r"jpeg(?:-[0-9]+)?\.dll", ("libjpeg-turbo",)),
        (r"zstd(?:-[0-9]+)?\.dll", ("zstd",)),
        (r"lzma(?:-[0-9]+)?\.dll", ("xz",)),
    )
    for pattern, components in patterns:
        if re.fullmatch(pattern, base):
            return components
    raise ValueError("No reviewed license/source mapping for runtime DLL: " + path.name)


def _license_sources(home, candidates, plugin):
    for component in candidates:
        directory = home / "share/licenses" / component
        if directory.is_dir():
            return component, sorted(path for path in directory.rglob("*") if path.is_file()), {
                "license_source": directory.relative_to(home).as_posix()}
    component = candidates[0]
    if (component in SHARED_GSTREAMER_LICENSE_COMPONENTS and plugin and
            plugin.get("License") in {"LGPL", "LGPLv2", "LGPLv2+"}):
        license_file = sdk.require_private_file(home, SHARED_GSTREAMER_LICENSE)
        return component, [license_file], {
            "license_source": SHARED_GSTREAMER_LICENSE,
            "license_evidence": [
                "https://github.com/GStreamer/cerbero/blob/1.28.8/recipes/" + component + ".recipe",
                "https://github.com/GStreamer/cerbero/blob/1.28.8/recipes/custom.py",
                "https://github.com/GStreamer/cerbero/blob/1.28.8/cerbero/build/recipe.py",
                "https://github.com/GStreamer/cerbero/blob/1.28.8/cerbero/build/filesprovider.py",
                "https://github.com/GStreamer/cerbero/blob/1.28.8/cerbero/packages/package.py",
            ]}
    raise ValueError("Missing SDK license directory: " + "/".join(candidates))


def _safe_libav_configuration(configuration):
    # Official Cerbero builds FFmpeg with Meson; other verified SDK records
    # can carry upstream configure flags. Accept exact disabled options, not
    # substring matches, and reject contradictory/unknown licensing values.
    tokens = configuration.split()
    for name in ("gpl", "nonfree", "version3"):
        if any(token == "--enable-" + name or token.startswith("--enable-" + name + "=") or
               (token.startswith("-D" + name + "=") and token != "-D" + name + "=disabled")
               for token in tokens):
            return False
    return ("--disable-nonfree" in tokens or
            ("-Dnonfree=disabled" in tokens and "-Dversion3=disabled" in tokens))


def _load_report(home, package):
    report = json.loads(sdk.require_private_file(home, sdk.REPORT).read_text(encoding="utf-8"))
    if (report.get("schema_version") != 1 or report.get("version") != package["version"] or
            report.get("archive_sha256") != package["sha256"] or report.get("compiler") != "MSVC x64"):
        raise ValueError("Runtime requires the matching install_gstreamer verified SDK report")
    probe = report.get("probe", "")
    if "libav ABI 61 61 59; mov demux/mp4 mux available" not in probe:
        raise ValueError("Missing verified libav ABI/MP4 evidence")
    for library in ("libavformat", "libavcodec", "libavutil"):
        if not re.search(r"^" + library + r" license: LGPL version 2\.1 or later\s*$", probe, re.M):
            raise ValueError("Disallowed or absent libav license evidence")
    configuration = re.search(r"^libavformat configuration: (.+)$", probe, re.M)
    if not configuration or not _safe_libav_configuration(configuration[1]):
        raise ValueError("Missing safe FFmpeg build configuration evidence")
    return report


def _select(index, *names):
    found = [index[name.casefold()] for name in names if name.casefold() in index]
    if len(found) != 1:
        raise ValueError("Missing or ambiguous private SDK file: " + "/".join(names))
    return found[0]


def _plugin_metadata(text, stage, package, expected_path):
    metadata = sdk.plugin_metadata(text, stage, package)
    if (stage / metadata["Filename"]).resolve() != expected_path.resolve():
        raise ValueError("Factory resolved outside its selected runtime plugin")
    if metadata["License"] not in {"LGPL", "LGPLv2", "LGPLv2+", "LGPLv2.1", "LGPLv2.1+", "BSD", "MIT", "MPL", "MPL-2.0", "Apache-2.0", "Zlib"}:
        raise ValueError("Disallowed plugin license: " + metadata["License"])
    _component(expected_path, metadata)
    return metadata


def prepare_runtime(sdk_home, destination, package=None, execute=sdk.run):
    """Create a new relocatable payload atomically; never overwrite a bundle.

    execute is a normal subprocess runner, injectable only for portable build
    tests. Actual factory discovery is always against the isolated copied set.
    """
    home, destination = Path(sdk_home).resolve(), Path(destination).absolute()
    package = sdk.load_lock() if package is None else package
    verified = _load_report(home, package)
    if destination.exists() or destination.is_symlink() or destination.resolve().is_relative_to(home):
        raise ValueError("Refusing to overwrite runtime destination or modify SDK")
    bin_index = _bin_index(home)
    plugin_index = {}
    for path in (home / "lib/gstreamer-1.0").iterdir():
        if path.suffix.casefold() == ".dll":
            key = path.name.casefold()
            if key in plugin_index:
                raise ValueError("Case-insensitive SDK plugin collision: " + key)
            plugin_index[key] = path
    selected = {}
    for plugin in PLUGIN_FACTORIES:
        selected[plugin] = _select(plugin_index, "gst" + plugin + ".dll", "libgst" + plugin + ".dll")
    audio_plugin = "wasapi2" if any(name in plugin_index for name in ("gstwasapi2.dll", "libgstwasapi2.dll")) else "wasapi"
    selected[audio_plugin] = _select(plugin_index, "gst" + audio_plugin + ".dll", "libgst" + audio_plugin + ".dll")
    audio_factory = audio_plugin + "sink"
    seeds = [_select(bin_index, name, "lib" + name) for name in ROOT_DLLS]
    scanner = sdk.require_private_file(home, "libexec/gstreamer-1.0/" + SCANNER)
    inspector = sdk.require_private_file(home, "bin/" + INSPECTOR)
    seeds += [scanner, *selected.values()]
    redist = MSVCRedist(package, execute)
    closure = dependency_closure(home, [*seeds, inspector], redist)
    final_closure = dependency_closure(home, seeds, redist)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".gstreamer-runtime-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "payload"
        (stage / PLUGIN_DIR).mkdir(parents=True)
        (stage / "runtime/gio-modules").mkdir()
        (stage / "runtime/schemas").mkdir()
        plugin_sources = set(selected.values())
        copied = {}
        for name, source in closure.items():
            target = stage / PLUGIN_DIR / source.name if source in plugin_sources else stage / source.name
            shutil.copy2(source, target)
            if redist.owns(source) and sdk.digest(target) != redist.records[name]["sha256"]:
                raise ValueError("Microsoft CRT changed after signature verification: " + name)
            copied[name] = target
        registry = Path(temporary) / "registry.bin"
        environment = runtime_environment(stage, registry)
        version = execute([stage / INSPECTOR, "--version"], env=environment)
        if not re.search(r"\bGStreamer\s+" + re.escape(package["version"]) + r"(?:\s|$)", version):
            raise ValueError("Relocated runtime version mismatch")
        plugins, factories, reports = {}, {}, {}
        for plugin, source in selected.items():
            target = copied[source.name.casefold()]
            output = execute([stage / INSPECTOR, target], env=environment)
            plugins[plugin] = _plugin_metadata(output, stage, package, target)
            if plugins[plugin].get("Name") != plugin:
                raise ValueError("Selected file declares unexpected plugin: " + source.name)
            reports["plugin-" + plugin] = output
            required = (audio_factory,) if plugin == audio_plugin else PLUGIN_FACTORIES[plugin]
            for factory in required:
                output = execute([stage / INSPECTOR, factory], env=environment)
                factories[factory] = _plugin_metadata(output, stage, package, target)
                reports["factory-" + factory] = output
        # The inspector is build-only. Recompute without it rather than shipping
        # a developer tool or its incidental dependencies in the application.
        for name in closure.keys() - final_closure.keys():
            copied[name].unlink()
        license_records = {item["path"]: item["sha256"] for item in verified["licenses"]}
        source_licenses, license_problems = {}, []
        for name, source in sorted(final_closure.items()):
            if redist.owns(source):
                continue
            try:
                plugin = next((plugins[key] for key, value in selected.items() if value == source), None)
                record = _license_sources(home, _component(source, plugin), plugin)
                component, license_sources, _ = record
                if not license_sources:
                    raise ValueError("Empty runtime license component: " + component)
                for license_file in license_sources:
                    relative = license_file.relative_to(home).as_posix()
                    sdk.require_private_file(home, relative)
                    if license_records.get(relative) != sdk.digest(license_file):
                        raise ValueError("SDK license inventory changed or is unverified: " + relative)
                source_licenses[name] = record
            except (OSError, ValueError) as error:
                license_problems.append(source.name + ": " + str(error))
        if license_problems:
            raise ValueError("Runtime license/source inventory failed:\n" + "\n".join(license_problems))
        licenses, files = {}, []
        for name, source in sorted(final_closure.items()):
            if redist.owns(source):
                if CRT_COMPONENT not in licenses:
                    # Preserve the official provider/license references and
                    # per-file provenance, without calling proprietary CRT LGPL.
                    notice = stage / "runtime/licenses" / CRT_COMPONENT / "PROVENANCE.json"
                    notice.parent.mkdir(parents=True)
                    notice.write_text(json.dumps({**redist.policy,
                        "files": {key: value for key, value in redist.records.items() if key in final_closure}}, indent=2) + "\n", encoding="utf-8")
                    licenses[CRT_COMPONENT] = {**redist.policy, "files": [
                        {"path": notice.relative_to(stage).as_posix(), "sha256": sdk.digest(notice)}]}
                dependencies = sorted(pe_dependencies(source))
                files.append({"path": copied[name].relative_to(stage).as_posix(),
                              "component": CRT_COMPONENT, "origin": "visual-studio-redist",
                              **redist.records[name], "imports": dependencies,
                              "windows_system_imports": [item for item in dependencies if _system(item)]})
                continue
            component, license_sources, license_evidence = source_licenses[name]
            if component not in licenses:
                inventory = []
                for license_file in license_sources:
                    relative = license_file.relative_to(home).as_posix()
                    sdk.require_private_file(home, relative)
                    checksum = sdk.digest(license_file)
                    if license_records.get(relative) != checksum:
                        raise ValueError("SDK license inventory changed or is unverified: " + relative)
                    target = stage / "runtime/licenses" / license_file.relative_to(home / "share/licenses")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(license_file, target)
                    inventory.append({"path": target.relative_to(stage).as_posix(), "sha256": checksum})
                if not inventory:
                    raise ValueError("Empty runtime license component: " + component)
                licenses[component] = {"files": inventory, **license_evidence,
                    "recipe": "https://raw.githubusercontent.com/GStreamer/cerbero/" + package["version"] + "/recipes/" + component + ".recipe"}
            target = copied[name]
            dependencies = sorted(pe_dependencies(source))
            files.append({"path": target.relative_to(stage).as_posix(), "sdk_path": source.relative_to(home).as_posix(),
                          "sha256": sdk.digest(target), "component": component, "imports": dependencies,
                          "windows_system_imports": [item for item in dependencies if _system(item)]})
        report = {"schema_version": 1, "sdk_version": package["version"], "sdk_archive_sha256": package["sha256"],
                  "architecture": "x86_64", "files": files, "plugins": plugins, "factories": factories,
                  "preferred_audio_sink": audio_factory, "aac_encoder": "avenc_aac", "h264_encoder": "openh264enc",
                  "licenses": licenses, "sdk_probe": verified["probe"],
                  "layout": {"dll_directory": ".", "plugin_directory": PLUGIN_DIR.as_posix(), "scanner": SCANNER,
                             "registry": "caller-owned writable cache; never a shipped SDK registry"},
                  "validation": "PE dependency closure and isolated relocated factory queries; target media/device/GUI tests remain required",
                  "subset_policy_verified": True,
                  "redistribution_approved": False,
                  "license_scope": "Selected runtime source/license evidence; not a legal determination or approval for the complete SDK."}
        evidence = stage / "runtime/inspect"
        evidence.mkdir()
        for name, output in reports.items():
            (evidence / (name + ".txt")).write_text(output, encoding="utf-8")
        (stage / "runtime/manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if destination.exists() or destination.is_symlink():
            raise ValueError("Runtime destination appeared during preparation")
        stage.rename(destination)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    report = prepare_runtime(args.sdk, args.destination)
    print(json.dumps({"destination": str(args.destination), "files": len(report["files"]),
                      "plugins": len(report["plugins"]), "audio": report["preferred_audio_sink"]}, indent=2))


if __name__ == "__main__":
    main()
