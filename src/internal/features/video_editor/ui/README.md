# Shared video UI prototype

This package owns layout, drawing descriptions, hit testing, pointer gestures,
keyboard actions, focus, accessibility semantics, and transient preview state.
It has no window, platform control, filesystem, player, or document history.
The existing video reducer remains authoritative.

- `open(snapshot)` accepts the full successful `video_open` / `video_snapshot`
  JSON result; invalid input returns `-1`.
- `frame(id, width, height)` produces top-left logical-point drawing commands,
  `videoRect`, semantic nodes, and cursor. Call it before pointer events. The
  design adapts to larger windows and scales below 720×480 without overflowing.
- `event(id, json)` returns ordered effects, pointer capture, and cursor. Hosts
  dispatch effects then publish the resulting authoritative snapshot. A command
  effect is a request, not confirmation that the reducer accepted the edit.
- `close(id)` releases only UI state, not the host's document or media.

Input includes pointerDown/Move/Up, cancel, key, activate, snapshot, playback,
error, exportStatus, and mediaStatus. `key` uses platform-neutral Space, Escape, ArrowLeft,
ArrowRight, Tab, Enter, Home, End, z/Z plus mod and shift. Semantic `activate`
presses a button or focuses a slider. Arrow keys then adjust that slider.

A trim gesture sends `seek` with `preview:true` against the original source.
Release emits at most one `command` containing a trim request, followed by
`restorePreview` with a source-time position. Cancellation emits restorePreview
without a document edit. Ordinary scrubbing sends `preview:false`. Hosts must
restore the current edited composition even after an unchanged or rejected trim.
Playback clock callbacks do not override an active pointer preview.

Export immediately gates repeated exports and all document-changing controls.
The host sends `{type:"exportStatus",busy,message,error}` to report progress,
completion, or failure. Playback and scrubbing remain available while exporting.

Drawing commands use rect/line/text, with optional text `valign:"center"`.
All styles are selected here; adapters only execute drawing and expose supplied
semantics. Native media fills videoRect; no invented thumbnail frames are drawn.

The host reports `{type:"mediaStatus",ready,message}` after plan synchronization.
When ready is false, shared UI cancels its gesture without emitting any media
restore effect and disables playback, seek, trim, and export. Undo/redo remain
available (unless export is busy) so a valid plan can be recovered. A successful
core snapshot alone does not clear this failure; only mediaStatus ready:true does.

Appearance defaults to dark. The host sends
`{type:"appearance",mode:"dark"|"light"}` when its effective appearance changes.
`palette.mbt` owns all neutral UI colors, including hover, pressed, focus and
disabled states. An appearance event changes no document or interaction state
and produces no effects; it can safely arrive during a pointer gesture.

The shared transport has `start`, `backward`, `play`, `forward`, `end`,
`preview-rate` button IDs, with `undo`/`redo` in the title bar. Navigation steps by 1% of the edited duration, capped at 5 seconds, using
edited output time, maps through the validated retained segments, pauses, and
emits a normal source-time seek; the ruler remains explicitly a source timeline.
Home/End seek to the retained endpoints unless a trim handle or rate menu is
focused. Space toggles playback, or operates the focused speed menu. J has no
reverse-playback or skip binding.

The shared rate menu offers `rate-0.5`, `rate-1`, `rate-1.5`, `rate-2`, `rate-3`.
Arrow keys move its focus, Home/End select its first/last row, Enter/Space choose,
and Escape/Tab/outside click dismiss it without choosing. Selecting a rate only
updates UI preview state and emits `{type:"previewRate",rate}`. The host returns
`{type:"previewRateStatus",rate,message,error}` using its actual applied rate;
all fields and the allowed rate are validated before any state change. A rate
never creates a document command, changes exported duration, or enters undo.
Media failure closes the menu and disables all media transport controls.

## V2 project UI

`document.schemaVersion == 2` selects the shared project view; v1 remains
supported by the same ABI. V2 retains authoritative 90,000-tick clip metadata,
while all transport/playhead display and `playback.outputMs` use edited output
milliseconds. Normal seeks emit `{type:"seekOutput",outputMs,preview:false}`.
The original source-time transport remains confined to v1.

The host wraps a UI command's direct `type` operation with its core
`expectedRevision` and `requestId`, then publishes the authoritative snapshot.
The component never writes revision or document history itself.

Stable semantic IDs:

- Selection: `clip:<core clip id>`; labels show human-facing clip numbers.
- Video edits: `project-split`, `project-remove`, `project-move-earlier`,
  `project-move-later`, `project-speed`, `project-unlink`.
- Actual speed menu: `clip-rate-0.5`, `clip-rate-1`, `clip-rate-1.5`,
  `clip-rate-2`, `clip-rate-3`; these submit `setSpeed`, unlike preview rate.
- Audio: `project-audio-toggle`, `project-offset-earlier`,
  `project-offset-later`. Offset is available only for unlinked audio and
  quantizes the navigation step to the 30fps grid; it is not video reorder.
