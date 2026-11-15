///|
fn manifest_fixture() -> Json {
  Json::object({
    "apiVersion": Json(1),
    "pluginId": Json("com.example.capture"),
    "name": Json("截图信息"),
    "version": Json("1.2.3"),
    "runtime": Json("extism-1"),
    "entry": Json("plugin.wasm"),
    "capabilities": Json::array([Json("result.text"), Json("capture.metadata")]),
    "tools": Json::array([
      Json::object({
        "toolId": Json("describe"),
        "title": Json("截图信息"),
        "target": Json("screenshot"),
        "action": Json("run"),
      }),
      Json::object({
        "toolId": Json("summary"),
        "title": Json("摘要"),
        "target": Json("screenshot"),
        "action": Json("run"),
      }),
    ]),
  })
}

///|
fn patch(value : Json, key : String, replacement : Json) -> Json {
  let fields : Map[String, Json] = Map([])
  match value {
    Object(source) =>
      for name, value in source {
        fields[name] = value
      }
    _ => abort("Expected object fixture")
  }
  fields[key] = replacement
  Json::object(fields)
}

///|
fn field(value : Json, key : String) -> Json {
  @test_support.model_test_field(value, key)
}

///|
fn success(value : String) -> Json raise {
  @test_support.model_test_result(value)
}

///|
fn capture_fixture() -> Json {
  Json::object({
    "width": Json(1920),
    "height": Json(1080),
    "format": Json("png"),
    "revision": Json(7),
  })
}

///|
fn request_fixture() -> Json {
  Json::object({
    "manifest": manifest_fixture(),
    "toolId": Json("user.com.example.capture/summary"),
    "invocationId": Json("invocation-42"),
    "capture": capture_fixture(),
  })
}

///|
fn output_fixture(text : String) -> Json {
  Json::object({
    "apiVersion": Json(1),
    "invocationId": Json("invocation-42"),
    "kind": Json("text"),
    "title": Json("截图信息"),
    "text": Json(text),
  })
}

///|
fn output_envelope(output : Json) -> String {
  Json::object({ "invocationId": Json("invocation-42"), "output": output }).stringify()
}

///|
test "manifest validates one package with several stable user action tools" {
  let result = success(plugin_manifest_validate(manifest_fixture().stringify()))
  let canonical = field(result, "manifest")
  assert_eq(
    field(canonical, "capabilities"),
    Json::array([Json("capture.metadata"), Json("result.text")]),
  )
  assert_eq(
    field(result, "tools"),
    @json.parse(
      (
        #|[{"id":"user.com.example.capture/describe","pluginId":"com.example.capture","toolId":"describe","target":"screenshot","type":"action","action":"run","title":"截图信息","enabled":true},
        #|{"id":"user.com.example.capture/summary","pluginId":"com.example.capture","toolId":"summary","target":"screenshot","type":"action","action":"run","title":"摘要","enabled":true}]
      ),
    ),
  )
  assert_eq(success(plugin_manifest_validate(canonical.stringify())), result)
  let typed = decode_manifest(canonical)
  typed.tools().clear()
  assert_eq(typed.tools().length(), 2) // Externally returned arrays cannot alter the validated manifest.
}

///|
test "manifest rejects namespace escapes arbitrary capability declarations and unknown fields" {
  for
    id in [
      "builtin.example", "builtinfoo.example", "example", "Com.example", "com..example",
      "com.example/other", "com.-example", "com.example-", "com.exämple",
    ] {
    @test_support.expect_error(
      plugin_manifest_validate(
        patch(manifest_fixture(), "pluginId", Json(id)).stringify(),
      ),
      "invalid_manifest",
    )
  }
  for
    version in [
      "01.0.0", "1.0", "1.0.0.0", "1.0.0-alpha", "1.0.0+build", "1.-1.0", "1e1.0.0",
      "1000000000.0.0",
    ] {
    @test_support.expect_error(
      plugin_manifest_validate(
        patch(manifest_fixture(), "version", Json(version)).stringify(),
      ),
      "invalid_manifest",
    )
  }
  for
    (key, value) in [
      ("entry", Json("../plugin.wasm")),
      ("runtime", Json("native")),
      ("network", Json(true)),
      ("files", Json::array([])),
      ("ui", Json::object({})),
      ("name", Json(" \n")),
    ] {
    @test_support.expect_error(
      plugin_manifest_validate(
        patch(manifest_fixture(), key, value).stringify(),
      ),
      "invalid_manifest",
    )
  }
  for
    capabilities in [
      [],
      [Json("capture.metadata")],
      [Json("capture.metadata"), Json("capture.metadata")],
      [Json("capture.metadata"), Json("network")],
      [Json("capture.metadata"), Json("result.text"), Json("capture.pixels")],
    ] {
    @test_support.expect_error(
      plugin_manifest_validate(
        patch(manifest_fixture(), "capabilities", Json::array(capabilities)).stringify(),
      ),
      "unsupported_capability",
    )
  }
  @test_support.expect_error(
    plugin_manifest_validate(
      patch(manifest_fixture(), "apiVersion", Json(2)).stringify(),
    ),
    "unsupported_api_version",
  )
}

