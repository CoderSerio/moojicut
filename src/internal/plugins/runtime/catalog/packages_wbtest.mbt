///|
fn package_manifest(id : String) -> Json {
  Json::object({
    "apiVersion": Json(2),
    "pluginId": Json(id),
    "name": Json("截图工具"),
    "version": Json("2.0.0"),
    "entry": Json("plugin.wasm"),
    "runtime": Json("extism-1"),
    "tools": Json::array([
      Json::object({
        "toolId": Json("info"),
        "title": Json("尺寸"),
        "gesture": Json("invoke"),
        "effect": Json("result.text"),
      }),
      Json::object({
        "toolId": Json("box"),
        "title": Json("编号框"),
        "gesture": Json("dragRect"),
        "effect": Json("capture.annotations.add"),
      }),
    ]),
  })
}

///|
fn package_request(layout : Json, manifests : Array[Json]) -> String {
  Json::object({ "layout": layout, "manifests": Json::array(manifests) }).stringify()
}

///|
test "v2 packages share catalog order and exact gesture descriptors without executable metadata injection" {
  let builtins = fixture_contributions()
  let manifests = [
    package_manifest("com.example.first"),
    package_manifest("com.example.second"),
  ]
  let response = resolve_packages(
    builtins,
    package_request(Json::null(), manifests),
  )
  let resolved = success(response)
  assert_eq(entries(resolved, "screenshot").length(), 9)
  let invoke = entries(resolved, "screenshot")[5]
  let drag = entries(resolved, "screenshot")[6]
  assert_eq(field(invoke, "id"), Json("user.com.example.first/info"))
  assert_eq(field(invoke, "action"), Json("invoke"))
  assert_eq(field(invoke, "command"), Json("plugin.run"))
  assert_eq(field(invoke, "interaction"), Json("invoke"))
  assert_eq(field(drag, "interaction"), Json("dragRect"))
  assert_eq(field(drag, "slot"), Json("tools"))
  assert_eq(
    field(drag, "payload"),
    Json::object({ "effect": Json("capture.annotations.add") }),
  )
  assert_eq(
    field(entries(resolved, "screenshot")[8], "id"),
    Json("user.com.example.second/box"),
  )
  assert_eq(
    resolve_packages(
      builtins,
      package_request(field(resolved, "layout"), manifests),
    ),
    response,
  )
  for
    (key, value) in [
      ("command", Json("shell.exec")),
      ("interaction", Json("invoke")),
      ("capability", Json(0)),
      ("payload", Json::object({ "effect": Json("file.write") })),
    ] {
    let forged = success(response)
    match entries(forged, "screenshot")[6] {
      Object(fields) => fields[key] = value
      _ => abort("descriptor")
    }
    assert_eq(snapshot_open_packages(builtins, forged.stringify(), 31), 0)
  }
  assert_eq(snapshot_open(builtins, response, 31), 0)
}

///|
test "v2 immutable typed updates retain gestures capabilities and reinstall preferences" {
  let builtins = fixture_contributions()
  let manifest = package_manifest("com.example.capture")
  let id = "user.com.example.capture/box"
  let response = resolve_packages(
    builtins,
    package_request(Json::null(), [manifest]),
  )
  let original = snapshot_open_packages(builtins, response, 0)
  assert_true(original > 0)
  let moved = snapshot_move(builtins, original, id, "builtin.image.arrow")
  assert_true(moved > original)
  assert_eq(snapshot_text(moved, 0, 1, 0), id)
  assert_eq(snapshot_value(moved, 0, 1, 5), 2)
  assert_eq(snapshot_value(moved, 0, 1, 1), 0)
  let disabled = snapshot_set_enabled(builtins, moved, id, 0)
  assert_true(disabled > moved)
  assert_eq(snapshot_value(disabled, 0, 1, 0), 0)
  assert_eq(snapshot_value(moved, 0, 1, 0), 1)
  assert_eq(snapshot_text(original, 0, 6, 0), id)
  let saved = @json.parse(snapshot_layout(disabled))
  let removed = success(resolve_packages(builtins, package_request(saved, [])))
  assert_eq(field(removed, "layout"), saved)
  assert_eq(entries(removed, "screenshot").length(), 5)
  let reinstalled = snapshot_open_packages(
    builtins,
    resolve_packages(builtins, package_request(saved, [manifest])),
    31,
  )
  assert_true(reinstalled > 0)
  assert_eq(snapshot_text(reinstalled, 0, 1, 0), id)
  assert_eq(snapshot_value(reinstalled, 0, 1, 0), 0)
  assert_eq(snapshot_value(reinstalled, 0, 1, 1), 1)
  assert_eq(snapshot_value(reinstalled, 0, 1, 5), 2)
  assert_eq(
    snapshot_text(reinstalled, 0, 1, 6),
    "{\"effect\":\"capture.annotations.add\"}",
  )
  assert_eq(snapshot_move(builtins, reinstalled, id, "builtin.image.pin"), 0)
  assert_eq(snapshot_set_enabled(builtins, reinstalled, "unknown", 1), 0)
  assert_eq(snapshot_layout(reinstalled), saved.stringify())
  for h in [original, moved, disabled, reinstalled] {
    assert_eq(snapshot_close(h), 1)
    assert_eq(snapshot_move(builtins, h, id, ""), 0)
  }
}

///|
test "v2 catalog rejects v1 mixed duplicate and undeclared contributions atomically" {
  let builtins = fixture_contributions()
  let good = package_manifest("com.example.capture")
  let legacy = user_manifest("com.example.legacy", ["info"])
  for
    (manifests, code) in [
      ([legacy], "unsupported_api_version"),
      ([good, legacy], "unsupported_api_version"),
      ([good, good], "invalid_catalog"),
      (
        [
          @json.parse(
            good
            .stringify()
            .replace_all(old="capture.annotations.add", new="file.write"),
          ),
        ],
        "unsupported_capability",
      ),
      (
        [
          @json.parse(
            good.stringify().replace_all(old="dragRect", new="invoke"),
          ),
        ],
        "invalid_manifest",
      ),
    ] {
    let response = resolve_packages(
      builtins,
      package_request(Json::null(), manifests),
    )
    @test_support.expect_error(response, code)
    assert_false(@json.parse(response) is Object({ "layout": _, .. }))
    assert_eq(snapshot_open_packages(builtins, response, 31), 0)
  }
  let manifests : Array[Json] = []
  for i in 0..<32 {
    manifests.push(package_manifest("com.example.p-\{i}"))
  }
  let accepted = resolve_packages(
    builtins,
    package_request(Json::null(), manifests),
  )
  assert_eq(entries(success(accepted), "screenshot").length(), 69)
  let handle = snapshot_open_packages(builtins, accepted, 31)
  assert_true(handle > 0)
  assert_eq(snapshot_close(handle), 1)
  manifests.push(package_manifest("com.example.overflow"))
  @test_support.expect_error(
    resolve_packages(builtins, package_request(Json::null(), manifests)),
    "invalid_catalog",
  )
}
