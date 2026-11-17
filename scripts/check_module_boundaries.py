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


def production_imports(source):
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
        else:
            imports.extend(paths)
    return imports


def within(path, parent):
    return path == parent or path.startswith(parent + "/")


def ownership(package):
    # Apply the same boundaries during incremental migration. An old package
    # name must not provide a back door from shared code to a product feature.
    legacy = {
        "protocol": "shared/protocol",
        "selection": "shared/geometry",
        "test_support": "shared/test_support",
        "video": "features/video_editor/core",
        "video_project": "features/video_editor/core",
        "video_ui": "features/video_editor/ui",
        "pin": "features/capture/extensions/pin",
        "desktop": "app/shortcuts",
        "updates": "app/updates",
        "tool_registry": "plugins/runtime",
        "feature_runtime": "plugins/runtime",
        "plugin_protocol": "plugins/contracts",
    }
    first, separator, rest = package.partition("/")
    return legacy.get(first, first) + (separator + rest if separator else "")


def violation(package, dependency, module):
    if dependency == module:
        return "internal packages must not import the root ABI facade"
    if not dependency.startswith(module + "/"):
        return None
    prefix = module + "/internal/"
    if not dependency.startswith(prefix):
        return "internal packages must not import executable or public entry packages"
    package = ownership(package)
    target = ownership(dependency[len(prefix):])
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
    for path in sorted(internal.rglob("moon.pkg.json")):
        errors.append(f"{path.relative_to(root)}: migrate legacy JSON manifests before checking imports")
    for path in sorted(internal.rglob("moon.pkg")):
        package = path.parent.relative_to(internal).as_posix()
        try:
            dependencies = production_imports(path.read_text(encoding="utf-8"))
        except ValueError as error:
            errors.append(f"{path.relative_to(root)}: {error}")
            continue
        for dependency in dependencies:
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
