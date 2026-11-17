"""Portable tests of the private Linux ELF closure and publication boundary."""
import json
import hashlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import linux_media_runtime as runtime


def elf_bytes(key):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    header[18:20] = (62).to_bytes(2, "little")
    return bytes(header) + key.encode()


class Tools:
    """readelf/patchelf contract fixture; no dependency or loader is simulated as passing."""
    def __init__(self):
        self.entries, self.paths, self.inspections = {}, {}, []
        self.bad_factory = False

    def __call__(self, command, env=None):
        command = [str(x) for x in command]
        if command[0] == "readelf":
            path = Path(command[-1])
            key = path.read_bytes()[64:].decode()
            needed, soname = self.entries[key]
            result = [f" 0x1 (NEEDED) Shared library: [{value}]" for value in needed]
            if soname: result.append(f" 0xe (SONAME) Library soname: [{soname}]")
            if str(path) in self.paths: result.append(f" 0x1d (RUNPATH) Library runpath: [{self.paths[str(path)]}]")
            return "\n".join(result)
        if command[0] == "patchelf":
            self.paths[command[-1]] = command[-2]
            return ""
        if command[0].endswith("gst-inspect-1.0"):
            self.inspections.append((command, env))
            plugin = Path(command[0]).parents[1] / "plugins/libgstcoreelements.so"
            if self.bad_factory and command[-1] == "queue": plugin = Path("/usr/lib/gstreamer-1.0/libgstcoreelements.so")
            return ("Plugin Details:\n  Name coreelements\n  Filename " + str(plugin) +
                    "\n  Version 1.28.9\n  License LGPL\n  Source module gstreamer\n\n  queue: Queue\n")
        raise AssertionError("Unexpected build command: " + repr(command))


class LinuxMediaRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="linux-media runtime ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.home = self.root / "sdk"
        (self.home / "lib").mkdir(parents=True)
        self.tools = Tools()

    def binary(self, relative, needed=(), soname=None):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        key = relative
        path.write_bytes(elf_bytes(key))
        self.tools.entries[key] = (needed, soname)
        return path

    def test_elf_parser_reads_soname_and_needed_rejects_foreign_machine_and_paths(self):
        path = self.binary("lib/libavformat.so.61", ["libavcodec.so.61", "libc.so.6"], "libavformat.so.61")
        info = runtime.elf_info(path, self.tools)
        self.assertEqual(info.soname, "libavformat.so.61")
        self.assertEqual(info.needed, {"libavcodec.so.61", "libc.so.6"})
        self.tools.entries["lib/libavformat.so.61"] = (["/usr/lib/libavcodec.so.61"], "libavformat.so.61")
        with self.assertRaisesRegex(ValueError, "basename"):
            runtime.elf_info(path, self.tools)
        value = bytearray(path.read_bytes()); value[18:20] = (183).to_bytes(2, "little"); path.write_bytes(value)
        with self.assertRaisesRegex(ValueError, "x86_64"):
            runtime.elf_info(path, self.tools)

    def test_parser_rejects_malformed_or_ambiguous_dynamic_entries(self):
        path = self.binary("lib/probe.so")
        for output in ("0x1 (NEEDED) no brackets", "0xe (SONAME) [a.so.1]\n0xe (SONAME) [b.so.1]",
                       "0x1d (RUNPATH) [/sdk]\n0xf (RPATH) [/system]"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                runtime.elf_info(path, lambda command: output)

    def test_closure_keeps_media_private_and_excludes_desktop_glib(self):
        root = self.binary("bin/probe", ["libgstreamer-1.0.so.0"])
        library = self.binary("lib/libgstreamer-1.0.so.0", ["libglib-2.0.so.0", "libc.so.6", "libmvec.so.1"], "libgstreamer-1.0.so.0")
        closure, system = runtime.dependency_closure(self.home, [root], self.tools)
        self.assertEqual({value[0] for value in closure.values()}, {root, library})
        self.assertEqual(system, {"libglib-2.0.so.0", "libc.so.6", "libmvec.so.1"})
        library.unlink()
        with self.assertRaisesRegex(ValueError, "system fallback forbidden"):
            runtime.dependency_closure(self.home, [root], self.tools,
                                       lambda *args: self.fail("must not search system GStreamer"))

    def test_closure_rejects_abi_mismatch_soname_mismatch_and_unknown_dependency(self):
        for dependency in ("libavcodec.so.58", "libx264.so.163", "libunknown.so.7"):
            with self.subTest(dependency=dependency):
                seed = self.binary("bin/probe", [dependency])
                with self.assertRaises(ValueError):
                    runtime.dependency_closure(self.home, [seed], self.tools)
        seed = self.binary("bin/probe", ["libavformat.so.61"])
        self.binary("lib/libavformat.so.61", [], "libavformat.so.60")
        with self.assertRaises(ValueError): runtime.dependency_closure(self.home, [seed], self.tools)

    def test_unused_sdk_libraries_are_not_selected_but_referenced_abis_stay_strict(self):
        seed = self.binary("bin/probe", ["libavformat.so.61"])
        library = self.binary("lib/libavformat.so.61", [], "libavformat.so.61")
        # FFmpeg installs avdevice even with --disable-devices. Its presence
        # does not make it an application dependency or an approved runtime ABI.
        for name in ("libavdevice.so.61", "libavcodec.so.58", "libx264.so.163"):
            self.binary("lib/" + name, [], name)
        closure, _ = runtime.dependency_closure(self.home, [seed], self.tools)
        self.assertEqual({item[0] for item in closure.values()}, {seed, library})
        for name in ("libavdevice.so.61", "libavcodec.so.58", "libx264.so.163"):
            with self.subTest(name=name):
                self.binary("bin/probe", [name])
                with self.assertRaises(ValueError):
                    runtime.dependency_closure(self.home, [seed], self.tools)
                with self.assertRaises(ValueError):
                    runtime.dependency_closure(self.home, [self.home / "lib" / name], self.tools)

    def test_orc_must_follow_the_private_simd_build_and_not_system_fallback(self):
        seed = self.binary("bin/probe", ["liborc-0.4.so.0"])
        with self.assertRaisesRegex(ValueError, "system fallback forbidden"):
            runtime.dependency_closure(self.home, [seed], self.tools,
                                       lambda *args: self.fail("private ORC cannot be substituted"))
        orc = self.binary("lib/liborc-0.4.so.0", ["libm.so.6"], "liborc-0.4.so.0")
        closure, _ = runtime.dependency_closure(self.home, [seed], self.tools)
        self.assertEqual(closure["liborc-0.4.so.0"][0], orc)

    def test_closure_reports_independent_unresolved_dependencies_together(self):
        first = self.binary("bin/first", ["libges-1.0.so.0"])
        second = self.binary("bin/second", ["libgstapp-1.0.so.0"])
        self.binary("lib/libgstapp-1.0.so.0", ["libunknown.so.7"], "libgstapp-1.0.so.0")
        with self.assertRaises(ValueError) as error:
            runtime.dependency_closure(self.home, [first, second], self.tools)
        message = str(error.exception)
        self.assertIn("libges-1.0.so.0", message)
        self.assertIn("system fallback forbidden", message)
        self.assertIn("libunknown.so.7", message)
        self.assertIn("Unreviewed non-SDK dependency", message)
        self.assertIn(str(first), message)
        self.assertIn(str(self.home / "lib/libgstapp-1.0.so.0"), message)

    def test_flac_32_bit_encoder_requires_the_private_abi_not_system_flac8(self):
        seed = self.binary("bin/probe", ["libFLAC.so.14"])
        with self.assertRaisesRegex(ValueError, "system fallback forbidden"):
            runtime.dependency_closure(self.home, [seed], self.tools,
                lambda *args: self.fail("FLAC must not resolve a system provider"))
        flac = self.binary("lib/libFLAC.so.14", ["libm.so.6"], "libFLAC.so.14")
        closure, _ = runtime.dependency_closure(self.home, [seed], self.tools)
        self.assertEqual(closure["libFLAC.so.14"][0], flac)
        self.binary("bin/probe", ["libFLAC.so.8"])
        self.binary("lib/libFLAC.so.8", [], "libFLAC.so.8")
        with self.assertRaisesRegex(ValueError, "Wrong private FLAC ABI"):
            runtime.dependency_closure(self.home, [seed], self.tools)

    def test_codec_provenance_checks_actual_dpkg_owner_hash_source_and_baseline(self):
        codec = self.root / "usr/lib/libvpx.so.7.0.0"
        codec.parent.mkdir(parents=True); codec.write_bytes(elf_bytes("vpx"))
        state = self.root / "pkg"
        (state / "info").mkdir(parents=True)
        (state / "doc/libvpx7").mkdir(parents=True)
        (state / "doc/libvpx7/copyright").write_text("BSD copyright and source text")
        (state / "os-release").write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
        expected_md5 = hashlib.md5(codec.read_bytes()).hexdigest()
        md5file = state / "info/libvpx7:amd64.md5sums"
        md5file.write_text(expected_md5 + "  " + str(codec).removeprefix("/") + "\n")
        owner = "libvpx7:amd64"
        def execute(command):
            if command[1] == "--search": return owner + ": " + command[2] + "\n"
            return "libvpx7:amd64\n1.11.0-2ubuntu2\nlibvpx\n1.11.0-2ubuntu2\namd64\n"
        def mapped_path(value):
            value = str(value)
            for prefix, target in (("/usr/share/doc", state / "doc"),
                                   ("/var/lib/dpkg/info", state / "info"),
                                   ("/etc/os-release", state / "os-release")):
                if value == prefix: return target
                if value.startswith(prefix + "/"): return target / value[len(prefix) + 1:]
            return Path(value)
        with patch.object(runtime, "Path", side_effect=mapped_path):
            provenance, texts = runtime.dpkg_provenance(codec, "libvpx.so.7", execute)
            self.assertEqual(provenance["installed_md5"], expected_md5)
            self.assertEqual(provenance["source_package"], "libvpx")
            self.assertEqual(texts, [state / "doc/libvpx7/copyright"])
            owner = "foreign-package:amd64"
            with self.assertRaisesRegex(ValueError, "dpkg owner"):
                runtime.dpkg_provenance(codec, "libvpx.so.7", execute)
            owner = "libvpx7:amd64"
            codec.write_bytes(b"locally replaced codec")
            with self.assertRaisesRegex(ValueError, "checksum"):
                runtime.dpkg_provenance(codec, "libvpx.so.7", execute)
            (state / "os-release").write_text("ID=debian\nVERSION_ID=12\n")
            with self.assertRaisesRegex(ValueError, "Ubuntu 22.04"):
                runtime.dpkg_provenance(codec, "libvpx.so.7", execute)

    def test_sdk_cannot_shadow_glib_or_follow_external_symlinks(self):
        for name in ("libglib-2.0.so.0", "libmvec.so.1"):
            with self.subTest(name=name):
                path = self.binary("lib/" + name, [], name)
                with self.assertRaisesRegex(ValueError, "system ABI"): runtime.sdk_index(self.home)
                path.unlink()
        external = self.root / "foreign.so.0"; external.write_bytes(elf_bytes("outside"))
        (self.home / "lib/libavformat.so.61").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "escapes"): runtime.sdk_index(self.home)

    def test_environment_removes_loader_and_sdk_contamination_keeps_desktop_session(self):
        inherited = {"PATH": "/old-sdk/bin", "LD_LIBRARY_PATH": "/old", "LD_PRELOAD": "bad.so",
                     "GST_PLUGIN_PATH": "/plugins", "GST_REGISTRY_UPDATE": "no",
                     "GST_PLUGIN_FEATURE_RANK": "x264enc:MAX", "GIO_EXTRA_MODULES": "/bad",
                     "GI_TYPELIB_PATH": "/bad", "GSETTINGS_SCHEMA_DIR": "/bad",
                     "DISPLAY": ":99", "DBUS_SESSION_BUS_ADDRESS": "unix:path=/session"}
        env = runtime.runtime_environment(self.root / "bundle", self.root / "registry", inherited)
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        self.assertEqual(env["LD_LIBRARY_PATH"], str(self.root / "bundle/runtime/lib"))
        self.assertEqual(env["DISPLAY"], ":99")
        for key in ("LD_PRELOAD", "GST_REGISTRY_UPDATE", "GST_PLUGIN_FEATURE_RANK", "GIO_EXTRA_MODULES", "GI_TYPELIB_PATH"):
            self.assertNotIn(key, env)
        with self.assertRaises(ValueError): runtime.runtime_environment(self.root, self.root / "registry", {})

    def sdk_fixture(self):
        self.binary("lib/libgstreamer-1.0.so.0", ["libglib-2.0.so.0"], "libgstreamer-1.0.so.0")
        self.binary("lib/libavformat.so.61", ["libc.so.6"], "libavformat.so.61")
        self.binary("lib/libgstnet-1.0.so.0", ["libc.so.6"], "libgstnet-1.0.so.0")
        self.binary("lib/libavdevice.so.61", ["libavformat.so.61"], "libavdevice.so.61")
        self.binary("lib/gstreamer-1.0/libgstcoreelements.so", ["libgstreamer-1.0.so.0"])
        self.binary("libexec/gstreamer-1.0/gst-plugin-scanner", ["libgstreamer-1.0.so.0"])
        self.binary("bin/gst-inspect-1.0", ["libgstreamer-1.0.so.0", "libgstnet-1.0.so.0"])
        license_file = self.home / "share/licenses/gstreamer/COPYING"
        license_file.parent.mkdir(parents=True); license_file.write_text("Test source license text\n")
        report = {"version": "1.28.9", "target": "linux-x86_64", "lock_sha256": "a" * 64,
                  "sources": [{"id": "gstreamer", "version": "1.28.9", "sha256": "b" * 64,
                               "url": "https://gstreamer.freedesktop.org/source.tar.xz",
                               "license_files": [license_file.relative_to(self.home).as_posix()]}],
                  "files": [{"path": p.relative_to(self.home).as_posix(), "sha256": runtime.sha256(p), "component": "gstreamer"}
                            for p in self.home.rglob("*") if p.is_file()]}
        module = SimpleNamespace(load_lock=lambda: {}, verify_sdk=lambda home, lock: report)
        self.enterContext(patch.dict(sys.modules, {"install_linux_gstreamer": module}))
        self.enterContext(patch.object(runtime, "ROOT_LIBRARIES", ("libgstreamer-1.0.so.0", "libavformat.so.61")))
        self.enterContext(patch.object(runtime, "PLUGIN_FACTORIES", {"coreelements": ("queue",)}))
        return report

    def test_payload_publication_relocates_checks_factories_and_excludes_inspector_only_dependencies(self):
        self.sdk_fixture()
        destination = self.root / "bundle"
        manifest = runtime.prepare_runtime(self.home, destination, execute=self.tools)
        self.assertTrue((destination / runtime.SCANNER).is_file())
        self.assertFalse((destination / runtime.INSPECTOR).exists())
        self.assertFalse((destination / runtime.LIB / "libgstnet-1.0.so.0").exists())
        self.assertFalse((destination / runtime.LIB / "libavdevice.so.61").exists())
        self.assertEqual(len(self.tools.inspections), 2)
        self.assertEqual(json.loads((destination / "runtime/manifest.json").read_text()), manifest)
        for entry in manifest["files"]:
            self.assertEqual(runtime.sha256(destination / entry["path"]), entry["sha256"])
            self.assertTrue(entry["runpath"].startswith("$ORIGIN"))
        with self.assertRaisesRegex(ValueError, "overwrite"):
            runtime.prepare_runtime(self.home, destination, execute=self.tools)

    def test_wrong_factory_origin_or_tampered_receipt_never_publishes_partial_payload(self):
        report = self.sdk_fixture()
        destination = self.root / "bundle"
        self.tools.bad_factory = True
        with self.assertRaisesRegex(ValueError, "plugin version/path"):
            runtime.prepare_runtime(self.home, destination, execute=self.tools)
        self.assertFalse(destination.exists())
        report["files"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "receipt hash"):
            runtime.prepare_runtime(self.home, destination, execute=self.tools)
        self.assertFalse(destination.exists())

    def test_sdk_receipt_resolves_internal_soname_symlinks_with_the_same_owner(self):
        report = self.sdk_fixture()
        target = self.home / "lib/libgstreamer-1.0.so.0"
        alias = self.home / "lib/libgstreamer-1.0.so"
        alias.symlink_to(target.name)
        entry = {"path": alias.relative_to(self.home).as_posix(), "symlink": target.name, "component": "gstreamer"}
        report["files"].append(entry)
        _, files = runtime._receipt_entries(self.home, report)
        self.assertIn(target, files)
        entry["component"] = "foreign"
        with self.assertRaisesRegex(ValueError, "symlink"):
            runtime._receipt_entries(self.home, report)


if __name__ == "__main__":
    unittest.main()
