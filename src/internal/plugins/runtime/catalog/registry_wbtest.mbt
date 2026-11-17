///|
fn success(text : String) -> Json raise {
  @test_support.model_test_result(text)
}

///|
fn field(value : Json, name : String) -> Json {
  @test_support.model_test_field(value, name)
}

///|
fn entries(value : Json, group : String) -> Array[Json] {
  @test_support.model_test_items(field(field(value, "groups"), group))
}

///|
fn ids(value : Json, group : String) -> Json {
  Json::array(entries(value, group).map(entry => field(entry, "id")))
}

///|
fn update(layout : Json, command : Json) -> Json raise {
  success(
    tool_registry_update(
      Json::object({ "layout": layout, "command": command }).stringify(),
    ),
  )
}

///|
test "defaults preserve injected identities and annotation versus action behavior" {
  let result = success(tool_registry_normalize(""))
  assert_eq(entries(result, "screenshot").length(), 5)
  for (index, kind) in [(0, 1), (1, 2), (2, 3), (3, 4)] {
    let entry = entries(result, "screenshot")[index]
    assert_eq(field(entry, "kind"), Json(kind))
    assert_eq(field(entry, "type"), Json("annotation"))
    assert_eq(field(entry, "slot"), Json("tools"))
    assert_eq(field(entry, "command"), Json("capture.annotate"))
  }
  assert_eq(field(entries(result, "screenshot")[4], "action"), Json("pin"))
  assert_eq(field(entries(result, "screenshot")[4], "slot"), Json("finish"))
  assert_eq(field(result, "manifests"), Json::array([]))
}

///|
test "normalization deduplicates first wins and preserves hidden unknown identities" {
  let result = success(
    tool_registry_normalize(
      (
        #|{"version":1,"groups":{"screenshot":[
        #|{"id":"builtin.image.text","enabled":false},
        #|{"id":"future.tool","enabled":false},
        #|{"id":"builtin.image.text","enabled":true},
        #|{"id":"builtin.image.arrow","enabled":true}],
        #|"recording":[{"id":"future.tool","enabled":true},{"id":"future.recording","enabled":false}]}}
      ),
    ),
  )
  let layout = field(result, "layout")
  assert_eq(
    ids(layout, "screenshot"),
    @json.parse(
      (
        #|["builtin.image.text","future.tool","builtin.image.arrow","builtin.image.rectangle","builtin.image.cover","builtin.image.pin"]
      ),
    ),
  )
  assert_eq(
    ids(result, "screenshot"),
    @json.parse(
      (
        #|["builtin.image.text","builtin.image.arrow","builtin.image.rectangle","builtin.image.cover","builtin.image.pin"]
      ),
    ),
  )
  assert_eq(field(entries(result, "screenshot")[0], "enabled"), Json(false))
  assert_eq(field(entries(layout, "screenshot")[1], "enabled"), Json(false))
  assert_eq(ids(layout, "recording"), @json.parse("[\"future.recording\"]"))
  assert_true(entries(result, "recording").is_empty())
  assert_true(entries(result, "videoEditing").is_empty())
  assert_eq(success(tool_registry_normalize(layout.stringify())), result)
}

///|
test "new tools append after saved order and toggles preserve slots and unknown data" {
  let result = success(
    tool_registry_normalize(
      (
        #|{"version":1,"groups":{"screenshot":[
        #|{"id":"builtin.image.cover","enabled":false},
        #|{"id":"future.tool","enabled":true},
        #|{"id":"builtin.image.rectangle","enabled":true}]}}
      ),
    ),
  )
  let original = field(result, "layout")
  assert_eq(
    ids(original, "screenshot"),
    @json.parse(
      (
        #|["builtin.image.cover","future.tool","builtin.image.rectangle","builtin.image.arrow","builtin.image.text","builtin.image.pin"]
      ),
    ),
  )
  let changed = update(
    original,
    @json.parse(
      (
        #|{"type":"enabled","id":"builtin.image.arrow","enabled":false}
      ),
    ),
  )
  assert_eq(
    ids(field(changed, "layout"), "screenshot"),
    ids(original, "screenshot"),
  )
  assert_eq(field(entries(changed, "screenshot")[2], "enabled"), Json(false))
  // Updating a disabled neighbor neither removes the hidden entry nor mutates input.
  assert_eq(field(entries(original, "screenshot")[3], "enabled"), Json(true))
  let restored = update(
    field(changed, "layout"),
    @json.parse(
      (
        #|{"type":"enabled","id":"builtin.image.arrow","enabled":true}
      ),
    ),
  )
  assert_eq(field(restored, "layout"), original)
}

