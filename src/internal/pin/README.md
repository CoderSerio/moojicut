# Shared pin policy

The scalar ABI in `native/shared/pin_policy.h` is used by the macOS, Windows and
Linux pin hosts. No window handles, event objects, image buffers or JSON cross
this boundary. Hosts retain monitor lookup, Retina/native unit conversion,
rounding/placement of native window rectangles, focus and input registration.

| Existing behavior | macOS (1) | Windows (2) | Linux (3) |
| --- | --- | --- | --- |
| Interactive fit | 95% work area | 100% work area | 100% work area |
| Scale range | 0.1–8, lowered when required to fit | Same | Same |
| Unanchored initial fit | 75%, at most original size | Original size | Interactive fit at scale 1 |
| Opacity domain / step | 0.1–1 / 0.1 | 26–255 / 26 | 0.1–1 / 0.1 |
| Recovery key required for visibility toggle | Hiding only | Hiding and restoring | Existing native global registration gate; local action unchanged |
| Explicit restore of hidden pass-through pins | Skip | Skip | Restore (legacy behavior) |

Visibility decisions prioritize a selected pin, otherwise restore a hidden group
before hiding all. Focus/selection effects deliberately remain with their native
window events: Windows clears selection for either toggle direction, Linux only
when hiding, and macOS can focus a restored selected pin.

Invalid geometry or nonfinite sizing produces zero, telling the host to keep its
current window geometry. Nonfinite opacity recovers to the visible default. These
checks keep invalid scalars away from window APIs; regular limits and platform
semantics are preserved.

Core regressions cover differing caps, tiny work areas, byte and unit alpha,
nonfinite input, selected-target priority, unavailable recovery keys and the
legacy pass-through differences. `test/native/pinned-image.m` exercises all
platform profiles through the actual scalar ABI and macOS's real pin controller;
Windows/Linux native smoke tests exercise their adapters on CI.
