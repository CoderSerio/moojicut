#!/usr/bin/env python3
"""Compile vendored Lucide SVGs and Mooji Cut geometric glyphs to native vectors.

No runtime SVG parser, JavaScript, or extra build dependency is required. This
deliberately rejects unsupported SVG constructs instead of silently dropping them.
Run with --check in CI after changing assets or this generator.
"""

import argparse
import json
import math
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets/icons/lucide"
TARGET = ROOT / "components/icons/shared/mc_icons.h"
MOON_TARGET = ROOT / "src/internal/shared/ui/icons/builtin_paths.mbt"


def arc(start, args):
    """SVG endpoint arcs -> <=90 degree cubic Beziers (SVG 2 appendix B)."""
    rx, ry, degrees, large, sweep, x, y = args
    if start == (x, y):
        return []
    rx, ry = abs(rx), abs(ry)
    if not rx or not ry:
        return [("L", x, y)]
    phi = math.radians(degrees)
    co, si = math.cos(phi), math.sin(phi)
    dx, dy = (start[0] - x) / 2, (start[1] - y) / 2
    px, py = co * dx + si * dy, -si * dx + co * dy
    correction = px * px / (rx * rx) + py * py / (ry * ry)
    if correction > 1:
        rx *= math.sqrt(correction)
        ry *= math.sqrt(correction)
    factor = math.sqrt(max(0, (rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px)
                           / (rx * rx * py * py + ry * ry * px * px)))
    if bool(large) == bool(sweep):
        factor = -factor
    cxp, cyp = factor * rx * py / ry, -factor * ry * px / rx
    cx, cy = co * cxp - si * cyp + (start[0] + x) / 2, si * cxp + co * cyp + (start[1] + y) / 2
    ux, uy = (px - cxp) / rx, (py - cyp) / ry
    vx, vy = (-px - cxp) / rx, (-py - cyp) / ry
    angle = math.atan2(uy, ux)
    delta = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    if sweep and delta < 0:
        delta += math.tau
    elif not sweep and delta > 0:
        delta -= math.tau
    count = max(1, math.ceil(abs(delta) / (math.pi / 2)))
    step = delta / count

    def point(t):
        return (cx + rx * co * math.cos(t) - ry * si * math.sin(t),
                cy + rx * si * math.cos(t) + ry * co * math.sin(t))

    def derivative(t):
        return (-rx * co * math.sin(t) - ry * si * math.cos(t),
                -rx * si * math.sin(t) + ry * co * math.cos(t))

    commands = []
    for index in range(count):
        a, b = angle + index * step, angle + (index + 1) * step
        p, q, u, v = point(a), point(b), derivative(a), derivative(b)
        alpha = 4 / 3 * math.tan(step / 4)
        end = (x, y) if index == count - 1 else q
        commands.append(("C", p[0] + alpha * u[0], p[1] + alpha * u[1],
                         q[0] - alpha * v[0], q[1] - alpha * v[1], *end))
    return commands


def path_commands(data):
    tokens = re.findall(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?", data)
    commands, current, start = [], (0, 0), (0, 0)
    index, command = 0, None
    counts = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "A": 7}
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command is None:
            raise ValueError("Path must begin with a command")
        upper, relative = command.upper(), command.islower()
        if upper == "Z":
            commands.append(("Z",))
            current, command = start, None
            continue
        if upper not in counts:
            raise ValueError("Unsupported SVG command: " + command)
        size = counts[upper]
        values = list(map(float, tokens[index:index + size]))
        if len(values) != size:
            raise ValueError("Incomplete SVG command")
        index += size
        if upper in ("M", "L", "C"):
            if relative:
                values = [value + current[i % 2] for i, value in enumerate(values)]
            commands.append((upper, *values))
            current = tuple(values[-2:])
            if upper == "M":
                start, command = current, "l" if relative else "L"
        elif upper in ("H", "V"):
            axis = 0 if upper == "H" else 1
            point = list(current)
            point[axis] = values[0] + (current[axis] if relative else 0)
            commands.append(("L", *point))
            current = tuple(point)
        else:
            if relative:
                values[-2] += current[0]
                values[-1] += current[1]
            commands.extend(arc(current, values))
            current = tuple(values[-2:])
    return commands


