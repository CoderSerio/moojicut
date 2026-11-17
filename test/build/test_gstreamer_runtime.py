"""PE dependency and private runtime packaging boundaries, without Windows loading."""

import copy
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import gstreamer_runtime as runtime
import install_gstreamer as sdk


PE_OFFSET = 0x80
OPTIONAL_OFFSET = PE_OFFSET + 24
DIRECTORY_OFFSET = OPTIONAL_OFFSET + 112
SECTION_OFFSET = OPTIONAL_OFFSET + 240
SECTION_RVA = 0x1000
SECTION_RAW = 0x200


def pe64(imports=(), delayed=()):
    """Small AMD64 PE32+ with mapped import descriptors, names and ordinal thunks."""
    if len(imports) > 15 or len(delayed) > 15:
        raise ValueError("fixture descriptor capacity exceeded")
    data = bytearray(0x1200)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, PE_OFFSET)
    data[PE_OFFSET:PE_OFFSET + 4] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, PE_OFFSET + 4,
                     0x8664, 1, 0, 0, 0, 240, 0x2022)
    struct.pack_into("<H", data, OPTIONAL_OFFSET, 0x20B)
    struct.pack_into("<Q", data, OPTIONAL_OFFSET + 24, 0x140000000)
    struct.pack_into("<II", data, OPTIONAL_OFFSET + 32, 0x1000, 0x200)
    struct.pack_into("<II", data, OPTIONAL_OFFSET + 56, 0x2000, 0x200)
    struct.pack_into("<H", data, OPTIONAL_OFFSET + 68, 3)
    struct.pack_into("<I", data, OPTIONAL_OFFSET + 108, 16)
    struct.pack_into("<8sIIIIIIHHI", data, SECTION_OFFSET,
                     b".rdata\0\0", 0x1000, SECTION_RVA, 0x1000,
                     SECTION_RAW, 0, 0, 0, 0, 0x40000040)
    next_name = 0x1400

    def name_rva(name):
        nonlocal next_name
        encoded = name.encode("ascii") + b"\0"
        if next_name + len(encoded) > 0x1800:
            raise ValueError("fixture name capacity exceeded")
        rva = next_name
        offset = SECTION_RAW + rva - SECTION_RVA
        data[offset:offset + len(encoded)] = encoded
        next_name += len(encoded)
        return rva

    if imports:
        struct.pack_into("<II", data, DIRECTORY_OFFSET + 8, 0x1000, (len(imports) + 1) * 20)
        for index, name in enumerate(imports):
            thunk = 0x1800 + index * 16
            struct.pack_into("<IIIII", data, SECTION_RAW + index * 20,
                             thunk, 0, 0, name_rva(name), thunk)
            struct.pack_into("<QQ", data, SECTION_RAW + thunk - SECTION_RVA,
                             0x8000000000000001, 0)
    if delayed:
        struct.pack_into("<II", data, DIRECTORY_OFFSET + 13 * 8,
                         0x1200, (len(delayed) + 1) * 32)
        for index, name in enumerate(delayed):
            thunk = 0x1900 + index * 16
            struct.pack_into("<IIIIIIII", data, SECTION_RAW + 0x200 + index * 32,
                             1, name_rva(name), 0, thunk, thunk, 0, 0, 0)
            struct.pack_into("<QQ", data, SECTION_RAW + thunk - SECTION_RVA,
                             0x8000000000000001, 0)
    return data


class GStreamerRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="gstreamer runtime test ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.home = self.root / "sdk"
        (self.home / "bin").mkdir(parents=True)

    def binary(self, relative, imports=(), delayed=(), data=None):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(pe64(imports, delayed) if data is None else data)
        return path

    def test_pe_imports_include_normal_and_delay_tables_case_insensitively(self):
        path = self.binary("bin/probe.exe", ["KERNEL32.dll", "LIBGSTREAMER-1.0-0.DLL"],
                           ["LibGStreamer-1.0-0.dll", "libges-1.0-0.dll"])
        self.assertEqual(runtime.pe_dependencies(path),
                         {"kernel32.dll", "libgstreamer-1.0-0.dll", "libges-1.0-0.dll"})
        self.assertEqual(runtime.pe_dependencies(self.binary("bin/empty.dll")), set())

    def test_pe_rejects_wrong_format_machine_and_truncated_headers(self):
        valid = pe64(["kernel32.dll"])
        invalid = [b"", b"MZ", valid[:PE_OFFSET + 4], valid[:OPTIONAL_OFFSET + 100],
                   valid[:SECTION_OFFSET + 20], valid[:SECTION_RAW + 5]]
        for offset, format_string, value in ((0x3C, "<I", 0xFFFFFF00),
                                             (PE_OFFSET + 4, "<H", 0x14C),
                                             (OPTIONAL_OFFSET, "<H", 0x10B),
                                             (PE_OFFSET + 20, "<H", 24)):
            data = bytearray(valid)
            struct.pack_into(format_string, data, offset, value)
            invalid.append(data)
        for index, data in enumerate(invalid):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    runtime.pe_dependencies(self.binary("bin/invalid.dll", data=data))

    def test_pe_rejects_unmapped_or_virtual_only_import_rvas(self):
        cases = []
        for directory in (1, 13):
            data = pe64(["kernel32.dll"], ["user32.dll"])
            struct.pack_into("<II", data, DIRECTORY_OFFSET + directory * 8, 0x7FFF0000, 64)
            cases.append(data)
        for name_offset in (SECTION_RAW + 12, SECTION_RAW + 0x200 + 4):
            data = pe64(["kernel32.dll"], ["user32.dll"])
            # A virtual section tail is not backed by bytes in the input file.
            struct.pack_into("<I", data, SECTION_OFFSET + 8, 0x2000)
            struct.pack_into("<I", data, name_offset, 0x2000)
            cases.append(data)
        for index, data in enumerate(cases):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    runtime.pe_dependencies(self.binary("bin/invalid.dll", data=data))

    def test_pe_requires_terminated_names_and_bounded_descriptor_tables(self):
        cases = []
        data = pe64(["kernel32.dll"])
        data[SECTION_RAW + 0x400:] = b"A" * (len(data) - SECTION_RAW - 0x400)
        cases.append(data)
        for directory, size in ((1, 20), (13, 32)):
            data = pe64(["kernel32.dll"], ["user32.dll"])
            struct.pack_into("<I", data, DIRECTORY_OFFSET + directory * 8 + 4, size)
            cases.append(data)
        for index, data in enumerate(cases):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    runtime.pe_dependencies(self.binary("bin/invalid.dll", data=data))

    def test_closure_follows_delay_imports_and_skips_only_explicit_system_dlls(self):
        probe = self.binary("bin/probe.exe", ["KERNEL32.dll", "USER32.dll", "api-ms-win-core-file-l1-1-0.dll"],
                            ["libgstreamer-1.0-0.dll"])
        dependency = self.binary("bin/libgstreamer-1.0-0.dll", ["libglib-2.0-0.dll"])
        leaf = self.binary("bin/libglib-2.0-0.dll", ["kernel32.dll"])
        unused = self.binary("bin/unused.dll", data=b"must never be parsed or copied")
        closure = runtime.dependency_closure(self.home, [probe])
        self.assertEqual(closure, {path.name.lower(): path for path in (probe, dependency, leaf)})
        self.assertNotIn(unused.name, closure)

    def test_closure_rejects_missing_dependency_and_non_x64_transitive_library(self):
        probe = self.binary("bin/probe.exe", ["libgstreamer-1.0-0.dll"])
        with self.assertRaises(ValueError):
            runtime.dependency_closure(self.home, [probe])
        dependency = pe64()
        struct.pack_into("<H", dependency, PE_OFFSET + 4, 0x14C)
        self.binary("bin/libgstreamer-1.0-0.dll", data=dependency)
        with self.assertRaises(ValueError):
            runtime.dependency_closure(self.home, [probe])

    def test_closure_reports_every_reachable_missing_dependency_in_one_failure(self):
        probe = self.binary("bin/probe.exe", ["missing-one.dll", "present.dll"], ["missing-two.dll"])
        self.binary("bin/present.dll", ["missing-three.dll"])
        with self.assertRaises(ValueError) as raised:
            runtime.dependency_closure(self.home, [probe])
        for name in ("missing-one.dll", "missing-two.dll", "missing-three.dll"):
            self.assertIn(name, str(raised.exception))

    def redist(self):
        vc = self.root / "Visual Studio/VC"
        tools = vc / "Tools/MSVC/14.44.35207"
        tools.mkdir(parents=True)
        marker = vc / "Auxiliary/Build/Microsoft.VCRedistVersion.default.txt"
        marker.parent.mkdir(parents=True)
        marker.write_text("14.44.35211\n", encoding="utf-8")
        directory = vc / "Redist/MSVC/14.44.35211/x64/Microsoft.VC143.CRT"
        directory.mkdir(parents=True)
        (directory / "vcruntime140.dll").write_bytes(pe64(["kernel32.dll", "api-ms-win-crt-runtime-l1-1-0.dll"]))
        (directory / "msvcp140.dll").write_bytes(pe64(["vcruntime140.dll"]))
        (directory / "concrt140.dll").write_bytes(pe64(["kernel32.dll"]))
        # A newer unselected version must not override the official default.
        (vc / "Redist/MSVC/14.99.99999/x64/Microsoft.VC143.CRT").mkdir(parents=True)
        # Windows os.environ normalizes keys to uppercase. A plain dict copy
        # must retain case-insensitive lookup for the active toolchain.
        environment = {"VCTOOLSINSTALLDIR": str(tools), "SYSTEMROOT": "D:/Windows", "PATH": "untrusted"}
        return directory, environment

    def signed_crt(self, command, **kwargs):
        self.assertEqual(Path(command[0]).name, "powershell.exe")
        self.assertEqual(Path(command[0]), Path("D:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"))
        self.assertEqual(command[1:4], ["-NoProfile", "-NonInteractive", "-Command"])
        source = Path(kwargs["env"]["MOOJICUT_CRT_FILE"])
        self.assertEqual(source.parent.name, "Microsoft.VC143.CRT")
        self.assertEqual(source.parent.parent.name, "x64")
        return json.dumps({"status": "Valid", "signer": "CN=Microsoft Corporation, O=Microsoft Corporation, C=US",
                           "thumbprint": "0123456789ABCDEF", "company": "Microsoft Corporation", "version": "14.44.35211.0"})

    def test_redist_uses_only_signed_versioned_x64_toolchain_files_and_rejects_tampering(self):
        directory, environment = self.redist()
        package = sdk.load_lock()
        provider = runtime.MSVCRedist(package, self.signed_crt, environment)
        probe = self.binary("bin/probe.exe", ["msvcp140.dll"])
        result = runtime.dependency_closure(self.home, [probe], provider)
        self.assertEqual(set(result), {"probe.exe", "msvcp140.dll", "vcruntime140.dll"})
        self.assertEqual(result["vcruntime140.dll"], directory / "vcruntime140.dll")
        self.assertNotIn("concrt140.dll", provider.records)
        self.assertEqual(provider.records["msvcp140.dll"]["sha256"], sdk.digest(directory / "msvcp140.dll"))
        self.assertFalse(runtime._system("vcruntime140.dll"))
        with self.assertRaisesRegex(ValueError, "VCToolsInstallDir"):
            runtime.dependency_closure(self.home, [probe], runtime.MSVCRedist(package, self.signed_crt, {"PATH": str(directory)}))
        for changed in ({"status": "HashMismatch"}, {"signer": "CN=Other Company"},
                        {"version": "14.30.10000.0"}, {"company": "Other Company"}):
            def inspect(command, **kwargs):
                return json.dumps(dict(json.loads(self.signed_crt(command, **kwargs)), **changed))
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "Unverified/outdated"):
                runtime.dependency_closure(self.home, [probe], runtime.MSVCRedist(package, inspect, environment))
        outside = self.root / "vcruntime140.dll"
        outside.write_bytes(pe64())
        (directory / "vcruntime140.dll").unlink()
        (directory / "vcruntime140.dll").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Missing official VS"):
            runtime.dependency_closure(self.home, [probe], runtime.MSVCRedist(package, self.signed_crt, environment))
    def test_closure_rejects_case_collisions_and_external_dependency_resolution(self):
        probe = self.binary("bin/probe.exe", ["libglib-2.0-0.dll"])
        library = self.binary("bin/libglib-2.0-0.dll")
        # Simulate directory entries from a case-sensitive SDK volume, even on
        # the default case-insensitive macOS filesystem used for these tests.
        upper = library.with_name(library.name.upper())
        original = Path.iterdir
        def entries(path):
            if path == self.home / "bin":
                return iter([probe, library, upper])
            return original(path)
        with patch.object(Path, "iterdir", entries):
            with self.assertRaises(ValueError):
                runtime.dependency_closure(self.home, [probe])
        library.unlink()
        outside = self.root / "libglib-2.0-0.dll"
        outside.write_bytes(pe64())
        library.symlink_to(outside)
        with self.assertRaises(ValueError):
            runtime.dependency_closure(self.home, [probe])

    def test_closure_never_resolves_an_import_by_searching_other_plugin_directories(self):
        plugin = self.binary("lib/gstreamer-1.0/gstcoreelements.dll", ["gstunexpected.dll"])
        self.binary("lib/gstreamer-1.0/gstunexpected.dll")
        with self.assertRaises(ValueError):
            runtime.dependency_closure(self.home, [plugin])
        # A plausible Windows-looking name must not bypass the exact allowlist.
        probe = self.binary("bin/probe.exe", ["kernel32-extra.dll"])
        with self.assertRaises(ValueError):
            runtime.dependency_closure(self.home, [probe])

    def test_runtime_environment_cannot_discover_machine_plugins_or_sdk_dlls(self):
        bundle = self.root / "app"
        registry = self.root / "cache/registry.bin"
        inherited = {"PATH": "machine-untrusted", "SYSTEMROOT": "D:/Windows",
                     "GST_PLUGIN_PATH": "external-plugin", "GST_PLUGIN_PATH_1_0": "external-1",
                     "GST_PLUGIN_SYSTEM_PATH_1_0": "machine-plugin", "GST_PLUGIN_SCANNER": "foreign-scanner",
                     "GST_PLUGIN_FEATURE_RANK": "x264enc:999", "GST_REGISTRY": "foreign-registry",
                     "GSTREAMER_ROOT_X86_64": "external-sdk"}
        original = dict(inherited)
        environment = runtime.runtime_environment(bundle, registry, inherited)
        self.assertEqual(inherited, original)
        self.assertNotIn("machine-untrusted", environment["PATH"])
        self.assertEqual(environment["PATH"], os.pathsep.join(map(str,
            (bundle, Path("D:/Windows/System32"), Path("D:/Windows")))))
        self.assertNotIn("GST_PLUGIN_PATH", environment)
        self.assertNotIn("GST_PLUGIN_FEATURE_RANK", environment)
        self.assertNotIn("GST_PLUGIN_SCANNER", environment)
        self.assertNotIn("GST_REGISTRY", environment)
        self.assertNotIn("GSTREAMER_ROOT_X86_64", environment)
        self.assertEqual(environment["GST_PLUGIN_PATH_1_0"], "")
        self.assertEqual(environment["GST_PLUGIN_SYSTEM_PATH_1_0"],
                         str(bundle.resolve() / "runtime/gstreamer/plugins"))
        self.assertEqual(environment["GST_PLUGIN_SCANNER_1_0"],
                         str(bundle.resolve() / "gst-plugin-scanner.exe"))
        self.assertEqual(environment["GST_REGISTRY_1_0"], str(registry.resolve()))

    def test_closure_rejects_disallowed_codecs_even_when_present_in_private_sdk(self):
        for name in ("libx264-164.dll", "libfdk-aac-2.dll", "libvo-aacenc-0.dll"):
            with self.subTest(name=name):
                self.binary("bin/" + name)
                probe = self.binary("bin/probe.exe", delayed=[name])
                with self.assertRaisesRegex(ValueError, "Disallowed"):
                    runtime.dependency_closure(self.home, [probe])

    def fixture_sdk(self):
        """Real PE files plus recorded inspector text; nothing is executed here."""
        package = copy.deepcopy(sdk.load_lock())
        self.plugin_factories = dict(runtime.PLUGIN_FACTORIES)
        self.plugin_factories["wasapi2"] = ("wasapi2sink",)
        self.modules = {name: "gst-plugins-base" for name in self.plugin_factories}
        self.modules.update(coreelements="gstreamer", ges="gst-editing-services",
                            nle="gst-editing-services", libav="gst-libav")
        for name in ("videocrop", "videofilter", "audiofx", "isomp4", "audioparsers",
                     "matroska", "vpx", "flac", "autodetect"):
            self.modules[name] = "gst-plugins-good"
        for name in ("soundtouch", "videoparsersbad", "openh264", "wasapi2"):
            self.modules[name] = "gst-plugins-bad"
        for name in runtime.ROOT_DLLS:
            imports = ["KERNEL32.dll"]
            if name == "glib-2.0-0.dll":
                imports.append("intl-8.dll")
            self.binary("bin/" + name, imports)
        self.binary("bin/intl-8.dll", ["KERNEL32.dll"])
        for name in self.plugin_factories:
            imports = ["gstreamer-1.0-0.dll"]
            if name == "soundtouch":
                imports.append("libSoundTouch.dll")
            elif name == "openh264":
                imports.append("openh264-2.6.0.dll")
            self.binary("lib/gstreamer-1.0/gst" + name + ".dll", imports)
        self.binary("bin/libSoundTouch.dll", ["KERNEL32.dll"])
        self.binary("bin/openh264-2.6.0.dll", ["KERNEL32.dll"])
        self.binary("bin/inspector-only.dll", ["KERNEL32.dll"])
        self.binary("bin/" + runtime.INSPECTOR, ["glib-2.0-0.dll", "inspector-only.dll"])
        self.binary("libexec/gstreamer-1.0/" + runtime.SCANNER, ["glib-2.0-0.dll"])
        self.binary("lib/gstreamer-1.0/gstx264.dll", data=b"unselected GPL plugin must never load")
        self.binary("bin/unused-broken.dll", data=b"unreferenced SDK content must never load")
        self.binary("bin/ffmpeg.exe", data=b"developer command line must never ship")
        components = ("gstreamer-1.0", "gst-editing-services-1.0", "gst-plugins-base-1.0",
                      "gst-plugins-good-1.0", "gst-plugins-bad-1.0", "gst-libav-1.0",
                      "glib", "ffmpeg", "soundtouch", "openh264", "proxy-libintl")
        licenses = []
        for component in components:
            path = self.home / "share/licenses" / component / "COPYING"
            path.parent.mkdir(parents=True)
            path.write_text("Fixture license text for " + component, encoding="utf-8")
            licenses.append({"path": path.relative_to(self.home).as_posix(), "sha256": sdk.digest(path)})
        carrier = self.home / runtime.SHARED_GSTREAMER_LICENSE
        carrier.write_text("Fixture for the exact shared LGPL-2.0-or-later text", encoding="utf-8")
        licenses.append({"path": runtime.SHARED_GSTREAMER_LICENSE, "sha256": sdk.digest(carrier)})
        probe = "libav ABI 61 61 59; mov demux/mp4 mux available\n"
        probe += "\n".join(name + " license: LGPL version 2.1 or later"
                           for name in ("libavformat", "libavcodec", "libavutil"))
        probe += "\nlibavformat configuration: --disable-nonfree --disable-programs --disable-network\n"
        verified = {"schema_version": 1, "version": package["version"],
                    "archive_sha256": package["sha256"], "compiler": "MSVC x64",
                    "probe": probe, "licenses": licenses}
        (self.home / sdk.REPORT).write_text(json.dumps(verified), encoding="utf-8")
        self.package = package
        self.calls = []
        self.stage_roots = set()
        return package

    def inspect(self, command, **kwargs):
        self.calls.append((command, kwargs))
        executable, query = Path(command[0]), command[1]
        stage = executable.parent
        self.stage_roots.add(stage)
        self.assertEqual(executable.name, runtime.INSPECTOR)
        self.assertNotEqual(stage, self.home / "bin")
        self.assertTrue(executable.is_file())
        environment = kwargs["env"]
        self.assertEqual(environment["GST_PLUGIN_SYSTEM_PATH_1_0"], str(stage / runtime.PLUGIN_DIR))
        self.assertEqual(environment["GST_PLUGIN_SCANNER_1_0"], str(stage / runtime.SCANNER))
        self.assertEqual(environment["GST_PLUGIN_PATH_1_0"], "")
        self.assertNotIn(str(self.home), environment["PATH"])
        self.assertNotIn("machine-untrusted", environment["PATH"])
        self.assertTrue((stage / runtime.SCANNER).is_file())
        self.assertFalse(Path(environment["GST_REGISTRY_1_0"]).is_relative_to(stage))
        if query == "--version":
            return "GStreamer " + self.package["version"] + "\n"
        if isinstance(query, Path):
            self.assertTrue(query.is_file())
            self.assertEqual(query.parent, stage / runtime.PLUGIN_DIR)
            plugin = query.stem.removeprefix("gst")
        else:
            candidates = [name for name, factories in self.plugin_factories.items() if query in factories]
            self.assertEqual(len(candidates), 1, "only bounded declared factory queries are allowed")
            plugin = candidates[0]
        filename = stage / runtime.PLUGIN_DIR / ("gst" + plugin + ".dll")
        version = self.package.get("component_versions", {}).get(self.modules[plugin], self.package["version"])
        return ("Plugin Details:\n  Name " + plugin + "\n  Filename " + str(filename) +
                "\n  Version " + version + "\n  License LGPL\n  Source module " +
                self.modules[plugin] + "\n")

    def test_packaging_copies_only_closure_beside_exe_and_checks_actual_factories(self):
        package = self.fixture_sdk()
        destination = self.root / "app"
        with patch.dict("os.environ", {"PATH": "machine-untrusted", "GST_PLUGIN_PATH": "foreign"}):
            report = runtime.prepare_runtime(self.home, destination, package, execute=self.inspect)
        self.assertTrue(self.calls)
        self.assertEqual(set(report["plugins"]), set(self.plugin_factories))
        self.assertEqual(report["plugins"]["nle"]["Version"], "1.28.8.1")
        self.assertEqual(report["plugins"]["ges"]["Version"], "1.28.8.1")
        self.assertEqual(report["plugins"]["soundtouch"]["Version"], "1.28.8.1")
        self.assertEqual(set(report["factories"]),
                         {factory for factories in self.plugin_factories.values() for factory in factories})
        self.assertFalse(report["redistribution_approved"])
        for name in runtime.ROOT_DLLS:
            self.assertTrue((destination / name).is_file(), name)
        self.assertTrue((destination / runtime.SCANNER).is_file())
        self.assertTrue((destination / "libSoundTouch.dll").is_file())
        self.assertTrue((destination / "openh264-2.6.0.dll").is_file())
        for forbidden in (runtime.INSPECTOR, "inspector-only.dll", "unused-broken.dll", "ffmpeg.exe"):
            self.assertFalse((destination / forbidden).exists(), forbidden)
        expected_plugins = {"gst" + name + ".dll" for name in self.plugin_factories}
        self.assertEqual({p.name for p in (destination / runtime.PLUGIN_DIR).iterdir()}, expected_plugins)
        self.assertFalse(list(destination.rglob("registry*.bin")))
        self.assertFalse((destination / "bin").exists())
        self.assertEqual(json.loads((destination / "runtime/manifest.json").read_text()), report)
        for record in report["files"]:
            target = destination / record["path"]
            self.assertEqual(sdk.digest(target), record["sha256"])
            self.assertEqual(target.read_bytes(), (self.home / record["sdk_path"]).read_bytes())
        for component in ("soundtouch", "openh264", "ffmpeg", "glib", "proxy-libintl"):
            self.assertIn(component, report["licenses"])
        self.assertEqual(next(item for item in report["files"] if item["path"] == "intl-8.dll")["component"], "proxy-libintl")
        for stage in self.stage_roots:
            self.assertNotIn(str(stage), json.dumps(report))
            self.assertFalse(stage.exists())
        self.assertEqual(list(self.root.glob(".gstreamer-runtime-*")), [])

    def test_packaging_includes_only_reachable_crt_with_signature_and_source_evidence(self):
        package = self.fixture_sdk()
        directory, environment = self.redist()
        self.binary("bin/glib-2.0-0.dll", ["msvcp140.dll", "intl-8.dll"])
        def execute(command, **kwargs):
            if Path(command[0]).name == "powershell.exe":
                return self.signed_crt(command, **kwargs)
            return self.inspect(command, **kwargs)
        destination = self.root / "app"
        with patch.dict("os.environ", environment):
            report = runtime.prepare_runtime(self.home, destination, package, execute=execute)
        for name in ("msvcp140.dll", "vcruntime140.dll"):
            record = next(item for item in report["files"] if item["path"] == name)
            self.assertEqual(record["component"], runtime.CRT_COMPONENT)
            self.assertEqual(record["origin"], "visual-studio-redist")
            self.assertEqual(record["source_path"], str(directory / name))
            self.assertEqual(record["sha256"], sdk.digest(destination / name))
            self.assertEqual(record["status"], "Valid")
            self.assertEqual(record["version"], "14.44.35211.0")
            self.assertNotIn("sdk_path", record)
        self.assertFalse((destination / "concrt140.dll").exists())
        license_record = report["licenses"][runtime.CRT_COMPONENT]
        self.assertEqual(license_record["redistribution_list"], package["msvc_redist"]["redistribution_list"])
        notice = destination / license_record["files"][0]["path"]
        self.assertEqual(sdk.digest(notice), license_record["files"][0]["sha256"])
        self.assertEqual(set(json.loads(notice.read_text())["files"]), {"msvcp140.dll", "vcruntime140.dll"})

    def test_crt_changed_after_verification_is_never_published(self):
        package = self.fixture_sdk()
        directory, environment = self.redist()
        self.binary("bin/glib-2.0-0.dll", ["vcruntime140.dll"])
        def execute(command, **kwargs):
            if Path(command[0]).name == "powershell.exe":
                return self.signed_crt(command, **kwargs)
            return self.inspect(command, **kwargs)
        original = runtime.shutil.copy2
        def copy(source, target):
            result = original(source, target)
            if Path(source).parent == directory:
                Path(target).write_bytes(b"changed while copying")
            return result
        destination = self.root / "app"
        with patch.dict("os.environ", environment), patch.object(runtime.shutil, "copy2", copy):
            with self.assertRaisesRegex(ValueError, "CRT changed"):
                runtime.prepare_runtime(self.home, destination, package, execute=execute)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob(".gstreamer-runtime-*")), [])

    def test_runtime_reports_all_missing_license_sources_in_one_failure(self):
        package = self.fixture_sdk()
        for component in ("soundtouch", "openh264"):
            path = self.home / "share/licenses" / component
            (path / "COPYING").unlink()
            path.rmdir()
        destination = self.root / "app"
        with self.assertRaises(ValueError) as raised:
            runtime.prepare_runtime(self.home, destination, package, execute=self.inspect)
        self.assertIn("soundtouch", str(raised.exception))
        self.assertIn("openh264", str(raised.exception))
        self.assertFalse(destination.exists())

    def test_sdk_plugin_license_omissions_use_exact_verified_text_without_changing_source_ownership(self):
        package = self.fixture_sdk()
        for component in ("gst-plugins-good-1.0", "gst-libav-1.0"):
            directory = self.home / "share/licenses" / component
            (directory / "COPYING").unlink()
            directory.rmdir()
        carrier = self.home / runtime.SHARED_GSTREAMER_LICENSE
        original = carrier.read_bytes()
        carrier.write_bytes(b"changed after verification")
        destination = self.root / "app"
        with self.assertRaisesRegex(ValueError, "license inventory changed"):
            runtime.prepare_runtime(self.home, destination, package, execute=self.inspect)
        self.assertFalse(destination.exists())
        carrier.write_bytes(original)
        report = runtime.prepare_runtime(self.home, destination, package, execute=self.inspect)
        for component in ("gst-plugins-good-1.0", "gst-libav-1.0"):
            license_record = report["licenses"][component]
            self.assertEqual(license_record["license_source"], runtime.SHARED_GSTREAMER_LICENSE)
            self.assertEqual(len(license_record["files"]), 1)
            self.assertTrue(license_record["recipe"].endswith("/" + component + ".recipe"))
        self.assertEqual(next(item for item in report["files"] if item["path"].endswith("gstlibav.dll"))["component"], "gst-libav-1.0")

    def test_actual_cerbero_meson_configuration_is_accepted_with_lgpl_runtime_evidence(self):
        package = self.fixture_sdk()
        report_path = self.home / sdk.REPORT
        verified = json.loads(report_path.read_text())
        verified["probe"] = verified["probe"].replace(
            "--disable-nonfree --disable-programs --disable-network",
            "-Ddebug=true -Dprograms=disabled -Dprotocols=disabled -Dnetwork=disabled "
            "-Dnonfree=disabled -Dversion3=disabled -Dprefix=C:/projects/repos/cerbero.git/1.28/build/dist/msvc_x86_64")
        report_path.write_text(json.dumps(verified), encoding="utf-8")
        report = runtime.prepare_runtime(self.home, self.root / "app", package, execute=self.inspect)
        self.assertIn("-Dnonfree=disabled", report["sdk_probe"])

    def test_packaging_rejects_missing_or_changed_license_and_cleans_own_staging(self):
        package = self.fixture_sdk()
        license_file = self.home / "share/licenses/soundtouch/COPYING"
        original = license_file.read_bytes()
        for tampered in (b"changed after SDK verification", None):
            with self.subTest(tampered=tampered):
                if tampered is None:
                    license_file.unlink()
                else:
                    license_file.write_bytes(tampered)
                destination = self.root / "app"
                with self.assertRaisesRegex(ValueError, "license"):
                    runtime.prepare_runtime(self.home, destination, package, execute=self.inspect)
                self.assertFalse(destination.exists())
                self.assertEqual(list(self.root.glob(".gstreamer-runtime-*")), [])
                license_file.write_bytes(original)
        self.assertTrue((self.home / "bin/gstreamer-1.0-0.dll").is_file())

    def test_packaging_refuses_external_factory_or_failed_inspection_without_publication(self):
        package = self.fixture_sdk()
        for fail in ("external", "execution", "gpl-plugin"):
            with self.subTest(fail=fail):
                def execute(command, **kwargs):
                    text = self.inspect(command, **kwargs)
                    if command[1] == "pitch":
                        if fail == "execution":
                            raise RuntimeError("required pitch factory unavailable")
                        if fail == "gpl-plugin":
                            return text.replace("License LGPL", "License GPL")
                        plugin = Path(command[0]).parent / runtime.PLUGIN_DIR / "gstsoundtouch.dll"
                        text = text.replace(str(plugin), str(self.home / "lib/gstreamer-1.0/gstsoundtouch.dll"))
                    return text
                destination = self.root / "app"
                with self.assertRaises((ValueError, RuntimeError)):
                    runtime.prepare_runtime(self.home, destination, package, execute=execute)
                self.assertFalse(destination.exists())
                self.assertEqual(list(self.root.glob(".gstreamer-runtime-*")), [])

    def test_packaging_rejects_unverified_libav_license_or_nonfree_build_before_execution(self):
        package = self.fixture_sdk()
        report_path = self.home / sdk.REPORT
        verified = json.loads(report_path.read_text())
        invalid_probes = (
            verified["probe"].replace("libavcodec license: LGPL version 2.1 or later",
                                      "libavcodec license: GPL version 2 or later"),
            verified["probe"].replace("--disable-nonfree", "--enable-nonfree"),
            verified["probe"].replace("--disable-nonfree", "--disable-nonfree --enable-gpl"),
            verified["probe"].replace("--disable-nonfree", "-Dnonfree=enabled -Dversion3=disabled"),
            verified["probe"].replace("--disable-nonfree", "-Dnonfree=disabled -Dversion3=enabled"),
            verified["probe"].replace("--disable-nonfree", "-Dnonfree=disabled -Dversion3=disabled -Dgpl=enabled"),
            verified["probe"].replace("--disable-nonfree", "-Dnonfree=disabled -Dversion3=disabled -Dnonfree=enabled"),
            verified["probe"].replace("--disable-nonfree", "-Dprefix=contains--disable-nonfree"),
        )
        for index, probe in enumerate(invalid_probes):
            with self.subTest(index=index):
                modified = dict(verified, probe=probe)
                report_path.write_text(json.dumps(modified), encoding="utf-8")
                with self.assertRaises(ValueError):
                    runtime.prepare_runtime(self.home, self.root / "app", package, execute=self.inspect)
                self.assertEqual(self.calls, [])
                self.assertFalse((self.root / "app").exists())

    def test_existing_or_racing_destination_is_never_overwritten_or_cleaned(self):
        package = self.fixture_sdk()
        existing = self.root / "existing"
        existing.mkdir()
        sentinel = existing / "user.txt"
        sentinel.write_bytes(b"user-owned")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            runtime.prepare_runtime(self.home, existing, package, execute=self.inspect)
        self.assertEqual(self.calls, [])
        self.assertEqual(sentinel.read_bytes(), b"user-owned")
        racing = self.root / "racing"
        def execute(command, **kwargs):
            text = self.inspect(command, **kwargs)
            if not racing.exists():
                racing.mkdir()
                (racing / "user.txt").write_bytes(b"appeared while querying")
            return text
        with self.assertRaisesRegex(ValueError, "appeared"):
            runtime.prepare_runtime(self.home, racing, package, execute=execute)
        self.assertEqual((racing / "user.txt").read_bytes(), b"appeared while querying")
        self.assertEqual(list(self.root.glob(".gstreamer-runtime-*")), [])


if __name__ == "__main__":
    unittest.main()