- Selected clip handles: `project-trim-start`, `project-trim-end`.

Ordinary Delete/Backspace and the remove button send `ripple:false`, retaining
a middle gap. Shift+Delete/Backspace removes and closes the gap for video or
linked groups. Unlinked audio always removes without ripple. Speed and trim
use ripple for video/linked groups, and `ripple:false` for independent audio. Relink is intentionally
absent because the current reducer does not provide it.

Trim dragging only displays a source-range candidate. It does not pretend the
player has applied a temporary composition. Escape rolls back without commands;
release emits one trim operation then a normal output seek. The changed edge
maps through the clip's actual source/output ratio. An unchanged source edge is
preserved exactly, including non-frame boundaries produced by a speeded split.
Core rejection restores authoritative metadata through the normal error/snapshot
path. Closing or invalidating media cancels UI capture without restore recursion.

Dragging a clip body previews absolute placement, keeping linked audio/video
together and leaving independent audio unchanged. Movement starts after three
logical points; compatible clip edges snap within six points at the current
zoom. The pointer-down time mapping stays fixed during the gesture, including
beyond the right viewport edge. Candidates clamp at zero and the project limit;
video collisions are shown as invalid, never resolved by silently moving other
clips. Release emits at most one `move` with `startTicks` and `linked:true`;
ordinary clicks retain their select/seek behavior. Escape, cancel, media failure,
authoritative snapshots, or a frame-size change discard the pending placement.
The body and its waveform move together; no temporary media composition is
installed while dragging. Existing reorder buttons still use `beforeClipId`.

Project interaction/rendering is isolated in `project_*.mbt` and reuses shared
palette, transport, icons, drawing helpers and semantics. No native controls or
platform symbols are required. `waveform.mbt` draws the audio envelope inside
audio clips after the host supplies a `waveform` event:

```json
{"type":"waveform","durationMs":12000,"peaks":[0,0.2,0.8,0]}
```

The duration must match the original source. Peaks are uniform source-time bins
(maximum 16,384), finite values in [0,1]; an empty array means unavailable, not
silence. The host decodes asynchronously and cancels on close. UI state caches
range maxima and maps visible pixels through source trim, actual speed and
timeline offset. Waveforms are absent from the project document, undo history
and render plan. Quiet speech uses square-root display gain only; export gain
is unchanged. This is a single-source overview, not a spectrum or unlimited
zoom detail. Multi-asset identities and higher-resolution analysis remain future
media-port work. Thumbnail generation is not implemented here.

Actual audio slowdown is currently unavailable: audio clips and linked groups
containing audio disable the 0.5× actual-speed menu item before any operation is
sent. Pointer activation and keyboard navigation honor this capability; the
accessibility label explains the restriction. Video-only or explicitly unlinked
video keeps the 0.5× choice, subject to the existing independent-audio ripple
constraints. Preview 0.5× remains available and does not modify the document.

## V2 timeline viewport and gaps

`project-zoom-out`, `project-zoom-in`, and `project-zoom-fit` change only the UI
viewport. The default shows the whole output; pan/zoom-out extent also reserves
at least one second (or 20% of output) after the larger of source/output duration,
within the seven-day limit. Committing a drag beyond output extends the project
and refits an already-fitted viewport. Maximum zoom shows three frames
(100ms), or the entire output when it is shorter. Buttons anchor the visible
playhead or viewport center. `frame.viewport` reports `{startMs,spanMs,totalMs}`.

The host forwards `scroll{x,y,deltaX,deltaY,shift,mod,precise?}` unchanged. Over
the timeline, deltaX (or deltaY if zero) pans; positive moves earlier and
negative later. Non-precise wheel units become 24 points. With mod, the same
sign zooms in/out around the pointer. Active pointer gestures ignore scrolling,
so a trim transaction retains its coordinate mapping until commit/cancel.
V1 safely ignores scroll. Playback and explicit transport navigation follow the
playhead when it leaves the viewport. ArrowLeft/Right move one output frame,
or ten with Shift. Trim keyboard steps use the same frame/viewport mapping.

Clip and gap drawing/semantics are clipped to the viewport. A clipped edge is
not a trim handle; offscreen playheads and drag candidates are not pinned to
the viewport boundary. Gaps derive from actual video intervals within output
duration, with stable `gap:<startTicks>:<endTicks>` IDs. Selecting one only
changes UI selection; Delete or the remove button requests the single core
`removeGap` operation. Other clip edits are disabled until a clip is selected.
The core can reject a gap crossed by independent audio atomically; shared UI
does not hide that audio or claim the command succeeded.

Action buttons use portable MoonBit geometry in `action_icons.mbt` and
`transport_render.mbt`. `labels.mbt` is the single source of complete action
names for accessibility and host tooltips; labels no longer determine button
width. Clip-rate and preview-rate controls use film-strip and monitor icons
respectively, followed by only the numeric rate and a chevron. Export changes
to a disabled hourglass while busy. The host uses semantic labels for hover
help, including disabled controls; shared drawing has no floating text tutorial.
