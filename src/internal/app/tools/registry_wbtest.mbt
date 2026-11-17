///|
fn opened(capabilities : Int32) -> Int32 raise {
  let handle = tool_registry_snapshot_open(
    tool_registry_normalize(""),
    capabilities,
  )
  assert_true(handle > 0)
  handle
}

///|
fn tool_index(handle : Int32, id : String) -> Int32 {
  for index in 0..<tool_registry_snapshot_count(handle, 0) {
    if tool_registry_snapshot_text(handle, 0, index, 0) == id {
      return index
    }
  }
  abort("missing contribution")
}

///|
test "app composes extension-owned tools slots defaults and generic commands" {
  let handle = opened(31)
  assert_eq(tool_registry_snapshot_count(handle, 0), 9)
  assert_eq(tool_registry_snapshot_count(handle, 1), 0)
  for
    (index, id, icon, kind) in [
      (0, "rectangle", "rectangle", 1),
      (1, "arrow", "arrow", 2),
      (2, "text", "text", 3),
      (3, "cover", "redact", 4),
    ] {
    assert_eq(
      tool_registry_snapshot_text(handle, 0, index, 0),
      "builtin.image." + id,
    )
    assert_eq(tool_registry_snapshot_text(handle, 0, index, 3), icon)
    assert_eq(tool_registry_snapshot_value(handle, 0, index, 2), 0)
    assert_eq(tool_registry_snapshot_value(handle, 0, index, 3), kind)
  }
  let pin = tool_index(handle, "builtin.image.pin")
  assert_eq(tool_registry_snapshot_value(handle, 0, pin, 2), 1)
  assert_eq(tool_registry_snapshot_text(handle, 0, pin, 4), "pin")
  for name in ["ocr", "translate", "scroll"] {
    let index = tool_index(handle, "builtin.capture." + name)
    assert_eq(tool_registry_snapshot_value(handle, 0, index, 2), 0)
    assert_eq(tool_registry_snapshot_text(handle, 0, index, 4), name)
    assert_eq(
      tool_registry_snapshot_value(handle, 0, index, 0),
      if name == "scroll" {
        0
      } else {
        1
      },
    )
  }
  let numbered = tool_index(handle, "builtin.image.numberedRectangle")
  assert_eq(tool_registry_snapshot_value(handle, 0, numbered, 4), 3)
  assert_eq(tool_registry_snapshot_value(handle, 0, numbered, 5), 2)
  assert_eq(tool_registry_snapshot_value(handle, 0, numbered, 0), 0)
  assert_eq(
    tool_registry_snapshot_text(handle, 0, numbered, 4),
    "capture.numberedRectangle",
  )
  assert_eq(
    @json.parse(tool_registry_snapshot_text(handle, 0, numbered, 6)),
    @json.parse("{\"previewKind\":1}"),
  )
  assert_eq(tool_registry_snapshot_close(handle), 1)
}

///|
test "backend availability is separate from the persistent enabled preference" {
  let unavailable = opened(0)
  let available = opened(31)
  for name in ["ocr", "translate", "scroll"] {
    let index = tool_index(unavailable, "builtin.capture." + name)
    assert_eq(tool_registry_snapshot_value(unavailable, 0, index, 1), 0)
    assert_eq(tool_registry_snapshot_value(available, 0, index, 1), 1)
    assert_true(
      tool_registry_snapshot_text(unavailable, 0, index, 7).length() > 0,
    )
    assert_eq(tool_registry_snapshot_text(available, 0, index, 7), "")
  }
  assert_eq(
    tool_registry_snapshot_layout(unavailable),
    tool_registry_snapshot_layout(available),
  )
  assert_eq(tool_registry_snapshot_value(unavailable, 0, 0, 1), 1)
  assert_eq(tool_registry_snapshot_close(unavailable), 1)
  assert_eq(tool_registry_snapshot_close(available), 1)
}

