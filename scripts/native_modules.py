"""Resolve explicitly listed, statically linked built-ins for native builds.

This is a build manifest, not a runtime plugin loader or a public plugin ABI.
Imported user code is never discovered or compiled by these helpers. Native
headers remain internal; the MoonBit library is built separately from moon.mod.
"""

import argparse
import json
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "plugins/system/builtins.json"
SUFFIXES = {"macos": {".m", ".c"}, "windows": {".c", ".cpp"}, "linux": {".c"}}


def resolve_sources(root, manifest, platform, modules=("host",)):
    """Validate ownership/dependencies, then return the requested dependency closure."""
    root = Path(root).resolve()
    if manifest.get("schema_version") != 1 or platform not in SUFFIXES:
        raise ValueError("Unsupported native module schema or platform.")
    registry = manifest["platforms"][platform]
    owners = {}
    for name, module in registry.items():
        if len(set(module["requires"])) != len(module["requires"]):
            raise ValueError("Duplicate dependency in " + name)
        for dependency in module["requires"]:
            if dependency not in registry:
                raise ValueError("Unknown dependency: " + dependency)
        for source in module["sources"]:
            path = PurePosixPath(source)
            if path.is_absolute() or ".." in path.parts or "\\" in source:
                raise ValueError("Source must be a repository-relative path: " + source)
            if name == "host" or name.startswith("system."):
                prefix = "native/" + platform + "/"
            else:
                kind, separator, feature = name.partition(".")
                if not separator or kind not in ("feature", "component"):
                    raise ValueError("Invalid module name: " + name)
                prefix = ("plugins/feature/" if kind == "feature" else "components/") + feature + "/" + platform + "/"
            if not source.startswith(prefix) or path.suffix not in SUFFIXES[platform]:
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
    return resolve_sources(ROOT, json.loads(MANIFEST.read_text(encoding="utf-8")),
                           platform, modules or ("host",))


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
