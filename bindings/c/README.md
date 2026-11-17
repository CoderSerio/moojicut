# MoonBit C bindings

These headers describe the application's native ABI exported by `src/api_*.mbt`.
They contain declarations and small host conversion helpers, not platform UI or
product policy. They are separate from the external Wasm plugin protocol.

- Initialize the MoonBit runtime once in each process before using its objects
  or exports.
- Serialize session calls on the owning main thread. Media workers consume
  copied plans and deliver results back to that owner; they do not mutate a
  shared MoonBit session from another thread.
- Follow each header's ownership rules. Release owned returned MoonBit objects
  with `moonbit_decref`; retain references explicitly where a consuming call or
  asynchronous handoff requires it. Do not treat a numeric session handle as a
  pointer or a guarantee that a session is still active.
- Keep declarations, exported functions, generated interfaces and callers in
  sync. `test/native/core-embedding.m` exercises actual linking and ownership;
  domain fixtures verify state transitions and media behavior.

All headers are explicitly owned by `shared.bindings` in
`build/native-modules.json`. The shared pixel implementation belongs in
`platform/shared/image/pixelate.h`, outside the ABI declaration directory.
