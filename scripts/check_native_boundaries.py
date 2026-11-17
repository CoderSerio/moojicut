#!/usr/bin/env python3
"""Verify native file ownership and actual literal include/import boundaries.

The static build manifest is separate from runtime plugin registration. Every
native source, header, included fragment and native packaging resource in the
managed trees must have an owner, or one named, explained build-tool exclusion.
Legacy layer exceptions are exact file pairs; new code cannot inherit them.
"""

import argparse
import json
from pathlib import Path
import re

from native_modules import MANIFEST, ROOT, module_registry, resolve_sources

MANAGED_ROOTS = ("native", "components", "plugins/feature", "platform", "bindings")
CODE_SUFFIXES = {".c", ".cpp", ".m", ".mm", ".h", ".hpp", ".inc", ".swift"}
RESOURCE_SUFFIXES = {".rc", ".manifest", ".ico", ".json", ".sh", ".in"}
EXTERNAL_HEADERS = {"moonbit.h", "extism.h"}
COMMENTS = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/')
INCLUDES = re.compile(r'^\s*#\s*(?:include|import)\b([^\n]*)', re.M)
LITERAL_HEADER = re.compile(r'\s*(?:"([^"\n]+)"|<([^>\n]+)>)\s*')


def native_includes(text):
    text = text.replace("\\\n", "")
    text = COMMENTS.sub(lambda m: " " + "\n" * m.group().count("\n")
                        if m.group().startswith(("//", "/*")) else m.group(), text)
    literals, computed = [], []
    for directive in INCLUDES.findall(text):
        match = LITERAL_HEADER.fullmatch(directive)
        if match:
            literals.append((match[1] or match[2], match[1] is not None))
        else:
            computed.append(directive.strip())
    return literals, computed


def quoted_includes(text):
    return [header for header, quoted in native_includes(text)[0] if quoted]


def layer_violation(source_owner, target_owner):
    if source_owner == target_owner:
        return None
    if source_owner.startswith("shared.") and not target_owner.startswith("shared."):
        return "shared native foundations must not import a platform or product module"
    if source_owner.startswith("platform.") and not target_owner.startswith(("platform.", "shared.")):
        return "platform adapters must not import product features or UI components"
    if source_owner.startswith("component.") and not target_owner.startswith(("component.", "platform.", "shared.")):
        return "reusable components must not import product features or application modules"
    if source_owner.startswith("feature."):
        if target_owner.startswith(("system.", "host")):
            return "features must not import application orchestration"
        if target_owner.startswith("feature."):
            return "cross-feature coordination belongs in the application"
    return None


def check_native_boundaries(root, manifest):
    root = Path(root).resolve()
    errors, owners = [], {}
    for platform in manifest["platforms"]:
        try:
            resolve_sources(root, manifest, platform)
        except (KeyError, ValueError) as error:
            errors.append(str(error))
            continue
        registry = module_registry(manifest, platform)
        for name, module in registry.items():
            identity = ("shared" if name.startswith("shared.") else platform, name)
            for relative in module["sources"] + module.get("files", []):
                previous = owners.setdefault(relative, identity)
                if previous != identity:
                    errors.append(f"{relative}: more than one native owner")
    exclusions = manifest.get("excluded_files", {})
    for relative, reason in exclusions.items():
        path = (root / relative).resolve()
        if not reason.strip() or not path.is_relative_to(root) or not path.is_file():
            errors.append(f"{relative}: missing or unexplained native exclusion")
        if relative in owners:
            errors.append(f"{relative}: cannot be both owned and excluded")
    for directory in MANAGED_ROOTS:
        for path in (root / directory).rglob("*"):
            if path.is_file() and path.suffix in CODE_SUFFIXES | RESOURCE_SUFFIXES:
                relative = path.relative_to(root).as_posix()
                if relative not in owners and relative not in exclusions:
                    errors.append(f"{relative}: native file is not registered")
    exceptions = {}
    for entry in manifest.get("legacy_includes", []):
        key = (entry["from"], entry["to"])
        if key in exceptions or not entry.get("reason", "").strip():
            errors.append(f"{key}: duplicate or unexplained legacy include")
        exceptions[key] = entry
    used_exceptions = set()
    for relative, (platform, name) in owners.items():
        path = root / relative
        if path.suffix not in CODE_SUFFIXES or not path.is_file():
            continue
        dependencies = {name}
        registry = module_registry(manifest, platform) if platform != "shared" else manifest.get("shared", {})

        def include_dependencies(owner):
            for dependency in registry[owner]["requires"] + registry[owner].get("includes", []):
                if dependency not in dependencies and dependency in registry:
                    dependencies.add(dependency)
                    include_dependencies(dependency)

        include_dependencies(name)
        includes, computed = native_includes(path.read_text(encoding="utf-8"))
        for directive in computed:
            errors.append(f"{relative}: computed include cannot be checked; use a literal header: {directive}")
        for include, quoted in includes:
            candidates = ((path.parent / include).resolve(), (root / include).resolve())
            target = next((candidate for candidate in candidates if candidate.is_file()), None)
            if target is None:
                managed = include.startswith(tuple(prefix + "/" for prefix in MANAGED_ROOTS))
                if managed or (quoted and include not in EXTERNAL_HEADERS):
                    errors.append(f"{relative}: cannot resolve native include {include}")
                continue
            if not target.is_relative_to(root):
                errors.append(f"{relative}: include escapes repository: {include}")
                continue
            target_path = target.relative_to(root).as_posix()
            target_identity = owners.get(target_path)
            if target_identity is None:
                errors.append(f"{relative}: include has no registered owner: {target_path}")
                continue
            target_platform, target_name = target_identity
            if target_platform not in (platform, "shared"):
                errors.append(f"{relative}: imports another platform: {target_path}")
                continue
            if target_name not in dependencies:
                errors.append(f"{relative}: undeclared native dependency {name} -> {target_name}")
            reason = layer_violation(name, target_name)
            key = (relative, target_path)
            if reason:
                if key in exceptions:
                    used_exceptions.add(key)
                else:
                    errors.append(f"{relative}: {reason}: {target_path}")
    for source, target in exceptions.keys() - used_exceptions:
        errors.append(f"{source}: unused legacy exception for {target}; remove it")
    return sorted(set(errors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    manifest = json.loads((args.root / MANIFEST.relative_to(ROOT)).read_text(encoding="utf-8"))
    errors = check_native_boundaries(args.root, manifest)
    if errors:
        raise SystemExit("\n".join(errors))
    print("Native file ownership and include boundaries passed.")
