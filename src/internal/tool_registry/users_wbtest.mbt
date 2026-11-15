///|
fn user_manifest(plugin_id : String, tool_ids : Array[String]) -> Json {
  Json::object({
    "apiVersion": Json(1),
    "pluginId": Json(plugin_id),
    "name": Json("Example"),
    "version": Json("1.0.0"),
    "entry": Json("plugin.wasm"),
    "runtime": Json("extism-1"),
    "capabilities": Json::array([Json("capture.metadata"), Json("result.text")]),
    "tools": Json::array(
      tool_ids.map(id => {
        Json::object({
          "toolId": Json(id),
          "title": Json(id),
          "target": Json("screenshot"),
          "action": Json("run"),
        })
      }),
    ),
  })
}

///|
fn resolve(
  layout : Json,
  manifests : Array[Json],
  command : Json?,
) -> Json raise {
  let request : Map[String, Json] = {
    "layout": layout,
    "manifests": Json::array(manifests),
  }
  if command is Some(value) {
    request["command"] = value
  }
  success(tool_registry_resolve(Json::object(request).stringify()))
}

///|
test "dynamic catalog appends multiple packages and routes same local names without collisions" {
  let manifests = [
    user_manifest("com.example.first", ["describe", "summary"]),
    user_manifest("com.example.second", ["describe"]),
  ]
  let result = resolve(Json::null(), manifests, None)
  assert_eq(
    ids(result, "screenshot"),
    @json.parse(
      (
        #|["builtin.image.rectangle","builtin.image.arrow","builtin.image.text","builtin.image.cover","builtin.image.pin","user.com.example.first/describe","user.com.example.first/summary","user.com.example.second/describe"]
      ),
    ),
  )
  assert_eq(
    entries(result, "screenshot")[5],
    @json.parse(
      (
        #|{"id":"user.com.example.first/describe","pluginId":"com.example.first","toolId":"describe","title":"describe","target":"screenshot","type":"action","action":"run","enabled":true}
      ),
    ),
  )
  assert_eq(
    field(entries(result, "screenshot")[7], "pluginId"),
    Json("com.example.second"),
  )
  assert_false(entries(result, "screenshot")[5] is Object({ "kind": _, .. }))
  assert_true(entries(result, "recording").is_empty())
  assert_true(entries(result, "videoEditing").is_empty())
  assert_eq(resolve(field(result, "layout"), manifests, None), result)
}

///|
test "user tool removal and reinstall preserve disabled positions while new tools append" {
  let manifests = [
    user_manifest("com.example.capture", ["describe", "summary"]),
  ]
  let original = resolve(Json::null(), manifests, None)
  let moved = resolve(
    field(original, "layout"),
    manifests,
    Some(
      @json.parse(
        (
          #|{"type":"move","group":"screenshot","id":"user.com.example.capture/summary","beforeId":"builtin.image.arrow"}
        ),
      ),
    ),
  )
  let disabled = resolve(
    field(moved, "layout"),
    manifests,
    Some(
      @json.parse(
        (
          #|{"type":"enabled","id":"user.com.example.capture/summary","enabled":false}
        ),
      ),
    ),
  )
  assert_eq(
    field(entries(disabled, "screenshot")[1], "id"),
    Json("user.com.example.capture/summary"),
  )
  assert_eq(field(entries(disabled, "screenshot")[1], "enabled"), Json(false))
  assert_eq(field(entries(disabled, "screenshot")[2], "kind"), Json(2))
  let removed = resolve(field(disabled, "layout"), [], None)
  assert_eq(entries(removed, "screenshot").length(), 5)
  assert_eq(field(removed, "layout"), field(disabled, "layout"))
  let recovered = resolve(field(removed, "layout"), manifests, None)
  assert_eq(recovered, disabled)
  let updated = resolve(
    field(removed, "layout"),
    [user_manifest("com.example.capture", ["summary", "new-tool"])],
    None,
  )
  assert_eq(field(entries(updated, "screenshot")[1], "enabled"), Json(false))
  assert_eq(
    field(entries(updated, "screenshot")[6], "id"),
    Json("user.com.example.capture/new-tool"),
  )
  assert_eq(field(entries(updated, "screenshot")[6], "enabled"), Json(true))
  assert_eq(
    ids(field(updated, "layout"), "screenshot"),
    @json.parse(
      (
        #|["builtin.image.rectangle","user.com.example.capture/summary","builtin.image.arrow","builtin.image.text","builtin.image.cover","builtin.image.pin","user.com.example.capture/describe","user.com.example.capture/new-tool"]
      ),
    ),
  )
  let enabled = resolve(
    field(recovered, "layout"),
    manifests,
    Some(
      @json.parse(
        (
          #|{"type":"enabled","id":"user.com.example.capture/summary","enabled":true}
        ),
      ),
    ),
  )
  assert_eq(ids(enabled, "screenshot"), ids(recovered, "screenshot"))
  assert_eq(field(entries(enabled, "screenshot")[1], "enabled"), Json(true))
}

