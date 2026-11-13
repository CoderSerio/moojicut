# Mooncap core

The editing and recording policy is implemented in MoonBit. The Electron host owns capture permissions, media streams, codecs, image drawing, and file output. No media bytes cross this core API.

## Build and test

From the repository root:

```sh
node scripts/build-core.mjs --test
```

The script uses `.tools/moon/bin/moon` when present, then `MOON_HOME`, then `moon` on `PATH`. It reads the compiler's artifact report and copies the generated ES module to `dist/core/core.mjs`. Importing that file initializes the core; no separate runtime initialization is needed.

The implementation was compiled and tested with `moon 0.1.20261104` and `moonc v0.10.20+65efd5b93`. Current official configuration and exports documentation:

- https://docs.moonbitlang.com/en/stable/toolchain/moon/package.html
- https://docs.moonbitlang.com/en/stable/language/ffi.html
- https://www.moonbitlang.com/download/

For an isolated installation, place the official platform toolchain archive under `.tools/moon` and the matching `core` archive under `.tools/moon/lib`, set `MOON_HOME` to that absolute directory, then run `moon -C "$MOON_HOME/lib/core" bundle --target js`. Use matching toolchain/core versions and verify the published toolchain SHA-256. The ordinary Unix installer accepts `MOON_HOME`, but can also edit shell profiles and use a temporary archive under the user's home directory; it was not run for this checkout.

## JavaScript API

```js
import { edit_plan, crop_rect, recording_transition, export_profile } from '../dist/core/core.mjs';

const plan = JSON.parse(edit_plan(JSON.stringify({
  durationMs: 10_000,
  trim: { startMs: 1_000, endMs: 9_000 },
  cut: { startMs: 3_000, endMs: 5_000 },
})));
```

The three request-object functions accept JSON strings. `recording_transition` accepts two strings. All return a JSON string with either `ok: true` or `{ ok: false, error: { code, message } }`.

### `edit_plan(request)`

Input: `{ durationMs, trim: { startMs, endMs }, cut?: { startMs, endMs } | null }`.

Output: `{ ok: true, segments: [{ sourceStartMs, sourceEndMs, outputStartMs, outputEndMs }], outputDurationMs }`.

Time values are integer milliseconds. Duration must be 1–604800000 ms (seven days). Both intervals must lie within the source and have `startMs < endMs`. The optional cut removes its intersection with the trim. Retained source intervals are joined without gaps on the output timeline. An entirely removed selection returns `empty_output`. Interval ends are exclusive.

### `crop_rect(request)`

Input: `{ sourceWidth, sourceHeight, x, y, width, height }` in integer **source pixels**, not preview coordinates.

Output: `{ ok: true, rect: { x, y, width, height } }`.

Source and selection sizes must be 1–32768 pixels; selection origins must be -32768–32768. The result is the intersection with the source image. A non-overlapping selection returns `empty_crop`. The host converts and rounds pointer coordinates before calling this function.

### `recording_transition(state, event)`

Output: `{ ok: true, state }`.

| Current state | Event | Next state |
| --- | --- | --- |
| idle, ready, error | start | requesting |
| requesting | capture_started | recording |
| recording | pause | paused |
| paused | resume | recording |
| recording, paused | stop | stopping |
| stopping | complete | ready |
| requesting, recording, paused, stopping | fail | error |
| idle, ready, error | reset | idle |

Other transitions return `invalid_transition`. The host must stop and release its media resources; a state transition does not do that work. Host callbacks should be associated with the active recording session so stale events cannot affect a later session.

### `export_profile(request)`

Input: `{ durationMs, width, height, preset: "share" | "quality", hasAudio: boolean, targetBytes?: number }`. Dimensions are 1–32768 pixels; time uses the same seven-day bound. Optional target size must be an integer between 1 byte and 1 TiB.

Output: `{ ok: true, videoBitrateKbps, audioBitrateKbps, maxWidth, estimatedBytes, fitsTarget }`.

- `share`: width limit 1280, audio 96 Kbit/s when enabled, default target 25 MiB. Pixel-based video bitrate is reduced to fit the estimated budget, down to 250 Kbit/s.
- `quality`: width limit 1920, audio 160 Kbit/s when enabled, pixel-based video bitrate. An optional target is checked but does not reduce quality.
- The host must not upscale smaller sources. Bitrate estimates scale the source proportionally to the width limit.
- `estimatedBytes` includes a 5% allowance for mux overhead. `fitsTarget: false` reports an insufficient budget; actual encoded size can still differ when it is true. Without a quality target, `fitsTarget` is true because no limit was requested.
- These profiles estimate a 30 fps workload. They do not enforce encoder support, frame rate, or a hard file-size limit.

Malformed JSON, duplicate object keys, fractional values, non-finite numbers, and out-of-range values produce structured errors. JSON strings are bounded to 65536 UTF-16 code units and nesting depth 16. Unknown fields are ignored for forward-compatible host requests.
