# User plugin protocol v1

This package validates data and constructs typed records. It does not load Wasm,
read files, grant capabilities, invoke plugins, or create windows. The native
host owns those operations and the existing feature/invocation lifecycle.

## Manifest

```json
{
  "apiVersion": 1,
  "pluginId": "com.example.capture-info",
  "name": "Capture Info",
  "version": "1.0.0",
  "entry": "plugin.wasm",
  "runtime": "extism-1",
  "capabilities": ["capture.metadata", "result.text"],
  "tools": [
    {"toolId": "describe", "title": "截图信息", "target": "screenshot", "action": "run"},
    {"toolId": "copy-size", "title": "复制尺寸", "target": "screenshot", "action": "run"}
  ]
}
```

All listed fields are required. Unknown fields are rejected at the manifest,
tool, capture, and output levels. No network, file, pixel, clipboard-write, or
custom-UI capability exists in this protocol.

- `pluginId`: at most 96 ASCII characters, at least two dot-separated segments;
  each segment starts with a lowercase letter, contains only lowercase letters,
  digits and hyphens, and does not end in a hyphen. IDs beginning with `builtin`
  are reserved.
- `toolId`: the same segment syntax, at most 48 characters, unique within a
  package. A package declares 1–16 tools.
- `version`: three numeric components `X.Y.Z`, each 1–9 digits, without leading
  zeros except `0`. Prerelease and build suffixes are not supported in v1.
- `name` and tool/result `title`: 1–80 UTF-16 code units, not blank and without
  ASCII control characters. Unicode display text is supported.
- `entry`, `runtime`, `target`, and `action` must match the example. Capabilities
  contain exactly the two distinct names shown; their order is normalized.

The global tool identity is `user.<pluginId>/<toolId>` (at most 150 characters).
It is stable across package upgrades. A user catalog descriptor contains `id`,
`pluginId`, local `toolId`, `title`, `target:"screenshot"`, `type:"action"`,
`action:"run"`, and `enabled`. It has no annotation `kind`.

## Invocation and result

Only an explicit click on a currently available user tool starts an invocation.
The host prepares this request through MoonBit and sends it to the plugin:

The fixed Extism export is `mooji_run` with signature `() -> i32`. The manifest's
`action:"run"` is a catalog action, not the exported function name.

```json
{
  "apiVersion": 1,
  "invocationId": "unique-host-invocation-id",
  "toolId": "describe",
  "capture": {"width": 1920, "height": 1080, "format": "png", "revision": 7}
}
```

`toolId` is local to the selected package. Width and height are integers in
1–32768; revision is an integer in 0–9007199254740990. The format is always `png`.
Only metadata for the current capture is supplied; there are no bytes or paths.
`invocationId` is 1–128 printable ASCII characters without spaces, assigned by
the host rather than by the plugin.

```json
{
  "apiVersion": 1,
  "invocationId": "unique-host-invocation-id",
  "kind": "text",
  "title": "截图信息",
  "text": "1920 × 1080"
}
```

The result must echo the exact invocation ID. Text is nonempty and at most
32,768 **UTF-8 bytes**; multiline text is supported. It is plain result data,
never HTML or a command. The native result window provides the user-operated
copy button; even a tool named “复制尺寸” must not write the clipboard itself.

## Native boundary

All four exports in `native/shared/plugin_protocol.h` use the owning MoonBit
String C ABI and return structured JSON errors without replacement state.

| Function | Input | Successful response |
| --- | --- | --- |
| `plugin_manifest_validate` | Manifest object | `{ok:true,manifest,tools}` |
| `plugin_request_prepare` | `{manifest,toolId:<global>,invocationId,capture}` | `{ok:true,request:<plugin request>}` |
| `plugin_output_validate` | `{invocationId:<expected>,output:<raw output object>}` | `{ok:true,result:<validated output>}` |
| `tool_registry_resolve` | `{layout:null|<saved>,manifests:[...],command?:...}` | `{ok:true,layout,groups}` |

Parsing rejects duplicate JSON keys and nesting deeper than 16. UTF-8 input
budgets are 64 KiB for manifest validation, 128 KiB for request preparation,
256 KiB for registry resolution, and 512 KiB for output validation envelopes.

The host must cap **raw plugin output** at 256 KiB before creating its envelope.
Embed that original JSON object verbatim: parsing and re-encoding it in native
code would erase duplicate keys before MoonBit could reject them. MoonBit also
checks the canonical output JSON against 256 KiB. The larger envelope budget
allows legal escaped text and envelope metadata; the decoded text is still
limited to 32 KiB UTF-8.

Errors are `{ok:false,error:{code,message}}`. Codes include `invalid_json`,
`invalid_input`, `invalid_manifest`, `invalid_request`, `invalid_output`,
`unsupported_api_version`, `unsupported_capability`, `unknown_tool`,
`invocation_mismatch`, and `limit_exceeded`; the registry additionally reports
`invalid_catalog` and its existing layout/command errors.

Matching an invocation ID does not authorize stale effects. Before displaying a
validated result, the host still checks that the call is current, uncancelled,
and belongs to the active capture revision. This package deliberately contains
no second enable/disable state machine.
