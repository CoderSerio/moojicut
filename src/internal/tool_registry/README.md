# Built-in tool registry

This package owns the built-in tool catalog and the user's ordered layout. It
does not own feature lifecycle, editor documents, annotation history, live
gestures, or per-tool style sessions.

The screenshot catalog contains four annotation tools and the pin action:

| Stable ID | Existing image/style kind |
| --- | --- |
| `builtin.image.rectangle` | 1 |
| `builtin.image.arrow` | 2 |
| `builtin.image.text` | 3 |
| `builtin.image.cover` | 4 |
| `builtin.image.pin` | None: action `pin` |

The annotation tools belong to `builtin.image-editor`; the pin action belongs
to `builtin.pin`. Selection and workflow controls remain host controls. The
`recording` and `videoEditing` catalogs are currently empty. IDs, action names,
and annotation kinds remain stable when display order changes. Loading an older
four-tool layout appends pin, enabled, after all saved entries.

The macOS screenshot toolbar presents two semantic groups. Annotation and user
tools retain their saved relative order on the left, with OCR/translation and
history actions. Pin appears once on the right, before cancel/confirm; its saved
position does not move it across that boundary. Its enable switch still applies.
The persisted catalog is unchanged, so older hosts can continue reading it.

Installed user tools enter the same layout through `tool_registry_resolve`.
Their validated identities use `user.<pluginId>/<toolId>`, and their descriptors
have `type:"action"`, `action:"run"`, and a package-local `toolId`, with no
annotation `kind`. Manifest validation and typed user tools live in
`../plugin_protocol`; the registry does not reinterpret their capability rules.

## JSON boundary

`tool_registry_normalize(savedJson)` accepts the saved layout object as JSON.
Pass an empty string for defaults. A valid saved layout uses this shape:

```json
{
  "version": 1,
  "groups": {
    "screenshot": [{"id": "builtin.image.text", "enabled": false}],
    "recording": [],
    "videoEditing": []
  }
}
```

Missing known groups are treated as empty. Missing built-ins are appended,
enabled, after saved entries. The first occurrence of each ID wins. Unknown IDs
retain their group, position, and enabled preference, but never appear in the
available catalog. A known built-in saved in the wrong group is rejected.

`tool_registry_update(requestJson)` accepts a layout object and one command:

```json
{"layout": {}, "command": {"type": "enabled", "id": "builtin.image.text", "enabled": false}}
```

```json
{"layout": {}, "command": {"type": "move", "group": "screenshot", "id": "builtin.image.text", "beforeId": "builtin.image.rectangle"}}
```

Replace the example `layout` with a complete saved layout. `beforeId: null`
moves to the end, including after hidden unknown entries. Moving before oneself
is a no-op. Update targets must be known built-ins; cross-group moves fail.

Both functions return `{ok:true,layout,groups}`. Each catalog entry in `groups`
contains `id`, `pluginId`, `target`, `type`, `title`, and `enabled`.
`type:"annotation"` entries also contain their existing `kind` (1–4).
`type:"action"` entries contain `action:"pin"` and have no `kind` field. Pin is
never passed to image annotation or style APIs. Disabled tools remain in both
outputs so settings can retain their position. Hosts persist **layout**, render
**groups**, and dispatch by stable ID and descriptor type rather than array
index. Native function declarations are in
`native/shared/tool_registry.h`.

## Installed-package resolution

`tool_registry_resolve` accepts
`{layout:null|<saved layout>,manifests:[<manifest objects>],command?:<command>}`.
Null layout starts from defaults; commands use the same enabled/move shape as
above. The response shape is unchanged. The catalog accepts at most 64 user
tools total, with at most 16 per package. Duplicate package IDs are errors.

Existing saved order and enabled preferences always win. Missing built-ins are
appended first, then new user tools in manifest-array and declaration order.
Hosts should supply a stable installed-package order. New tools start enabled;
this never invokes them automatically. Removed tools remain hidden unknown
entries, retaining their preference and position for reinstall. A package
upgrade can change titles without changing identities or saved preferences.
Commands cannot target a tool absent from the current installed catalog.

The older normalize/update exports remain available for built-in-only callers.
A host with installed packages must use resolve for **all** layout reads and
updates so that enabled and reorder commands can find user tools. The new
export is declared in `native/shared/plugin_protocol.h`.

Invalid input returns `{ok:false,error:{code,message}}`, without a replacement
layout. Hosts must not overwrite saved preferences after an error. JSON parsing
rejects duplicate object keys and requests over 64 KiB. Saved IDs have 1–160
characters; input and normalized layouts have at most 256 entries. Normalized
layout JSON is limited to 60,000 characters, leaving room for an update command
inside the shared request limit. Accepted layouts remain reloadable after
defaults are appended.

Persist successful changes before applying them to live controls. Existing
`feature_runtime` gates remain authoritative. Updating the layout must not
recreate image/video sessions or style banks, discard existing annotations, or
change the state of an ongoing recording.
