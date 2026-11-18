#!/usr/bin/env python3
"""Check production MoonBit imports against the shared architecture boundaries.

This checks source package dependencies, not the native linkage manifest. Test
imports may cross layers to verify an integration without shipping that edge.
"""

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TOKENS = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9]*|[^\s]')
RETIRED_PACKAGES = frozenset({
    "image", "capture_ui", "editor_style", "desktop", "feature_runtime", "pin",
    "plugin_protocol", "selection", "tool_registry", "updates", "video",
    "video_project", "video_ui", "protocol", "test_support",
})
INTERNAL_ROOTS = frozenset({"app", "cli", "features", "plugins", "shared"})


def package_imports(source, include_tests=False):
    tokens = [token for token in TOKENS.findall(source)
              if not token.startswith(("//", "/*"))]
    imports = []
    index = 0
    while index < len(tokens):
        if tokens[index] != "import":
            index += 1
            continue
        index += 1
        if index >= len(tokens) or tokens[index] != "{":
            raise ValueError("Unsupported import syntax; update the boundary checker")
        index += 1
        paths = []
        while index < len(tokens) and tokens[index] != "}":
            if tokens[index].startswith('"'):
                paths.append(json.loads(tokens[index]))
            index += 1
        if index == len(tokens):
            raise ValueError("Unclosed import block")
        index += 1
        if index < len(tokens) and tokens[index] == "for":
            if index + 1 >= len(tokens) or tokens[index + 1] not in ('"test"', '"wbtest"'):
                raise ValueError("Unknown import scope; update the boundary checker")
            index += 2
            if include_tests:
                imports.extend(paths)
        else:
            imports.extend(paths)
    return imports


def production_imports(source):
    return package_imports(source)


def within(path, parent):
    return path == parent or path.startswith(parent + "/")


def location_error(package):
    first = package.partition("/")[0]
    if first in RETIRED_PACKAGES:
        return "retired package path; use its canonical app/features/plugins/shared owner"
    if first not in INTERNAL_ROOTS:
        return "internal package must belong to app, cli, features, plugins or shared"
    return None


def violation(package, dependency, module):
    if dependency == module:
        return "internal packages must not import the root ABI facade"
    if not dependency.startswith(module + "/"):
        return None
    prefix = module + "/internal/"
    if not dependency.startswith(prefix):
        return "internal packages must not import executable or public entry packages"
    target = dependency[len(prefix):]
    if reason := location_error(target):
        return reason
    if within(target, "shared/test_support"):
        return "test helpers must be imported only for tests"
    parts = package.split("/")
    if len(parts) >= 2 and parts[0] == "features":
        feature = "/".join(parts[:2])
        if within(target, "features") and not within(target, feature):
            return "cross-feature coordination belongs in app"
        if within(target, "app") or within(target, "cli"):
            return "features must not depend on application or CLI orchestration"
        if len(parts) >= 3 and parts[2] == "core":
            allowed = (feature + "/core", "shared")
            if not any(within(target, name) for name in allowed):
                return "feature core may depend only on its own core and shared foundations"
        if len(parts) >= 3 and parts[2] == "ui":
            if within(target, feature) and not any(
                    within(target, name) for name in (feature + "/ui", feature + "/core")):
                return "feature UI receives contributions from its root; it must not import the root or extensions"
    if within(package, "shared") and not within(target, "shared"):
        return "shared foundations must not depend on product features or orchestration"
    if within(package, "plugins"):
        if not any(within(target, name) for name in ("plugins", "shared")):
            return "generic plugin infrastructure must not depend on concrete features"
        if within(package, "plugins/contracts") and within(target, "plugins/runtime"):
            return "plugin contracts must not depend on their runtime"
    return None


def check_boundaries(root):
    root = Path(root)
    manifest = (root / "moon.mod").read_text(encoding="utf-8")
    module = re.search(r'^name\s*=\s*"([^"]+)"', manifest, re.M).group(1)
    source = re.search(r'^source\s*=\s*"([^"]+)"', manifest, re.M)
    internal = root / (source.group(1) if source else ".") / "internal"
    errors = []
    # Empty old directories and loose source files are not a migration escape
    # hatch. All retired roots have been moved; never translate them as aliases.
    for name in sorted(RETIRED_PACKAGES):
        if (internal / name).exists():
            errors.append(f"{(internal / name).relative_to(root)}: {location_error(name)}")
    for path in sorted(internal.rglob("moon.pkg.json")):
        errors.append(f"{path.relative_to(root)}: migrate legacy JSON manifests before checking imports")
    for path in sorted(internal.rglob("moon.pkg")):
        package = path.parent.relative_to(internal).as_posix()
        if package.partition("/")[0] in RETIRED_PACKAGES:
            continue
        if reason := location_error(package):
            errors.append(f"{path.relative_to(root)}: {reason}")
            continue
        try:
            source = path.read_text(encoding="utf-8")
            dependencies = production_imports(source)
            all_dependencies = package_imports(source, include_tests=True)
        except ValueError as error:
            errors.append(f"{path.relative_to(root)}: {error}")
            continue
        # Test imports may cross active layers, but cannot resurrect old paths.
        prefix = module + "/internal/"
        retired = set()
        for dependency in all_dependencies:
            if dependency.startswith(prefix) and dependency[len(prefix):].partition("/")[0] in RETIRED_PACKAGES:
                retired.add(dependency)
        for dependency in sorted(retired):
            errors.append(f"{path.relative_to(root)} imports {dependency}: retired package path")
        for dependency in dependencies:
            if dependency in retired:
                continue
            reason = violation(package, dependency, module)
            if reason:
                errors.append(f"{path.relative_to(root)} imports {dependency}: {reason}")
    return errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    arguments = parser.parse_args()
    errors = check_boundaries(arguments.root)
    if errors:
        raise SystemExit("\n".join(errors))
    print("MoonBit production module boundaries passed.")