///|
test "tool declarations are bounded unique local keys and cannot impersonate annotation controls" {
  let original = @test_support.model_test_items(
      field(manifest_fixture(), "tools"),
    )[0]
  for
    (key, value) in [
      ("toolId", Json("../describe")),
      ("toolId", Json("builtin.image.rectangle")),
      ("toolId", Json("Describe")),
      ("toolId", Json("a".repeat(49))),
      ("target", Json("recording")),
      ("action", Json("pin")),
      ("kind", Json(1)),
      ("title", Json("x".repeat(81))),
    ] {
    let manifest = patch(
      manifest_fixture(),
      "tools",
      Json::array([patch(original, key, value)]),
    )
    @test_support.expect_error(
      plugin_manifest_validate(manifest.stringify()),
      "invalid_manifest",
    )
  }
  for tools in [[], [original, original]] {
    @test_support.expect_error(
      plugin_manifest_validate(
        patch(manifest_fixture(), "tools", Json::array(tools)).stringify(),
      ),
      "invalid_manifest",
    )
  }
  let tools : Array[Json] = []
  for index in 0..<16 {
    tools.push(patch(original, "toolId", Json("tool-\{index}")))
  }
  ignore(
    success(
      plugin_manifest_validate(
        patch(manifest_fixture(), "tools", Json::array(tools)).stringify(),
      ),
    ),
  )
  tools.push(patch(original, "toolId", Json("overflow")))
  @test_support.expect_error(
    plugin_manifest_validate(
      patch(manifest_fixture(), "tools", Json::array(tools)).stringify(),
    ),
    "invalid_manifest",
  )
  let longest_id = "a." + "b".repeat(94)
  let longest_tool = patch(original, "toolId", Json("c".repeat(48)))
  let result = success(
    plugin_manifest_validate(
      patch(
        patch(manifest_fixture(), "pluginId", Json(longest_id)),
        "tools",
        Json::array([longest_tool]),
      ).stringify(),
    ),
  )
  let descriptor = @test_support.model_test_items(field(result, "tools"))[0]
  assert_eq(
    field(descriptor, "id"),
    Json("user." + longest_id + "/" + "c".repeat(48)),
  )
}

///|
test "invocation preparation routes global identity to the package local tool with metadata only" {
  let prepared = success(plugin_request_prepare(request_fixture().stringify()))
  assert_eq(
    field(prepared, "request"),
    @json.parse(
      (
        #|{"apiVersion":1,"invocationId":"invocation-42","toolId":"summary","capture":{"width":1920,"height":1080,"format":"png","revision":7}}
      ),
    ),
  )
  for
    global_id in [
      "summary", "builtin.image.text", "user.com.other.capture/summary", "user.com.example.capture/missing",
    ] {
    @test_support.expect_error(
      plugin_request_prepare(
        patch(request_fixture(), "toolId", Json(global_id)).stringify(),
      ),
      "unknown_tool",
    )
  }
  for
    (key, value) in [
      ("width", Json(0)),
      ("height", Json(32769)),
      ("width", Json(1.5)),
      ("revision", Json(-1)),
      ("revision", Json(9007199254740991.0)),
      ("format", Json("jpeg")),
      ("pixels", Json("base64")),
      ("path", Json("/tmp/capture.png")),
    ] {
    let capture = patch(capture_fixture(), key, value)
    @test_support.expect_error(
      plugin_request_prepare(
        patch(request_fixture(), "capture", capture).stringify(),
      ),
      "invalid_request",
    )
  }
  let limits = patch(
    patch(patch(capture_fixture(), "width", Json(1)), "height", Json(32768)),
    "revision",
    Json(9007199254740990.0),
  )
  ignore(
    success(
      plugin_request_prepare(
        patch(request_fixture(), "capture", limits).stringify(),
      ),
    ),
  )
  for id in ["", "contains space", "换行", "a".repeat(129)] {
    @test_support.expect_error(
      plugin_request_prepare(
        patch(request_fixture(), "invocationId", Json(id)).stringify(),
      ),
      "invalid_request",
    )
  }
}

///|
test "output validates the invocation and returns text without accepting executable effects" {
  let output = output_fixture("宽度：1920\n高度：1080")
  assert_eq(
    field(success(plugin_output_validate(output_envelope(output))), "result"),
    output,
  )
  @test_support.expect_error(
    plugin_output_validate(
      output_envelope(patch(output, "invocationId", Json("old-invocation"))),
    ),
    "invocation_mismatch",
  )
  @test_support.expect_error(
    plugin_output_validate(
      output_envelope(patch(output, "apiVersion", Json(2))),
    ),
    "unsupported_api_version",
  )
  for
    (key, value) in [
      ("kind", Json("html")),
      ("text", Json("")),
      ("title", Json("\n")),
      ("ui", Json::object({})),
      ("clipboard", Json(true)),
      ("network", Json("https://example.com")),
      ("kind", Json::array([])),
    ] {
    @test_support.expect_error(
      plugin_output_validate(output_envelope(patch(output, key, value))),
      "invalid_output",
    )
  }
}

