///|
let index_test_digest = "1111111111111111111111111111111111111111111111111111111111111111"

///|
fn index_test_layout() -> Json {
  Json::object({
    "version": Json(1),
    "groups": Json::object({
      "screenshot": Json::array([
        Json::object({ "id": Json(test_box_id), "enabled": Json(true) }),
      ]),
      "recording": Json::array([]),
      "videoEditing": Json::array([]),
    }),
  })
}

///|
fn index_test_package() -> PluginIndex raise {
  PluginIndex::empty(index_test_layout()).with_package(
    test_package_id,
    index_test_digest,
    true,
    [test_box_id, test_text_id],
  )
}

///|
fn index_test_rejected(text : String) -> Bool {
  try {
    ignore(parse_plugin_index(text))
    false
  } catch {
    _ => true
  }
}

///|
test "strict plugin index rejects ambiguous records and numeric revisions without partial interpretation" {
  let index = index_test_package()
  let valid = index.encode()
  assert_eq(parse_plugin_index(valid).encode(), valid)
  let object = match @json.parse(valid) {
    Object(fields) => fields
    _ => abort("fixture")
  }
  for bad in [Json(-1), Json(0.5), Json(2147483648.0), Json("1"), Json(true)] {
    object["revision"] = bad
    assert_true(index_test_rejected(Json::object(object).stringify()))
  }
  object["revision"] = Json(1)
  object["unknown"] = Json(true)
  assert_true(index_test_rejected(Json::object(object).stringify()))
  object.remove("unknown")
  object["schemaVersion"] = Json(1)
  assert_true(index_test_rejected(Json::object(object).stringify()))
  object["schemaVersion"] = Json(2)
  object["layout"] = Json::array([])
  assert_true(index_test_rejected(Json::object(object).stringify()))
  object["layout"] = index_test_layout()
  let record = match object["packages"] {
    Array(values) =>
      match values[0] {
        Object(fields) => fields
        _ => abort("fixture")
      }
    _ => abort("fixture")
  }
  object["packages"] = Json::array([Json::object(record), Json::object(record)])
  assert_true(index_test_rejected(Json::object(object).stringify()))
  object["packages"] = Json::array([Json::object(record)])
  for
    bad in [
      Json("ABCDEF"),
      Json("g111111111111111111111111111111111111111111111111111111111111111"),
      Json(1),
    ] {
    record["digest"] = bad
    assert_true(index_test_rejected(Json::object(object).stringify()))
  }
  record["digest"] = Json(index_test_digest)
  record["enabled"] = Json(1)
  assert_true(index_test_rejected(Json::object(object).stringify()))
  record["enabled"] = Json(true)
  for
    grants in [
      Json::array([Json(test_box_id), Json(test_box_id)]),
      Json::array([Json("user.com.other/box")]),
      Json::array([Json("user.com.example.numbered-box/")]),
      Json::array([Json("user.com.example.numbered-box/Box")]),
    ] {
    record["granted"] = grants
    assert_true(index_test_rejected(Json::object(object).stringify()))
  }
  record["granted"] = Json::array([])
  record["path"] = Json("/tmp/plugin.wasm")
  assert_true(index_test_rejected(Json::object(object).stringify()))
  assert_true(
    index_test_rejected(
      "{\"schemaVersion\":2,\"schemaVersion\":2,\"revision\":0,\"packages\":[],\"layout\":{}}",
    ),
  )
  assert_true(
    index_test_rejected(
      "{\"schemaVersion\":2,\"revision\":0,\"packages\":[],\"layout\":{\"x\":1,\"x\":2}}",
    ),
  )
  for
    revision in [
      "2147483647.0000001", "0.0000000000000000000000000000001", "1e-9999", "1.0",
      "1e0", "-0",
    ] {
    assert_true(
      index_test_rejected(
        "{\"schemaVersion\":2,\"revision\":\{revision},\"packages\":[],\"layout\":{}}",
      ),
    )
  }
}

