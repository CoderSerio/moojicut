"""Resolve explicitly listed, statically linked built-ins for native builds.

This is a build manifest, not a runtime plugin loader or a public plugin ABI.
Imported user code is never discovered or compiled by these helpers. Native
headers remain internal; the MoonBit library is built separately from moon.mod.
"""

import argparse
import json
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "build/native-modules.json"
SUFFIXES = {"macos": {".m", ".c", ".swift"}, "windows": {".c", ".cpp"}, "linux": {".c"}}
COMPILE_SUFFIXES = {".c", ".cpp", ".m", ".mm", ".swift"}
SHARED_PREFIXES = {
    "shared.editor_host": "platform/shared/app/",
    "shared.bindings": "bindings/c/",
    "shared.icons": "components/icons/shared/",
    "shared.media": "platform/shared/media/",
    "shared.media_engine": "platform/shared/media/",
    "shared.image": "platform/shared/image/",
    "shared.graphics": "platform/shared/graphics/",
    "shared.storage": "platform/shared/storage/",
    "shared.plugin_host.worker": "platform/shared/plugin_host/",
    "shared.plugin_host.package": "platform/shared/plugin_host/",
    "shared.plugin_host.storage": "platform/shared/plugin_host/",
    "shared.plugin_host.protocol": "platform/shared/plugin_host/",
    "shared.plugin_host.process": "platform/shared/plugin_host/",
    "shared.plugin_host.posix": "platform/shared/plugin_host/",
}


def module_registry(manifest, platform):
    shared = manifest.get("shared", {})
    platform_modules = manifest["platforms"][platform]
    if shared.keys() & platform_modules.keys():
        raise ValueError("Shared and platform module identities must be distinct")
    return dict(shared, **platform_modules)


def module_prefix(name, platform):
    if name in SHARED_PREFIXES:
        return SHARED_PREFIXES[name]
    if name.startswith("tool.") and platform == "macos":
        return "native/tools/"
    if name == "host" or name.startswith("system."):
        return "native/" + platform + "/"
    kind, separator, feature = name.partition(".")
    if not separator or kind not in ("feature", "component", "platform"):
        raise ValueError("Invalid module name: " + name)
    return ("platform/" + platform + "/" + feature + "/" if kind == "platform" else
            ("plugins/feature/" if kind == "feature" else "components/") + feature + "/" + platform + "/")


def resolve_sources(root, manifest, platform, modules=("host",)):
    """Validate ownership/dependencies, then return the requested dependency closure."""
    root = Path(root).resolve()
    if manifest.get("schema_version") != 1 or platform not in SUFFIXES:
        raise ValueError("Unsupported native module schema or platform.")
    registry = module_registry(manifest, platform)
    owners = {}
    for name, module in registry.items():
        if len(set(module["requires"])) != len(module["requires"]):
            raise ValueError("Duplicate dependency in " + name)
        for dependency in module["requires"] + module.get("includes", []):
            if dependency not in registry:
                raise ValueError("Unknown dependency: " + dependency)
        for source in module["sources"] + module.get("files", []):
            path = PurePosixPath(source)
            if path.is_absolute() or ".." in path.parts or "\\" in source:
                raise ValueError("Source must be a repository-relative path: " + source)
            prefix = module_prefix(name, platform)
            if source in module.get("files", []) and path.suffix in COMPILE_SUFFIXES:
                raise ValueError("Compilation unit must be listed in sources, not files: " + source)
            if not source.startswith(prefix) or (source in module["sources"] and path.suffix not in SUFFIXES[platform]):
                raise ValueError("Source is outside its module: " + source)
            resolved = (root / source).resolve()
            if not resolved.is_relative_to(root) or not resolved.is_file():
                raise ValueError("Missing or external native source: " + source)
            if resolved in owners:
                raise ValueError("Native source is listed more than once: " + source)
            owners[resolved] = name

    # Validate even unrequested modules, so a broken entry cannot lurk until a
    # different fixture or host happens to use it.
    visited, active = set(), set()

    def visit(name, ordered):
        if name not in registry:
            raise ValueError("Unknown native module: " + name)
        if name in active:
            raise ValueError("Native module dependency cycle at " + name)
        if name in visited:
            return
        active.add(name)
        for dependency in registry[name]["requires"]:
            visit(dependency, ordered)
        active.remove(name)
        visited.add(name)
        ordered.extend(root / source for source in registry[name]["sources"])

    for name in registry:
        visit(name, [])
    visited.clear()
    sources = []
    for name in modules:
        visit(name, sources)
    return sources


def native_sources(platform, *modules):
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    # Import lazily: the standalone checker also uses this module's resolver.
    from check_native_boundaries import check_native_boundaries
    errors = check_native_boundaries(ROOT, manifest)
    if errors:
        raise ValueError("\n".join(errors))
    return resolve_sources(ROOT, manifest, platform, modules or ("host",))


def object_path(directory, source):
    """Keep full source paths: different modules may both have selection.c."""
    relative = Path(source).relative_to(ROOT)
    return Path(directory) / "objects" / relative.parent / (relative.name + ".obj")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=tuple(SUFFIXES) + ("all",))
    args = parser.parse_args()
    for platform in SUFFIXES if args.platform == "all" else (args.platform,):
        for source in native_sources(platform):
            print(platform + ": " + source.relative_to(ROOT).as_posix())