///|
test "moving disabled tools changes order without changing tool kind or persistent enabled state" {
  let original = field(success(tool_registry_normalize("")), "layout")
  let disabled = update(
    original,
    @json.parse(
      (
        #|{"type":"enabled","id":"builtin.image.text","enabled":false}
      ),
    ),
  )
  let moved = update(
    field(disabled, "layout"),
    @json.parse(
      (
        #|{"type":"move","group":"screenshot","id":"builtin.image.text","beforeId":"builtin.image.rectangle"}
      ),
    ),
  )
  assert_eq(
    ids(moved, "screenshot"),
    @json.parse(
      (
        #|["builtin.image.text","builtin.image.rectangle","builtin.image.arrow","builtin.image.cover","builtin.image.pin"]
      ),
    ),
  )
  assert_eq(field(entries(moved, "screenshot")[0], "kind"), Json(3))
  assert_eq(field(entries(moved, "screenshot")[0], "enabled"), Json(false))
  assert_eq(field(entries(moved, "screenshot")[1], "kind"), Json(1))
  assert_eq(field(entries(moved, "screenshot")[2], "kind"), Json(2))
  assert_eq(field(entries(moved, "screenshot")[3], "kind"), Json(4))
  assert_eq(
    success(tool_registry_normalize(field(moved, "layout").stringify())),
    moved,
  )
  let self_move = update(
    field(moved, "layout"),
    @json.parse(
      (
        #|{"type":"move","group":"screenshot","id":"builtin.image.text","beforeId":"builtin.image.text"}
      ),
    ),
  )
  assert_eq(self_move, moved)
  let last = update(
    field(moved, "layout"),
    @json.parse(
      (
        #|{"type":"move","group":"screenshot","id":"builtin.image.text","beforeId":null}
      ),
    ),
  )
  assert_eq(
    ids(last, "screenshot"),
    @json.parse(
      (
        #|["builtin.image.rectangle","builtin.image.arrow","builtin.image.cover","builtin.image.pin","builtin.image.text"]
      ),
    ),
  )
  assert_eq(field(entries(last, "screenshot")[4], "enabled"), Json(false))
  assert_eq(
    ids(original, "screenshot"),
    ids(success(tool_registry_normalize("")), "screenshot"),
  )
}

///|
test "old annotation layouts append pin and preserve its finish action through toggles" {
  let original = success(
    tool_registry_normalize(
      (
        #|{"version":1,"groups":{"screenshot":[
        #|{"id":"builtin.image.rectangle","enabled":true},
        #|{"id":"builtin.image.arrow","enabled":false},
        #|{"id":"builtin.image.text","enabled":true},
        #|{"id":"builtin.image.cover","enabled":true}],"recording":[],"videoEditing":[]}}
      ),
    ),
  )
  let pin = entries(original, "screenshot")[4]
  assert_eq(
    pin,
    @json.parse(
      (
        #|{"id":"builtin.image.pin","pluginId":"builtin.pin","target":"screenshot","type":"action","action":"pin","title":"贴图","enabled":true,"icon":"pin","slot":"finish","command":"pin","interaction":"invoke","defaultEnabled":true,"capability":0,"requires":"","payload":{}}
      ),
    ),
  )
  let disabled = update(
    field(original, "layout"),
    @json.parse(
      (
        #|{"type":"enabled","id":"builtin.image.pin","enabled":false}
      ),
    ),
  )
  assert_eq(ids(disabled, "screenshot"), ids(original, "screenshot"))
  assert_eq(field(entries(disabled, "screenshot")[4], "enabled"), Json(false))
  assert_false(entries(disabled, "screenshot")[4] is Object({ "kind": _, .. }))
  let restored = update(
    field(disabled, "layout"),
    @json.parse(
      (
        #|{"type":"enabled","id":"builtin.image.pin","enabled":true}
      ),
    ),
  )
  assert_eq(restored, original)
  assert_eq(field(entries(restored, "screenshot")[1], "enabled"), Json(false))
  for (index, kind) in [(0, 1), (1, 2), (2, 3), (3, 4)] {
    let annotation = entries(restored, "screenshot")[index]
    assert_eq(field(annotation, "type"), Json("annotation"))
    assert_eq(field(annotation, "kind"), Json(kind))
    assert_eq(field(annotation, "pluginId"), Json("builtin.image-editor"))
    assert_false(annotation is Object({ "action": _, .. }))
  }
  assert_eq(
    success(tool_registry_normalize(field(restored, "layout").stringify())),
    restored,
  )
}

///|
test "cross-group and unknown update targets are rejected without a replacement layout" {
  let layout = field(success(tool_registry_normalize("")), "layout")
  let cases = [
    (
      (
        #|{"type":"move","group":"recording","id":"builtin.image.arrow","beforeId":null}
      ),
      "invalid_group",
    ),
    (
      (
        #|{"type":"move","group":"invalid","id":"builtin.image.arrow","beforeId":null}
      ),
      "invalid_group",
    ),
    (
      (
        #|{"type":"move","group":"screenshot","id":"builtin.image.arrow","beforeId":"unknown"}
      ),
      "unknown_tool",
    ),
    (
      (
        #|{"type":"enabled","id":"unknown","enabled":true}
      ),
      "unknown_tool",
    ),
    (
      (
        #|{"type":"enabled","id":"builtin.image.arrow","enabled":1}
      ),
      "invalid_input",
    ),
    (
      (
        #|{"type":"move","group":"screenshot","id":"builtin.image.arrow"}
      ),
      "invalid_input",
    ),
    (
      (
        #|{"type":"delete","id":"builtin.image.arrow"}
      ),
      "invalid_command",
    ),
  ]
  for (command, code) in cases {
    let result = tool_registry_update(
      Json::object({ "layout": layout, "command": @json.parse(command) }).stringify(),
    )
    @test_support.expect_error(result, code)
    assert_false(@json.parse(result) is Object({ "layout": _, .. }))
  }
  assert_eq(
    success(tool_registry_normalize(layout.stringify())),
    success(tool_registry_normalize("")),
  )
}

