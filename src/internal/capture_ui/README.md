# Shared screenshot interactions

This is the first screenshot UI migration slice. macOS now uses this package
for rectangle, arrow and cover gestures and floating toolbar placement. Text
input, window hit testing, toolbar control painting and property controls still
use native adapters. Windows/Linux have not yet adopted this new boundary.

`src/api_capture_ui.mbt` exports the C ABI in `native/shared/capture_ui.h`.
All calls run on the UI thread. Sessions are per editor, disposable, and never
reuse handles. The image document and undo history stay in `internal/image`.

## Gesture contract

`capture_ui_open(sourceWidth, sourceHeight)` returns a handle (zero on failure).
`capture_ui_event` accepts a JSON object containing `session` and `type`:

| Event | Additional fields | Result |
| --- | --- | --- |
| `begin` | `id`, `kind` (1 outline, 2 arrow, 4 cover), `x`, `y`, `color`, `opacity`, `stroke`; optional `shape`, `blockSize` | Freeze identity, tool and style for this gesture |
| `move` | `x`, `y` | `preview` annotation, no command |
| `end` | `x`, `y` | One `command:{type:"add",annotations:[...]}`, clears the draft |
| `cancel` | — | Clear the draft without a command |

Successful responses contain `ok:true`, `active`, `preview` and `command`.
Absent previews/commands are JSON null. Invalid inputs return `ok:false` and
leave the current transaction intact. Cancel or close on tool disable, editor
close or interrupted input. A repeated end, or end after cancel, emits nothing.
The host applies a returned command through `image_apply` with the current
expected revision; an agent can submit that same command directly.

`shape` defaults to 0: outline supports 0 rectangle / 1 ellipse; cover supports
0 rectangle / 1 ellipse / 2 mosaic. `blockSize` defaults to 12 source pixels
(4–48). Shared `editor_style` owns per-tool defaults and conditional property
visibility. Mosaic is opaque and uses the block-size control, not RGBA controls.
An existing object changes through `image_apply` command
`{type:"setShape",id,shape}`, preserving identity and bounds with one undo entry.
Outline and cover families cannot be interchanged by this command.

The macOS compositor renders outlines, elliptical fills and pixelated masks in
both preview and export. `components/image_effects/macos` samples the scene
below a mosaic on a source-anchored grid, including other annotations and earlier
masks. The native inline-text adapter uses the same compositor above live text.

Coordinates are source pixels. Rectangles/covers normalize reverse drags;
arrows preserve directed endpoints, including horizontal/vertical lines.
Points clamp to source bounds. Movement below 3 pixels, or area shapes with an
edge below 2 pixels, produces no annotation. Tool enablement/IME preflight stays
in the host during this migration; it must cancel when the active tool closes.

## Layout contract

`capture_ui_toolbar_frame` takes positive finite surface dimensions, a region
in top-left logical points, and renderer-measured toolbar/property widths. It
returns an owned four-double array `[x,y,width,height]`; release it with
`moonbit_decref`. The shared policy anchors below the region's right edge, moves
above when necessary, clamps to the display and omits an empty property row.
The host converts AppKit's bottom-left coordinates only at this boundary.

## Cases and checks

- Reverse-drawn rectangle: normalized bounds, stable preview ID, one undo entry.
- Reverse/horizontal arrow: directed endpoints survive preview, commit and export.
- Cover: the same geometry contract with solid fill and independent style.
- Escape/tool disable: cancelled drafts cannot be committed by a later release.
- Two toolbar groups: editing, OCR/translation and history on the left;
  pin/cancel/confirm on the right. Pin is never a selected annotation tool.

Run `moon test --target native --deny-warn -p moojicut/core/internal/capture_ui`
and the equivalent `--target js` for the same shared event tests.
`python3 scripts/native.py test` includes the real macOS `tool-layout` and
`capture-overlay` regressions. Set `MOOJICUT_TOOLBAR_PREVIEW_DIR` when running
`tool-layout` to save light/dark screenshots of its synthetic source in the
production editor. Tests do not install apps, capture the desktop or copy data
to the system clipboard.