def read_svg(path):
    root = ET.parse(path).getroot()
    expected = {"width": "24", "height": "24", "viewBox": "0 0 24 24", "fill": "none",
                "stroke": "currentColor", "stroke-width": "2", "stroke-linecap": "round",
                "stroke-linejoin": "round"}
    if root.attrib != expected:
        raise ValueError("Expected an untransformed, unfilled 24 x 24 Lucide icon with round strokes")
    allowed = {"path": {"d"}, "rect": {"x", "y", "width", "height", "rx", "ry"},
               "line": {"x1", "y1", "x2", "y2"}}
    result = []
    for child in root:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag not in allowed or set(child.attrib) - allowed[tag] or len(child):
            raise ValueError("Unsupported SVG element or attributes: " + tag)
        if tag == "path":
            result.extend(path_commands(child.attrib["d"]))
        elif tag == "rect":
            x, y, w, h = [float(child.get(k, 0)) for k in ("x", "y", "width", "height")]
            rx = min(float(child.get("rx", 0)), w / 2)
            ry = min(float(child.get("ry", rx)), h / 2)
            result.extend(path_commands(f"M{x+rx} {y} H{x+w-rx} A{rx} {ry} 0 0 1 {x+w} {y+ry} "
                                       f"V{y+h-ry} A{rx} {ry} 0 0 1 {x+w-rx} {y+h} "
                                       f"H{x+rx} A{rx} {ry} 0 0 1 {x} {y+h-ry} "
                                       f"V{y+ry} A{rx} {ry} 0 0 1 {x+rx} {y} Z"))
        elif tag == "line":
            result.extend([("M", float(child.get("x1", 0)), float(child.get("y1", 0))),
                           ("L", float(child.get("x2", 0)), float(child.get("y2", 0)))])
        else:
            raise ValueError("Unsupported SVG element: " + tag)
    return result


def icon_paths():
    source = json.loads((SOURCE / "source.json").read_text())
    icons = {name: read_svg(SOURCE / (filename + ".svg")) for name, filename in source["icons"].items()}
    # Mooji Cut's shape selectors use simple project-owned geometric glyphs.
    # Keep fill semantics in the shared vector catalog for every native backend.
    icons["REDACT"] = path_commands("M3 5 H21 V19 H3 Z")
    ellipse = path_commands("M21 12 A9 7 0 1 1 3 12 A9 7 0 1 1 21 12 Z")
    icons["ELLIPSE"] = ellipse
    icons["COVER_ELLIPSE"] = ellipse
    icons["MOSAIC"] = []
    for x, y, opacity in [(3, 3, 1), (13, 3, .35), (3, 13, .55), (13, 13, .8)]:
        icons["MOSAIC"].extend(path_commands(f"M{x} {y} H{x+8} V{y+8} H{x} Z"))
        icons["MOSAIC"].append(("F", opacity))  # fill/reset path with relative foreground opacity
    return source, icons


def generate():
    source, icons = icon_paths()
    lines = ["/* Generated by scripts/generate_icons.py. Do not edit.",
             " * Lucide " + source["version"] + " (" + source["commit"] + ")",
             " * ISC / Feather MIT: assets/icons/lucide/LICENSE; shape variants are Mooji Cut geometry. */",
             "#ifndef MOOJICUT_SHARED_ICONS_H", "#define MOOJICUT_SHARED_ICONS_H", "#include <string.h>",
             "typedef enum {", *["  MC_ICON_" + name + "," for name in icons],
             "  MC_ICON_COUNT", "} MCIcon;",
             "typedef struct { char op; float x1, y1, x2, y2, x3, y3; } MCIconCommand;",
             "typedef struct { const MCIconCommand *commands; unsigned count; } MCIconPath;"]
    for name, commands in icons.items():
        lines.append("static const MCIconCommand mc_icon_" + name.lower() + "[] = {")
        for op, *values in commands:
            values += [0] * (6 - len(values))
            numbers = [format(0 if abs(value) < 0.0000005 else value, ".6f") + "f" for value in values]
            lines.append("  {'" + op + "', " + ", ".join(numbers) + "},")
        lines.append("};")
    lines.extend(["/* Stable asset names for declarative contributions; unknown names have no geometry. */",
                  "static inline MCIcon mc_icon_from_name(const char *name) {",
                  "  if (!name) return MC_ICON_COUNT;"])
    for name in icons:
        lines.append('  if (!strcmp(name, "' + name.lower() + '")) return MC_ICON_' + name + ';')
    lines.extend(["  return MC_ICON_COUNT;", "}",
                  "static inline MCIconPath mc_icon_path(MCIcon icon) {", "  switch (icon) {"])
    for name in icons:
        array = "mc_icon_" + name.lower()
        lines.extend(["    case MC_ICON_" + name + ": {",
                      "      MCIconPath path = {" + array + ", sizeof(" + array + ") / sizeof(" + array + "[0])};",
                      "      return path;", "    }"])
    lines.extend(["    default: { MCIconPath empty = {0, 0}; return empty; }", "  }", "}",
                  "static inline int mc_icon_filled(MCIcon icon) {",
                  "  return icon == MC_ICON_REDACT || icon == MC_ICON_COVER_ELLIPSE || icon == MC_ICON_MOSAIC;",
                  "}", "#endif", ""])
    return "\n".join(lines)