///|
test "malformed or unsupported saved data fails closed instead of resetting user preferences" {
  for
    (saved, code) in [
      ("{", "invalid_json"),
      ("null", "invalid_input"),
      ("[]", "invalid_input"),
      ("{}", "unsupported_version"),
      ("{\"version\":2,\"groups\":{}}", "unsupported_version"),
      ("{\"version\":1,\"version\":1,\"groups\":{}}", "invalid_json"),
      ("{\"version\":1,\"groups\":[]}", "invalid_input"),
      ("{\"version\":1,\"groups\":{\"screenshot\":false}}", "invalid_input"),
      ("{\"version\":1,\"groups\":{\"screenshot\":[null]}}", "invalid_input"),
      (
        "{\"version\":1,\"groups\":{\"screenshot\":[{\"id\":\"\",\"enabled\":true}]}}",
        "invalid_input",
      ),
      (
        "{\"version\":1,\"groups\":{\"screenshot\":[{\"id\":\"future\",\"enabled\":\"false\"}]}}",
        "invalid_input",
      ),
      (
        "{\"version\":1,\"groups\":{\"recording\":[{\"id\":\"builtin.image.arrow\",\"enabled\":true}]}}",
        "invalid_group",
      ),
    ] {
    @test_support.expect_error(tool_registry_normalize(saved), code)
  }
  @test_support.expect_error(tool_registry_update("{}"), "invalid_input")
}

///|
test "maximum accepted saved layout remains reloadable after defaults are appended" {
  let unknown : Array[Json] = []
  for index in 0..<256 {
    unknown.push(
      Json::object({ "id": Json("future.\{index}"), "enabled": Json(false) }),
    )
  }
  let saved = Json::object({
    "version": Json(1),
    "groups": Json::object({ "screenshot": Json::array(unknown) }),
  })
  let normalized = success(tool_registry_normalize(saved.stringify()))
  assert_eq(entries(field(normalized, "layout"), "screenshot").length(), 261)
  assert_eq(entries(normalized, "screenshot").length(), 5)
  assert_eq(
    success(tool_registry_normalize(field(normalized, "layout").stringify())),
    normalized,
  )
  unknown.push(Json::object({ "id": Json("overflow"), "enabled": Json(false) }))
  @test_support.expect_error(
    tool_registry_normalize(saved.stringify()),
    "invalid_input",
  )
}

///|
test "an update at the serialized layout limit must still produce a reloadable layout" {
  let baseline = success(tool_registry_normalize(""))
  let layout = field(baseline, "layout")
  let rows = entries(layout, "screenshot")
  let padding : Array[Map[String, Json]] = []
  for index in 0..<70 {
    let row = { "id": Json("future.\{index}."), "enabled": Json(true) }
    padding.push(row)
    rows.push(Json::object(row))
  }
  for index, row in padding {
    let remaining = 60000 - layout.stringify().length()
    let escaped = if remaining / 6 < 145 { remaining / 6 } else { 145 }
    let plain = if escaped < 145 { remaining % 6 } else { 0 }
    row["id"] = Json(
      "future.\{index}." + "\u0001".repeat(escaped) + "x".repeat(plain),
    )
  }
  let saved = layout.stringify()
  assert_eq(saved.length(), 60000)
  let normalized = success(tool_registry_normalize(saved))
  assert_eq(field(normalized, "layout"), layout)
  let command = Json::object({
    "type": Json("enabled"),
    "id": Json("builtin.image.rectangle"),
    "enabled": Json(false),
  })
  for
    rejected in [
      tool_registry_update(
        Json::object({ "layout": layout, "command": command }).stringify(),
      ),
      tool_registry_resolve(
        Json::object({
          "layout": layout,
          "manifests": Json::array([]),
          "command": command,
        }).stringify(),
      ),
    ] {
    @test_support.expect_error(rejected, "invalid_input")
    assert_false(@json.parse(rejected) is Object({ "layout": _, .. }))
  }
  let handle = snapshot_open(fixture_contributions(), normalized.stringify(), 0)
  assert_true(handle > 0)
  assert_eq(
    snapshot_set_enabled(
      fixture_contributions(),
      handle,
      "builtin.image.rectangle",
      0,
    ),
    0,
  )
  assert_eq(snapshot_layout(handle), saved)
  assert_eq(layout.stringify(), saved)
  assert_eq(success(tool_registry_normalize(saved)), normalized)
  assert_eq(snapshot_close(handle), 1)
}