///|
test "newly installed known identity reuses retained unknown preferences and keeps other unknown entries" {
  let saved = @json.parse(
    (
      #|{"version":1,"groups":{"screenshot":[{"id":"user.com.example.capture/describe","enabled":false},{"id":"future.unknown","enabled":true}]}}
    ),
  )
  let result = resolve(
    saved,
    [user_manifest("com.example.capture", ["describe"])],
    None,
  )
  assert_eq(
    field(entries(result, "screenshot")[0], "id"),
    Json("user.com.example.capture/describe"),
  )
  assert_eq(field(entries(result, "screenshot")[0], "enabled"), Json(false))
  assert_eq(
    field(entries(field(result, "layout"), "screenshot")[1], "id"),
    Json("future.unknown"),
  )
  assert_eq(entries(result, "screenshot").length(), 6)
  assert_eq(entries(field(result, "layout"), "screenshot").length(), 7)
}

///|
test "invalid dynamic catalogs and cross-group commands fail without a replacement snapshot" {
  let manifest = user_manifest("com.example.capture", ["describe"])
  let layout = field(resolve(Json::null(), [manifest], None), "layout")
  let requests = [
    (
      Json::object({
        "layout": layout,
        "manifests": Json::array([manifest, manifest]),
      }),
      "invalid_catalog",
    ),
    (
      Json::object({
        "layout": layout,
        "manifests": Json::array([user_manifest("builtin.user", ["describe"])]),
      }),
      "invalid_manifest",
    ),
    (
      Json::object({
        "layout": layout,
        "manifests": Json::array([manifest]),
        "command": @json.parse(
          (
            #|{"type":"move","group":"recording","id":"user.com.example.capture/describe","beforeId":null}
          ),
        ),
      }),
      "invalid_group",
    ),
    (
      Json::object({
        "layout": layout,
        "manifests": Json::array([]),
        "command": @json.parse(
          (
            #|{"type":"enabled","id":"user.com.example.capture/describe","enabled":true}
          ),
        ),
      }),
      "unknown_tool",
    ),
    (
      Json::object({
        "layout": layout,
        "manifests": Json::array([manifest]),
        "command": @json.parse(
          (
            #|{"type":"move","group":"screenshot","id":"builtin.image.pin","beforeId":"future.unknown"}
          ),
        ),
      }),
      "unknown_tool",
    ),
    (
      Json::object({
        "layout": layout,
        "manifests": Json::array([manifest]),
        "script": Json("ignored?"),
      }),
      "invalid_input",
    ),
  ]
  for (request, code) in requests {
    let result = tool_registry_resolve(request.stringify())
    @test_support.expect_error(result, code)
    assert_false(@json.parse(result) is Object({ "layout": _, .. }))
  }
}

///|
test "dynamic catalog is limited to 64 tools with per-package bounds checked by the same manifest decoder" {
  let manifests : Array[Json] = []
  for package_index in 0..<4 {
    let tool_ids : Array[String] = []
    for tool in 0..<16 {
      tool_ids.push("tool-\{tool}")
    }
    manifests.push(
      user_manifest("com.example.package-\{package_index}", tool_ids),
    )
  }
  let accepted = resolve(Json::null(), manifests, None)
  assert_eq(entries(accepted, "screenshot").length(), 69)
  manifests.push(user_manifest("com.example.overflow", ["overflow"]))
  @test_support.expect_error(
    tool_registry_resolve(
      Json::object({
        "layout": Json::null(),
        "manifests": Json::array(manifests),
      }).stringify(),
    ),
    "invalid_catalog",
  )
}
