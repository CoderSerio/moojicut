///|
fn app_packages_request(layout : @json.Json) -> String {
  let manifest = @json.parse(
    (
      #|{"apiVersion":2,"pluginId":"com.example.capture","name":"截图示例","version":"2.0.0",
      #|"entry":"plugin.wasm","runtime":"extism-1","tools":[
      #|{"toolId":"info","title":"尺寸信息","gesture":"invoke","effect":"result.text"},
      #|{"toolId":"box","title":"编号框","gesture":"dragRect","effect":"capture.annotations.add"}]}
    ),
  ) catch {
    _ => abort("fixture")
  }
  @json.Json::object({
    "layout": layout,
    "manifests": @json.Json::array([manifest]),
  }).stringify()
}

///|
fn app_packages_context(toolbar : Int32, capabilities : Int32) -> Int32 {
  @capture.toolbar_context(
    toolbar,
    "{\"hasRegion\":true,\"blocked\":false,\"fieldFocused\":false,\"pinAvailable\":true,\"edit\":0,\"editVersion\":0,\"measuredHeight\":0,\"capabilities\":\{capabilities}}",
  )
}

///|
fn app_packages_ack(toolbar : Int32) -> Int32 {
  @capture.toolbar_ack(
    toolbar,
    @capture.toolbar_value(toolbar, 6).to_int(),
    1,
    "",
  )
}

///|
test "v2 app snapshots feed the shared toolbar and keep invocation separate from rectangle selection" {
  let resolved = tool_registry_resolve_packages(
    app_packages_request(@json.Json::null()),
  )
  let snapshot = tool_registry_snapshot_open_packages(resolved, 31)
  assert_true(snapshot > 0)
  assert_eq(tool_registry_snapshot_count(snapshot, 0), 10)
  let info = "user.com.example.capture/info"
  let box = "user.com.example.capture/box"
  let moved = tool_registry_snapshot_move(
    snapshot, box, "builtin.image.rectangle",
  )
  assert_true(moved > 0)
  assert_eq(tool_registry_snapshot_text(moved, 0, 0, 0), box)
  assert_eq(tool_registry_snapshot_value(moved, 0, 0, 5), 2)
  let image = @capture.image_session_create(640, 480)
  let style = @capture.editor_style_create()
  let toolbar = capture_toolbar_open(image, style, moved)
  assert_true(toolbar > 0)
  assert_eq(app_packages_context(toolbar, 0), 1)
  assert_eq(
    @capture.toolbar_activate(
      toolbar,
      @capture.toolbar_value(toolbar, 2).to_int(),
      info,
    ),
    0,
  )
  assert_eq(
    @capture.toolbar_activate(
      toolbar,
      @capture.toolbar_value(toolbar, 2).to_int(),
      box,
    ),
    0,
  )
  assert_eq(app_packages_context(toolbar, 31), 1)
  assert_eq(
    @capture.toolbar_activate(
      toolbar,
      @capture.toolbar_value(toolbar, 2).to_int(),
      box,
    ),
    1,
  )
  assert_eq(@capture.toolbar_value(toolbar, 5), 1) // select, not worker invocation
  assert_eq(@capture.toolbar_value(toolbar, 1), 2) // same dragRect surface contract
  assert_eq(@capture.toolbar_value(toolbar, 0), 1) // shared rectangle preview
  assert_eq(@capture.toolbar_text(toolbar, 0), box)
  assert_eq(@capture.toolbar_text(toolbar, 1), "plugin.run")
  assert_eq(@capture.toolbar_text(toolbar, 2), box)
  assert_eq(app_packages_ack(toolbar), 1)
  let frame = @json.parse(@capture.toolbar_frame(toolbar, 384, 0))
  let semantics = @test_support.model_test_items(
    @test_support.model_test_field(frame, "semantics"),
  )
  assert_true(
    semantics.any(node => {
      @test_support.model_test_field(node, "id") == @json.Json(box)
    }),
  )
  assert_eq(
    @capture.toolbar_activate(
      toolbar,
      @capture.toolbar_value(toolbar, 2).to_int(),
      info,
    ),
    1,
  )
  assert_eq(@capture.toolbar_value(toolbar, 5), 8) // independent app-owned invocation
  assert_eq(@capture.toolbar_text(toolbar, 2), info)
  assert_eq(
    @json.parse(@capture.toolbar_text(toolbar, 3)),
    @json.parse("{\"effect\":\"result.text\"}"),
  )
  // ACK accepts dispatch, without retaining a worker lifetime in the toolbar.
  assert_eq(app_packages_ack(toolbar), 1)
  assert_eq(@capture.toolbar_value(toolbar, 6), 0)
  let disabled = tool_registry_snapshot_set_enabled(moved, box, 0)
  let config = capture_toolbar_config_prepare(toolbar, disabled)
  assert_true(config > 0)
  assert_eq(
    @capture.toolbar_config_commit_many(
      "[{\"toolbar\":\{toolbar},\"candidate\":\{config}}]",
    ),
    1,
  )
  assert_eq(@capture.toolbar_text(toolbar, 0), "host.select")
  assert_eq(
    @capture.toolbar_activate(
      toolbar,
      @capture.toolbar_value(toolbar, 2).to_int(),
      box,
    ),
    0,
  )
  assert_eq(tool_registry_snapshot_value(moved, 0, 0, 0), 1)
  // Exact persisted layout is sufficient to reconstruct both descriptors.
  let saved = tool_registry_snapshot_layout(disabled)
  let reloaded = tool_registry_snapshot_open_packages(
    tool_registry_resolve_packages(app_packages_request(@json.parse(saved))),
    31,
  )
  assert_true(reloaded > 0)
  assert_eq(tool_registry_snapshot_layout(reloaded), saved)
  assert_eq(tool_registry_snapshot_value(reloaded, 0, 0, 5), 2)
  assert_eq(tool_registry_snapshot_value(reloaded, 0, 0, 0), 0)
  assert_eq(@capture.toolbar_close(toolbar), 1)
  for h in [snapshot, moved, disabled, reloaded] {
    assert_eq(tool_registry_snapshot_close(h), 1)
  }
  @capture.image_session_dispose(image)
  @capture.editor_style_dispose(style)
}
