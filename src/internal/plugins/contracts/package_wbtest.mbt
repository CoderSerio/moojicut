///|
fn v2_manifest() -> String {
  let manifest =
    #|{"apiVersion":2,"pluginId":"com.example.capture","name":"截图示例","version":"1.2.3",
    #|"entry":"plugin.wasm","runtime":"extism-1","tools":[
    #|{"toolId":"info","title":"查看尺寸","gesture":"invoke","effect":"result.text"},
    #|{"toolId":"box","title":"编号框","gesture":"dragRect","effect":"capture.annotations.add"}]}
  manifest
}

///|
fn v2_capture(selection : PluginSelection?) -> PluginCapture {
  { width: 320, height: 180, revision: 7, selection, }
}

///|
fn v2_box() -> PluginSelection {
  { x: 8, y: 12, width: 64, height: 32, }
}

///|
fn v2_failure(
  operation : () -> Unit raise InputError,
  expected : String,
) -> Unit raise {
  let code = try {
    operation()
    "unexpected_success"
  } catch {
    InputError(code, _) => code
  }
  assert_eq(code, expected)
}

///|
test "v2 package exposes stable contributions and rejects v1 and undeclared effects" {
  let manifest = parse_plugin_package(v2_manifest())
  assert_eq(manifest.plugin_id, "com.example.capture")
  let tool = manifest.contribution("user.com.example.capture/box").unwrap()
  assert_true(tool.gesture is DragRect)
  assert_eq(tool.effect.key(), "capture.annotations.add")
  v2_failure(
    () => ignore(parse_plugin_package(manifest_fixture().stringify())),
    "unsupported_api_version",
  )
  v2_failure(
    () => {
      ignore(
        parse_plugin_package(
          v2_manifest().replace_all(
            old="capture.annotations.add",
            new="file.write",
          ),
        ),
      )
    },
    "unsupported_capability",
  )
  v2_failure(
    () => {
      ignore(
        parse_plugin_package(
          v2_manifest().replace_all(old="dragRect", new="invoke"),
        ),
      )
    },
    "invalid_manifest",
  )
}

///|
test "v2 install health identifies tools without a screenshot, invocation or effects" {
  let manifest = parse_plugin_package(v2_manifest())
  assert_eq(
    @json.parse(plugin_health_request()),
    Json::object({ "apiVersion": Json(2), "operation": Json("health") }),
  )
  manifest.validate_health(
    "{\"apiVersion\":2,\"operation\":\"health\",\"toolIds\":[\"box\",\"info\"]}",
  )
  v2_failure(
    () => {
      manifest.validate_health(
        "{\"apiVersion\":2,\"operation\":\"health\",\"toolIds\":[\"info\",\"info\"]}",
      )
    },
    "invalid_health",
  )
  v2_failure(
    () => {
      manifest.validate_health(
        "{\"apiVersion\":2,\"operation\":\"health\",\"toolIds\":[\"box\",\"info\"],\"effects\":[]}",
      )
    },
    "invalid_health",
  )
}

///|
test "v2 invocation binds selected gesture, exact document revision and effect" {
  let manifest = parse_plugin_package(v2_manifest())
  let id = "user.com.example.capture/box"
  let invocation = manifest.prepare_invocation(
    id,
    "box-27",
    v2_capture(Some(v2_box())),
  )
  let request = @json.parse(invocation.request())
  assert_eq(field(request, "operation"), Json("invoke"))
  assert_eq(field(request, "toolId"), Json("box"))
  assert_eq(field(field(request, "capture"), "revision"), Json(7))
  assert_eq(field(field(request, "selection"), "width"), Json(64))
  v2_failure(
    () => ignore(manifest.prepare_invocation(id, "box-27", v2_capture(None))),
    "invalid_request",
  )
  let outside = { ..v2_box(), x: 257, }
  v2_failure(
    () => {
      ignore(
        manifest.prepare_invocation(id, "box-27", v2_capture(Some(outside))),
      )
    },
    "invalid_request",
  )
  v2_failure(
    () => {
      ignore(
        invocation.validate_output(
          "{\"apiVersion\":2,\"invocationId\":\"other\",\"kind\":\"annotations\",\"annotations\":[{}]}",
        ),
      )
    },
    "invocation_mismatch",
  )
  v2_failure(
    () => {
      ignore(
        invocation.validate_output(
          "{\"apiVersion\":2,\"invocationId\":\"box-27\",\"kind\":\"text\",\"title\":\"wrong\",\"text\":\"wrong\"}",
        ),
      )
    },
    "unsupported_effect",
  )
  // Geometry and IDs belong to the receiving capture document. The protocol
  // validates the envelope and bounds the array before handing it there.
  let response = invocation.validate_output(
    "{\"apiVersion\":2,\"invocationId\":\"box-27\",\"kind\":\"annotations\",\"annotations\":[{\"type\":\"rect\"}]}",
  )
  guard response is Annotations(annotations) else {
    fail("expected annotations")
  }
  assert_eq(annotations.length(), 1)
}

///|
test "v2 text response remains UTF-8 plain text and cannot publish annotations" {
  let manifest = parse_plugin_package(v2_manifest())
  let invocation = manifest.prepare_invocation(
    "user.com.example.capture/info",
    "info-9",
    v2_capture(None),
  )
  let response = invocation.validate_output(
    "{\"apiVersion\":2,\"invocationId\":\"info-9\",\"kind\":\"text\",\"title\":\"截图尺寸\",\"text\":\"320 × 180 像素\"}",
  )
  guard response is Text(title, text) else { fail("expected text") }
  assert_eq(title, "截图尺寸")
  assert_eq(text, "320 × 180 像素")
  v2_failure(
    () => {
      ignore(
        invocation.validate_output(
          "{\"apiVersion\":2,\"invocationId\":\"info-9\",\"kind\":\"annotations\",\"annotations\":[{}]}",
        ),
      )
    },
    "unsupported_effect",
  )
}