///|
test "typed candidates preserve immutable snapshots until the host saves and publishes" {
  let original = opened(0)
  let saved = tool_registry_snapshot_layout(original)
  let candidate = tool_registry_snapshot_set_enabled(
    original, "builtin.capture.scroll", 1,
  )
  assert_true(candidate > original)
  let scroll = tool_index(candidate, "builtin.capture.scroll")
  assert_eq(tool_registry_snapshot_value(candidate, 0, scroll, 0), 1)
  assert_eq(tool_registry_snapshot_value(candidate, 0, scroll, 1), 0)
  assert_eq(tool_registry_snapshot_value(original, 0, scroll, 0), 0)
  let moved = tool_registry_snapshot_move(
    candidate, "builtin.capture.scroll", "builtin.image.rectangle",
  )
  assert_true(moved > candidate)
  assert_eq(
    tool_registry_snapshot_text(moved, 0, 0, 0),
    "builtin.capture.scroll",
  )
  assert_eq(
    tool_registry_snapshot_value(
      moved,
      0,
      tool_index(moved, "builtin.image.pin"),
      2,
    ),
    1,
  )
  assert_eq(
    tool_registry_snapshot_text(candidate, 0, 0, 0),
    "builtin.image.rectangle",
  )
  let last = tool_registry_snapshot_move(moved, "builtin.capture.scroll", "")
  assert_eq(
    tool_registry_snapshot_text(last, 0, 8, 0),
    "builtin.capture.scroll",
  )
  // A failed disk write simply discards candidates; there is no runtime-global
  // publication to roll back, and reading cannot change the original layout.
  for handle in [candidate, moved, last] {
    assert_eq(tool_registry_snapshot_close(handle), 1)
  }
  assert_eq(tool_registry_snapshot_layout(original), saved)
  let reloaded = tool_registry_snapshot_open(tool_registry_normalize(saved), 0)
  assert_true(reloaded > original)
  assert_eq(tool_registry_snapshot_close(reloaded), 1)
  assert_eq(tool_registry_snapshot_set_enabled(original, "unknown", 1), 0)
  assert_eq(
    tool_registry_snapshot_set_enabled(original, "builtin.image.text", 2),
    0,
  )
  assert_eq(
    tool_registry_snapshot_move(original, "builtin.image.text", "unknown"),
    0,
  )
  assert_eq(tool_registry_snapshot_layout(original), saved)
  assert_eq(tool_registry_snapshot_close(original), 1)
}

///|
test "snapshots reconstruct trusted contributions and reject forged execution metadata" {
  let original = tool_registry_normalize("")
  for
    (key, value) in [
      ("kind", @json.Json(4)),
      ("command", @json.Json("shell.exec")),
      ("slot", @json.Json("finish")),
      ("icon", @json.Json("fake")),
      ("title", @json.Json("fake")),
      ("capability", @json.Json(0)),
    ] {
    let root = @json.parse(original)
    let groups = @test_support.model_test_field(root, "groups")
    let entries = @test_support.model_test_items(
      @test_support.model_test_field(groups, "screenshot"),
    )
    let index = if key == "capability" { 5 } else { 0 }
    match entries[index] {
      Object(fields) => fields[key] = value
      _ => abort("descriptor")
    }
    assert_eq(tool_registry_snapshot_open(root.stringify(), 31), 0)
  }
  for text in ["", "{", "{}", "{\"ok\":false}", "{\"ok\":true,\"ok\":true}"] {
    assert_eq(tool_registry_snapshot_open(text, 0), 0)
  }
  assert_eq(tool_registry_snapshot_open(original, -1), 0)
}

///|
test "closed invalid and exhausted snapshot handles fail without changing live snapshots" {
  let first = opened(0)
  assert_eq(tool_registry_snapshot_close(first), 1)
  assert_eq(tool_registry_snapshot_close(first), 0)
  assert_eq(tool_registry_snapshot_count(first, 0), -1)
  assert_eq(tool_registry_snapshot_value(first, 0, 0, 0), -1)
  assert_eq(tool_registry_snapshot_text(first, 0, 0, 0), "")
  assert_eq(tool_registry_snapshot_layout(first), "")
  assert_eq(tool_registry_snapshot_move(first, "builtin.image.text", ""), 0)
  let next = opened(0)
  assert_true(next > first)
  for
    (group, index, key) in [
      (-1, 0, 0),
      (3, 0, 0),
      (0, -1, 0),
      (0, 9, 0),
      (0, 0, 99),
    ] {
    assert_eq(tool_registry_snapshot_value(next, group, index, key), -1)
    assert_eq(tool_registry_snapshot_text(next, group, index, key), "")
  }
  assert_eq(tool_registry_snapshot_close(next), 1)
  let handles : Array[Int32] = []
  while true {
    let handle = tool_registry_snapshot_open(tool_registry_normalize(""), 0)
    if handle == 0 {
      break
    }
    handles.push(handle)
  }
  assert_eq(handles.length(), 64)
  assert_eq(
    tool_registry_snapshot_set_enabled(handles[0], "builtin.image.text", 0),
    0,
  )
  for handle in handles {
    assert_eq(tool_registry_snapshot_close(handle), 1)
  }
}