def generate_moon():
    """Compile the same paths to bounded line/rectangle shared-frame primitives.

    Cubics are subdivided at build time (12 samples per <=90 degree arc), so
    hosts need no SVG parser, product icon enum, or curve approximation policy.
    Filled shape variants use thin scanlines; normal toolbar glyphs are strokes.
    """
    source, icons = icon_paths()
    # Project-owned glyphs for shared toolbar navigation and missing plugin art.
    icons["CHEVRON_LEFT"] = path_commands("M15 6 L9 12 L15 18")
    icons["CHEVRON_RIGHT"] = path_commands("M9 6 L15 12 L9 18")
    icons["SAVE"] = path_commands("M12 3 V15 M7 10 L12 15 L17 10 M4 16 V20 H20 V16")
    icons["SCROLL"] = path_commands("M5 5 H19 V19 H5 Z M12 3 V21 M9 6 L12 3 L15 6 M9 18 L12 21 L15 18")
    icons["PLUGIN"] = path_commands("M4 4 H9 C7 0 17 0 15 4 H20 V9 C24 7 24 17 20 15 V20 H15 C17 24 7 24 9 20 H4 V15 C0 17 0 7 4 9 Z")
    lines = ["// Generated by scripts/generate_icons.py. Do not edit.",
             "// Lucide " + source["version"] + "; ISC / Feather MIT: assets/icons/lucide/LICENSE.",
             "// Each primitive is (filled rectangle?, x1, y1, x2/width, y2/height, opacity).",
             "///|", "fn paths(name : String) -> Array[(Bool, Double, Double, Double, Double, Double)] {",
             "  match name {"]
    for name, commands in icons.items():
        filled = name in ("REDACT", "COVER_ELLIPSE", "MOSAIC")
        primitives, contour = [], []
        current = start = (0.0, 0.0)

        def segment(point):
            nonlocal current
            if not filled:
                primitives.append((False, *current, *point, 1.0))
            contour.append(point)
            current = point

        def flush(opacity):
            if not filled or not contour:
                return
            # Axis aligned rectangles stay a single primitive, including mosaic.
            xs, ys = {p[0] for p in contour}, {p[1] for p in contour}
            if len(xs) == 2 and len(ys) == 2:
                primitives.append((True, min(xs), min(ys), max(xs)-min(xs), max(ys)-min(ys), opacity))
            else:
                y0, y1 = min(ys), max(ys)
                count = max(1, math.ceil((y1-y0)*4))
                step = (y1-y0)/count
                for row in range(count):
                    y = y0 + (row + .5)*step
                    intersections = []
                    for a, b in zip(contour, contour[1:] + contour[:1]):
                        if min(a[1], b[1]) <= y < max(a[1], b[1]):
                            intersections.append(a[0] + (y-a[1])*(b[0]-a[0])/(b[1]-a[1]))
                    intersections.sort()
                    for left, right in zip(intersections[::2], intersections[1::2]):
                        primitives.append((True, left, y0+row*step, right-left, step, opacity))
            contour.clear()

        for op, *v in commands:
            if op == "M":
                current = start = tuple(v)
                contour.append(current)
            elif op == "L":
                segment(tuple(v))
            elif op == "C":
                a = current
                for index in range(1, 13):
                    t, u = index/12, 1-index/12
                    segment(tuple(u**3*a[k] + 3*u*u*t*v[k] + 3*u*t*t*v[k+2] + t**3*v[k+4] for k in range(2)))
            elif op == "Z":
                segment(start)
            elif op == "F":
                flush(v[0])
        flush(1)
        lines.append('    "' + name.lower() + '" => [')
        for rect, *values in primitives:
            lines.append("      (" + str(rect).lower() + ", " + ", ".join(format(0 if abs(v)<.0000005 else v, ".6f") for v in values) + "),")
        lines.append("    ]")
    lines.extend(["    _ => []", "  }", "}", ""])
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content = generate()
    moon_content = generate_moon()
    if args.check:
        if not TARGET.is_file() or TARGET.read_text() != content:
            raise SystemExit("Native icons are stale. Run python scripts/generate_icons.py")
        if not MOON_TARGET.is_file() or MOON_TARGET.read_text() != moon_content:
            raise SystemExit("Shared MoonBit icons are stale. Run python scripts/generate_icons.py")
    else:
        TARGET.parent.mkdir(parents=True, exist_ok=True)
        TARGET.write_text(content)
        MOON_TARGET.parent.mkdir(parents=True, exist_ok=True)
        MOON_TARGET.write_text(moon_content)
    print("Native icon vectors match the source catalog.")