///|
test "index mutations preserve ordering and cannot alias callers or increment revision twice" {
  let input_layout = index_test_layout()
  let input_grants = [test_box_id]
  let first = PluginIndex::empty(input_layout).with_package(
    test_package_id, index_test_digest, true, input_grants,
  )
  let before = first.encode()
  input_grants.clear()
  match input_layout {
    Object(fields) => fields.clear()
    _ => ()
  }
  first.packages().clear()
  first.packages()[0].granted().clear()
  match first.layout() {
    Object(fields) => fields.clear()
    _ => ()
  }
  assert_eq(first.encode(), before)
  let second = first.with_package(
    "com.example.second",
    index_test_digest,
    true,
    [],
  )
  let changed_layout = Json::object({
    "version": Json(1),
    "groups": Json::object({}),
  })
  let replaced = second.with_package(
    test_package_id,
    index_test_digest,
    false,
    [test_text_id],
    layout=changed_layout,
  )
  assert_eq(replaced.revision, second.revision + 1)
  assert_eq(replaced.packages().map(entry => entry.plugin_id), [
    test_package_id, "com.example.second",
  ])
  assert_false(replaced.packages()[0].enabled)
  assert_eq(replaced.packages()[0].granted(), [test_text_id])
  assert_eq(replaced.layout(), changed_layout)
  assert_eq(first.encode(), before)
  let removed = replaced.without_package(
    test_package_id,
    layout=index_test_layout(),
  )
  assert_eq(removed.revision, replaced.revision + 1)
  assert_eq(removed.packages().map(entry => entry.plugin_id), [
    "com.example.second",
  ])
  assert_eq(removed.layout(), index_test_layout())
  let before_unknown = removed.encode()
  assert_true(
    try {
      ignore(removed.without_package("com.example.absent"))
      false
    } catch {
      _ => true
    },
  )
  assert_eq(removed.encode(), before_unknown)
  assert_eq(removed.with_layout(changed_layout).revision, removed.revision + 1)
}

