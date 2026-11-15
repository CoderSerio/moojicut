///|
fn binding_fixture(saved : Json, command? : Json, external? : Json) -> String {
  let request : Map[String, Json] = {
    "order": ["capture", "record", "zoom"],
    "global": ["capture", "record"],
    "defaults": {
      "capture": { "keyCode": 18, "modifiers": 12, "keyLabel": "1" },
      "record": { "keyCode": 19, "modifiers": 12, "keyLabel": "2" },
      "zoom": { "keyCode": 24, "modifiers": 0, "keyLabel": "+" },
    },
    "saved": saved,
  }
  if command is Some(value) {
    request["command"] = value
  }
  if external is Some(value) {
    request["external"] = value
  }
  shortcut_bindings_resolve(Json::object(request).stringify())
}

///|
test "shortcut preference recovery preserves disabled and first-wins binding" {
  let output = binding_fixture({
    "capture": null,
    "record": { "keyCode": 24, "modifiers": 8, "keyLabel": "+" },
    "zoom": { "keyCode": 24, "modifiers": 8, "keyLabel": "different label" },
  })
  @test_support.expect_json(
    output, "{\"ok\":true,\"bindings\":{\"capture\":null,\"record\":{\"keyCode\":24,\"modifiers\":8,\"keyLabel\":\"+\"},\"zoom\":null}}",
  )
  let defaults = binding_fixture({})
  assert_eq(
    binding_fixture({
      "record": { "keyCode": 1.5, "modifiers": 12, "keyLabel": "A" },
    }),
    defaults,
  )
  assert_eq(
    binding_fixture({
      "record": { "keyCode": true, "modifiers": 12, "keyLabel": "A" },
    }),
    defaults,
  )
  assert_eq(
    binding_fixture({
      "record": { "keyCode": 1, "modifiers": 4, "keyLabel": "A" },
    }),
    defaults,
  )
}

///|
test "shortcut edits prevent duplicate and global typing interception" {
  @test_support.expect_error(
    binding_fixture({}, command={
      "action": "record",
      "binding": { "keyCode": 18, "modifiers": 12, "keyLabel": "1" },
    }),
    "duplicate",
  )
  for flags in [0, 4, 16] {
    @test_support.expect_error(
      binding_fixture({}, command={
        "action": "record",
        "binding": { "keyCode": 0, "modifiers": Json(flags), "keyLabel": "A" },
      }),
      "invalid_shortcut",
    )
  }
  @test_support.expect_error(
    binding_fixture({}, command={ "action": "missing", "binding": null }),
    "unknown_action",
  )
  let cleared = @test_support.model_test_result(
    binding_fixture({}, command={ "action": "record", "binding": null }),
  )
  assert_eq(
    @test_support.model_test_field(
      @test_support.model_test_field(cleared, "bindings"),
      "record",
    ),
    Json::null(),
  )
  // Key zero is an actual physical key, not the disabled sentinel.
  let local_result = @test_support.model_test_result(
    binding_fixture({}, command={
      "action": "zoom",
      "binding": { "keyCode": 0, "modifiers": 0, "keyLabel": "A" },
    }),
  )
  assert_eq(
    @test_support.model_test_field(
      @test_support.model_test_field(
        @test_support.model_test_field(local_result, "bindings"),
        "zoom",
      ),
      "keyCode",
    ),
    Json(0),
  )
}

///|
test "global pin chords respect external capture bindings but local pins do not" {
  let external : Json = {
    "screenshot": { "keyCode": 0, "modifiers": 8, "keyLabel": "A" },
  }
  @test_support.expect_error(
    binding_fixture(
      {},
      command={
        "action": "record",
        "binding": { "keyCode": 0, "modifiers": 8, "keyLabel": "A" },
      },
      external~,
    ),
    "external_duplicate",
  )
  let output = binding_fixture(
    {},
    command={
      "action": "zoom",
      "binding": { "keyCode": 0, "modifiers": 8, "keyLabel": "A" },
    },
    external~,
  )
  ignore(@test_support.model_test_result(output))
}
