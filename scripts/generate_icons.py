#!/usr/bin/env python3
"""Compile the vendored Lucide SVG subset to portable native vector commands.

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


def generate():
    source = json.loads((SOURCE / "source.json").read_text())
    lines = ["/* Generated by scripts/generate_icons.py. Do not edit.",
             " * Lucide " + source["version"] + " (" + source["commit"] + ")",
             " * ISC / Feather MIT: assets/icons/lucide/LICENSE. */",
             "#ifndef MOOJICUT_SHARED_ICONS_H", "#define MOOJICUT_SHARED_ICONS_H",
             "typedef enum {", *["  MC_ICON_" + name + "," for name in source["icons"]],
             "  MC_ICON_COUNT", "} MCIcon;",
             "typedef struct { char op; float x1, y1, x2, y2, x3, y3; } MCIconCommand;",
             "typedef struct { const MCIconCommand *commands; unsigned count; } MCIconPath;"]
    for name, filename in source["icons"].items():
        lines.append("static const MCIconCommand mc_icon_" + name.lower() + "[] = {")
        for op, *values in read_svg(SOURCE / (filename + ".svg")):
            values += [0] * (6 - len(values))
            numbers = [format(0 if abs(value) < 0.0000005 else value, ".6f") + "f" for value in values]
            lines.append("  {'" + op + "', " + ", ".join(numbers) + "},")
        lines.append("};")
    lines.extend(["static inline MCIconPath mc_icon_path(MCIcon icon) {", "  switch (icon) {"])
    for name in source["icons"]:
        array = "mc_icon_" + name.lower()
        lines.extend(["    case MC_ICON_" + name + ": {",
                      "      MCIconPath path = {" + array + ", sizeof(" + array + ") / sizeof(" + array + "[0])};",
                      "      return path;", "    }"])
    lines.extend(["    default: { MCIconPath empty = {0, 0}; return empty; }", "  }", "}", "#endif", ""])
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    content = generate()
    if args.check:
        if not TARGET.is_file() or TARGET.read_text() != content:
            raise SystemExit("Native icons are stale. Run python scripts/generate_icons.py")
    else:
        TARGET.parent.mkdir(parents=True, exist_ok=True)
        TARGET.write_text(content)
    print("Lucide native vectors match the vendored SVG sources.")