///|
test "index has bounded storage and refuses revision overflow before a new durable candidate" {
  let mut index = PluginIndex::empty(Json::object({}))
  for i = 0; i < 64; i = i + 1 {
    index = index.with_package("com.example.p\{i}", index_test_digest, true, [])
  }
  assert_eq(index.packages().length(), 64)
  assert_true(
    try {
      ignore(
        index.with_package("com.example.extra", index_test_digest, true, []),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    index
    .with_package("com.example.p0", index_test_digest, false, [])
    .packages()
    .length(),
    64,
  )
  let max = parse_plugin_index(
    "{\"schemaVersion\":2,\"revision\":2147483647,\"packages\":[],\"layout\":{}}",
  )
  assert_true(
    try {
      ignore(max.with_layout(Json::object({})))
      false
    } catch {
      _ => true
    },
  )
  let large = String::make(400000, '界')
  let text = "{\"schemaVersion\":2,\"revision\":0,\"packages\":[],\"layout\":{\"value\":\"\{large}\"}}"
  assert_true(index_test_rejected(text))
  assert_true(
    try {
      ignore(PluginIndex::empty(Json::object({ "value": Json(large) })))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "verified restart restores approval and active version without health or publication effects" {
  let index = index_test_package()
  let runtime = @runtime.Runtime::new()
  let installed = restore_plugin_index(runtime, index, [
    { manifest_json: test_manifest(), digest: index_test_digest, },
  ])
  assert_eq(installed.length(), 1)
  assert_true(runtime.quiescent())
  assert_eq(
    runtime.package_snapshot(test_package_id).unwrap().content.digest,
    index_test_digest,
  )
  let image = @capture.image_session_create(320, 180)
  defer @capture.image_session_dispose(image)
  let owner = runtime.open_owner(image, 0).unwrap()
  let call = installed[0].begin_capture_call(
    owner,
    test_text_id,
    "restored-text",
    None,
  )
  let output = "{\"apiVersion\":2,\"invocationId\":\"restored-text\",\"kind\":\"text\",\"title\":\"尺寸\",\"text\":\"320 × 180\"}"
  assert_true(call.complete(output) is ShowText(_, _))
  let disabled_runtime = @runtime.Runtime::new()
  let disabled = index.with_package(test_package_id, index_test_digest, false, [
    test_text_id,
  ])
  let disabled_plugins = restore_plugin_index(disabled_runtime, disabled, [
    { manifest_json: test_manifest(), digest: index_test_digest, },
  ])
  let disabled_owner = disabled_runtime.open_owner(image, 0).unwrap()
  assert_true(
    try {
      ignore(
        disabled_plugins[0].begin_capture_call(
          disabled_owner,
          test_text_id,
          "disabled",
          None,
        ),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "restore rejects corrupt or mismatched snapshots atomically and never replaces a live runtime" {
  let index = index_test_package()
  let runtime = @runtime.Runtime::new()
  for
    verified in [
      [],
      [
        {
          manifest_json: test_manifest(),
          digest: "2222222222222222222222222222222222222222222222222222222222222222",
        },
      ],
      [{ manifest_json: "{}", digest: index_test_digest, }],
      [
        { manifest_json: test_manifest(), digest: index_test_digest, },
        { manifest_json: test_manifest(), digest: index_test_digest, },
      ],
    ] {
    assert_true(
      try {
        ignore(restore_plugin_index(runtime, index, verified))
        false
      } catch {
        _ => true
      },
    )
    assert_true(runtime.package_snapshot(test_package_id) is None)
    assert_true(runtime.quiescent())
  }
  let missing_grant = index.with_package(
    test_package_id,
    index_test_digest,
    true,
    ["user.com.example.numbered-box/absent"],
  )
  assert_true(
    try {
      ignore(
        restore_plugin_index(runtime, missing_grant, [
          { manifest_json: test_manifest(), digest: index_test_digest, },
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_true(runtime.package_snapshot(test_package_id) is None)
  ignore(
    restore_plugin_index(runtime, index, [
      { manifest_json: test_manifest(), digest: index_test_digest, },
    ]),
  )
  let installed = runtime.package_snapshot(test_package_id)
  assert_true(
    try {
      ignore(
        restore_plugin_index(runtime, index, [
          { manifest_json: test_manifest(), digest: index_test_digest, },
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_eq(runtime.package_snapshot(test_package_id), installed)
  let empty_runtime = @runtime.Runtime::new()
  let empty = PluginIndex::empty(Json::object({}))
  ignore(restore_plugin_index(empty_runtime, empty, []))
  assert_true(
    try {
      ignore(
        restore_plugin_index(empty_runtime, index, [
          { manifest_json: test_manifest(), digest: index_test_digest, },
        ]),
      )
      false
    } catch {
      _ => true
    },
  )
}

///|
test "multi-package restore checks every package first and returns the index ordering" {
  let second_manifest = "{\"apiVersion\":2,\"pluginId\":\"com.example.second\",\"name\":\"Second\",\"version\":\"2.0.0\",\"entry\":\"plugin.wasm\",\"runtime\":\"extism-1\",\"tools\":[{\"toolId\":\"info\",\"title\":\"Info\",\"gesture\":\"invoke\",\"effect\":\"result.text\"}]}"
  let index = index_test_package().with_package(
    "com.example.second",
    index_test_digest,
    true,
    ["user.com.example.second/absent"],
  )
  let verified : Array[VerifiedPluginArchive] = [
    { manifest_json: second_manifest, digest: index_test_digest, },
    { manifest_json: test_manifest(), digest: index_test_digest, },
  ]
  let runtime = @runtime.Runtime::new()
  assert_true(
    try {
      ignore(restore_plugin_index(runtime, index, verified))
      false
    } catch {
      _ => true
    },
  )
  assert_true(runtime.package_snapshot(test_package_id) is None)
  assert_true(runtime.package_snapshot("com.example.second") is None)
  let valid = index.with_package(
    "com.example.second",
    index_test_digest,
    true,
    ["user.com.example.second/info"],
  )
  assert_true(
    try {
      ignore(restore_plugin_index(runtime, valid, [verified[0], verified[0]]))
      false
    } catch {
      _ => true
    },
  )
  assert_true(runtime.package_snapshot("com.example.second") is None)
  let restored = restore_plugin_index(runtime, valid, verified)
  assert_eq(restored.map(item => item.manifest.plugin_id), [
    test_package_id, "com.example.second",
  ])
  assert_eq(restored[1].installed.content.version, "2.0.0")
  assert_true(runtime.quiescent())
}
