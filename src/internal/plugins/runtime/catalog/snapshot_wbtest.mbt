///|
test "generic runtime accepts a caller-owned recording command without capture knowledge" {
  let payload = Json::object({
    "control": Json("toggle"),
    "futureOption": Json(7),
  })
  let tools : Array[@plugin_protocol.ToolContribution] = [
    {
      id: "fixture.recording.marker",
      plugin_id: "fixture.recording",
      target: "recording",
      title: "Marker",
      icon: "marker",
      slot: "tools",
      behavior: "command",
      command: "recording.addMarker",
      interaction: "invoke",
      annotation_kind: 0,
      default_enabled: false,
      capability: 64,
      requires: "markerBackend",
      payload,
    },
  ]
  let response = normalize(tools, "")
  let original = snapshot_open(tools, response, 64)
  assert_true(original > 0)
  assert_eq(snapshot_count(original, 0), 0)
  assert_eq(snapshot_count(original, 1), 1)
  assert_eq(snapshot_value(original, 1, 0, 0), 0)
  assert_eq(snapshot_value(original, 1, 0, 1), 1)
  assert_eq(snapshot_text(original, 1, 0, 4), "recording.addMarker")
  let enabled = snapshot_set_enabled(
    tools, original, "fixture.recording.marker", 1,
  )
  assert_true(enabled > original)
  assert_eq(snapshot_value(enabled, 1, 0, 0), 1)
  assert_eq(snapshot_value(original, 1, 0, 0), 0)
  let before = snapshot_text(original, 1, 0, 6)
  match payload {
    Object(fields) => fields["futureOption"] = Json(99)
    _ => abort("payload")
  }
  assert_eq(snapshot_text(original, 1, 0, 6), before)
  assert_eq(snapshot_text(enabled, 1, 0, 6), before)
  assert_eq(snapshot_close(original), 1)
  assert_eq(snapshot_close(enabled), 1)
}

///|
test "typed user candidates retain validated installed metadata and capability mask" {
  let tools = fixture_contributions()
  let response = resolve_catalog(
    tools,
    Json::object({
      "layout": Json::null(),
      "manifests": Json::array([
        user_manifest("com.example.snapshot", ["summary"]),
      ]),
    }).stringify(),
  )
  let original = snapshot_open(tools, response, 16)
  assert_true(original > 0)
  assert_eq(snapshot_count(original, 0), 6)
  assert_eq(snapshot_text(original, 0, 5, 4), "plugin.run")
  assert_eq(snapshot_text(original, 0, 5, 8), "summary")
  let saved = snapshot_layout(original)
  assert_eq(
    snapshot_move(
      tools, original, "user.com.example.snapshot/summary", "builtin.image.pin",
    ),
    0,
  )
  assert_eq(
    snapshot_move(
      tools, original, "builtin.image.pin", "user.com.example.snapshot/summary",
    ),
    0,
  )
  assert_eq(snapshot_layout(original), saved)
  let rejected = resolve_catalog(
    tools,
    Json::object({
      "layout": @json.parse(saved),
      "manifests": Json::array([
        user_manifest("com.example.snapshot", ["summary"]),
      ]),
      "command": Json::object({
        "type": Json("move"),
        "group": Json("screenshot"),
        "id": Json("user.com.example.snapshot/summary"),
        "beforeId": Json("builtin.image.pin"),
      }),
    }).stringify(),
  )
  @test_support.expect_error(rejected, "invalid_slot")
  assert_eq(snapshot_layout(original), saved)
  let disabled = snapshot_set_enabled(
    tools, original, "user.com.example.snapshot/summary", 0,
  )
  let moved = snapshot_move(
    tools, disabled, "user.com.example.snapshot/summary", "builtin.image.rectangle",
  )
  assert_true(disabled > original && moved > disabled)
  assert_eq(snapshot_value(original, 0, 5, 0), 1)
  assert_eq(snapshot_value(moved, 0, 0, 0), 0)
  assert_eq(snapshot_value(moved, 0, 0, 1), 1)
  assert_eq(snapshot_text(moved, 0, 0, 1), "com.example.snapshot")
  assert_eq(snapshot_text(moved, 0, 0, 4), "plugin.run")
  assert_eq(snapshot_text(moved, 0, 0, 8), "summary")
  for handle in [original, disabled, moved] {
    assert_eq(snapshot_close(handle), 1)
  }
}