///|
test "text limits use UTF-8 bytes and escaped legal output has its own envelope budget" {
  for
    text in [
      "a".repeat(32768),
      "界".repeat(10922) + "ab",
      "😀".repeat(8192),
      "\n".repeat(32768),
      "\u0001".repeat(32768),
    ] {
    let output = output_fixture(text)
    assert_eq(
      field(success(plugin_output_validate(output_envelope(output))), "result"),
      output,
    )
  }
  for text in ["界".repeat(10923), "😀".repeat(8192) + "a"] {
    @test_support.expect_error(
      plugin_output_validate(output_envelope(output_fixture(text))),
      "limit_exceeded",
    )
  }
  @test_support.expect_error(
    plugin_output_validate(output_envelope(output_fixture("a".repeat(32769)))),
    "invalid_output",
  )
  @test_support.expect_error(
    plugin_output_validate(" ".repeat(524289)),
    "limit_exceeded",
  )
}

///|
test "raw boundaries reject duplicate keys before any host normalization can hide them" {
  // Escaped spelling must not disguise a duplicate decoded field name.
  @test_support.expect_error(
    plugin_manifest_validate("{\"apiVersion\":1,\"api\\u0056ersion\":1}"),
    "invalid_json",
  )
  @test_support.expect_error(
    plugin_manifest_validate(
      (
        #|{"apiVersion":1,"apiVersion":1}
      ),
    ),
    "invalid_json",
  )
  @test_support.expect_error(
    plugin_request_prepare(
      (
        #|{"capture":{"width":1,"width":2}}
      ),
    ),
    "invalid_json",
  )
  @test_support.expect_error(
    plugin_output_validate(
      (
        #|{"invocationId":"invocation-42","output":{"apiVersion":1,"invocationId":"invocation-42","kind":"text","title":"Result","text":"first","text":"second"}}
      ),
    ),
    "invalid_json",
  )
  @test_support.expect_error(
    plugin_manifest_validate(" ".repeat(65537)),
    "limit_exceeded",
  )
  @test_support.expect_error(plugin_manifest_validate("null"), "invalid_input")
}

///|
test "raw UTF-16 rejects unpaired and adjacent malformed surrogate units" {
  let malformed : Array[Array[Int32]] = [
    [0xD800],
    [0xDBFF],
    [0xDC00],
    [0xDFFF],
    [0xD800, 0x0061],
    [0x0061, 0xDC00],
    [0xD800, 0xDBFF],
    [0xDC00, 0xD800],
    [0xDC00, 0xDFFF],
    [0xD800, 0xDC00, 0xDFFF],
    [0xD800, 0xDC00, 0xDBFF],
    [0xD800, 0xDBFF, 0xDFFF],
  ]
  for units in malformed {
    // Deliberately bypass Char's scalar invariant, as a raw C ABI caller can.
    let raw = String::from_array(units.map(unit => unit.unsafe_to_char()))
    assert_eq(raw.length(), units.length())
    for index in 0..<units.length() {
      assert_eq(raw[index].to_int(), units[index])
    }
    for input in [raw, "{\"value\":\"" + raw + "\"}"] {
      @test_support.expect_error(
        plugin_manifest_validate(input),
        "invalid_json",
      )
      @test_support.expect_error(plugin_request_prepare(input), "invalid_json")
      @test_support.expect_error(plugin_output_validate(input), "invalid_json")
    }
  }
  let leading = String::from_array([(0xD800).unsafe_to_char()])
  @test_support.expect_error(
    plugin_manifest_validate(leading + " ".repeat(65536)),
    "limit_exceeded",
  )
  // ASCII escape sequences still go through the JSON parser's own checks.
  for escaped in ["\\uD800", "\\uDFFF", "\\uD800\\uD800"] {
    @test_support.expect_error(
      plugin_manifest_validate("{\"value\":\"" + escaped + "\"}"),
      "invalid_json",
    )
  }
}

///|
test "UTF-16 pair boundaries retain exact UTF-8 byte budgeting" {
  for
    units in [
      [0xD7FF],
      [0xE000],
      [0xD800, 0xDC00],
      [0xDBFF, 0xDFFF],
      [0xD7FF, 0xD800, 0xDC00, 0xDBFF, 0xDFFF, 0xE000],
    ] {
    let value = String::from_array(units.map(unit => unit.unsafe_to_char()))
    let input = "{\"value\":\"" + value + "\"}"
    let byte_limit = @utf8.encode(input).length()
    assert_eq(parse_object(input, byte_limit).get("value"), Some(Json(value)))
    @test_support.expect_error(
      @protocol.response(() => {
        ignore(parse_object(input, byte_limit - 1))
        Json(true)
      }),
      "limit_exceeded",
    )
  }
}