///|
test "typed and JSON moves reject cross-slot anchors without changing the source snapshot" {
  let original = opened(31)
  let saved = tool_registry_snapshot_layout(original)
  for
    (id, before) in [
      ("builtin.image.rectangle", "builtin.image.pin"),
      ("builtin.image.pin", "builtin.image.rectangle"),
    ] {
    assert_eq(tool_registry_snapshot_move(original, id, before), 0)
    let command = @json.Json::object({
      "type": @json.Json("move"),
      "group": @json.Json("screenshot"),
      "id": @json.Json(id),
      "beforeId": @json.Json(before),
    })
    let update = tool_registry_update(
      @json.Json::object({ "layout": @json.parse(saved), "command": command }).stringify(),
    )
    let resolve = tool_registry_resolve(
      @json.Json::object({
        "layout": @json.parse(saved),
        "manifests": @json.Json::array([]),
        "command": command,
      }).stringify(),
    )
    for rejected in [update, resolve] {
      @test_support.expect_error(rejected, "invalid_slot")
      assert_false(@json.parse(rejected) is Object({ "layout": _, .. }))
    }
    assert_eq(tool_registry_snapshot_layout(original), saved)
  }
  // A null/empty anchor still appends within the group's persisted order;
  // toolbar rendering partitions that order into the two slots.
  let appended = tool_registry_snapshot_move(original, "builtin.image.pin", "")
  assert_true(appended > original)
  assert_eq(tool_registry_snapshot_text(appended, 0, 8, 0), "builtin.image.pin")
  assert_eq(tool_registry_snapshot_value(appended, 0, 8, 2), 1)
  assert_eq(tool_registry_snapshot_layout(original), saved)
  assert_eq(tool_registry_snapshot_close(appended), 1)
  assert_eq(tool_registry_snapshot_close(original), 1)
}

///|
test "adding built-ins preserves a previously full layout across reload and edits" {
  let entries : Array[@json.Json] = []
  for id in ["pin", "arrow", "rectangle", "text", "cover"] {
    entries.push(
      @json.Json::object({
        "id": @json.Json("builtin.image." + id),
        "enabled": @json.Json(id != "pin" && id != "arrow"),
      }),
    )
  }
  for index in 0..<251 {
    entries.push(
      @json.Json::object({
        "id": @json.Json("future.\{index}"),
        "enabled": @json.Json(false),
      }),
    )
  }
  let old = @json.Json::object({
    "version": @json.Json(1),
    "groups": @json.Json::object({ "screenshot": @json.Json::array(entries) }),
  })
  let normalized = tool_registry_normalize(old.stringify())
  let original = tool_registry_snapshot_open(normalized, 31)
  assert_true(original > 0)
  let saved = tool_registry_snapshot_layout(original)
  let layout = @json.parse(saved)
  let rows = @test_support.model_test_items(
    @test_support.model_test_field(
      @test_support.model_test_field(layout, "groups"),
      "screenshot",
    ),
  )
  assert_eq(rows.length(), 260)
  for index in 0..<256 {
    assert_eq(rows[index], entries[index])
  }
  assert_eq(tool_registry_normalize(saved), normalized)
  assert_eq(tool_registry_snapshot_text(original, 0, 0, 0), "builtin.image.pin")
  assert_eq(tool_registry_snapshot_value(original, 0, 0, 0), 0)
  assert_eq(tool_registry_snapshot_value(original, 0, 1, 0), 0)
  let enabled = tool_registry_snapshot_set_enabled(
    original, "builtin.image.arrow", 1,
  )
  assert_true(enabled > original)
  let updated = tool_registry_update(
    @json.Json::object({
      "layout": @json.parse(tool_registry_snapshot_layout(enabled)),
      "command": @json.Json::object({
        "type": @json.Json("enabled"),
        "id": @json.Json("builtin.capture.ocr"),
        "enabled": @json.Json(false),
      }),
    }).stringify(),
  )
  let reloaded = tool_registry_snapshot_open(updated, 31)
  assert_true(reloaded > enabled)
  let reloaded_rows = @test_support.model_test_items(
    @test_support.model_test_field(
      @test_support.model_test_field(
        @json.parse(tool_registry_snapshot_layout(reloaded)),
        "groups",
      ),
      "screenshot",
    ),
  )
  assert_eq(reloaded_rows.length(), 260)
  for index in 5..<256 {
    assert_eq(reloaded_rows[index], entries[index])
  }
  assert_eq(tool_registry_snapshot_text(reloaded, 0, 0, 0), "builtin.image.pin")
  assert_eq(tool_registry_snapshot_value(reloaded, 0, 0, 0), 0)
  assert_eq(tool_registry_snapshot_value(reloaded, 0, 1, 0), 1)
  assert_eq(
    tool_registry_snapshot_value(
      reloaded,
      0,
      tool_index(reloaded, "builtin.capture.ocr"),
      0,
    ),
    0,
  )
  assert_eq(tool_registry_snapshot_layout(original), saved)
  for handle in [original, enabled, reloaded] {
    assert_eq(tool_registry_snapshot_close(handle), 1)
  }
}
