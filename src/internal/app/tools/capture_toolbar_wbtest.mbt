///|
test "capture app adapter copies only a live verified catalog and owns no runtime lease" {
  let image = @capture.image_session_create(640, 480)
  let style = @capture.editor_style_create()
  assert_eq(capture_toolbar_open(image, style, 12345678), 0)
  let catalog = opened(8)
  let toolbar = capture_toolbar_open(image, style, catalog)
  assert_true(toolbar > 0)
  assert_eq(tool_registry_snapshot_close(catalog), 1)
  assert_eq(capture_toolbar_config_prepare(toolbar, catalog), 0)
  assert_eq(@capture.toolbar_tool_enabled(toolbar, 1), 1)
  assert_eq(
    @capture.toolbar_context(
      toolbar, "{\"hasRegion\":true,\"blocked\":false,\"fieldFocused\":false,\"pinAvailable\":true,\"edit\":0,\"editVersion\":0,\"measuredHeight\":0,\"capabilities\":0}",
    ),
    1,
  )
  let epoch = @capture.toolbar_value(toolbar, 2).to_int()
  assert_eq(@capture.toolbar_activate(toolbar, epoch, "builtin.capture.ocr"), 0)
  assert_eq(
    @capture.toolbar_context(
      toolbar, "{\"hasRegion\":true,\"blocked\":false,\"fieldFocused\":false,\"pinAvailable\":true,\"edit\":0,\"editVersion\":0,\"measuredHeight\":0,\"capabilities\":1}",
    ),
    1,
  )
  assert_eq(@capture.toolbar_activate(toolbar, epoch, "builtin.capture.ocr"), 1)
  assert_eq(@capture.toolbar_value(toolbar, 5), 5)
  assert_eq(
    @capture.toolbar_ack(
      toolbar,
      @capture.toolbar_value(toolbar, 6).to_int(),
      1,
      "",
    ),
    1,
  )
  assert_eq(@capture.toolbar_close(toolbar), 1)
  @capture.image_session_dispose(image)
  @capture.editor_style_dispose(style)
}

///|
test "verified catalog config keeps enabled preferences separate from backend permissions" {
  let image = @capture.image_session_create(640, 480)
  let style = @capture.editor_style_create()
  let old = opened(31)
  let toolbar = capture_toolbar_open(image, style, old)
  let candidate = tool_registry_snapshot_set_enabled(
    old, "builtin.image.rectangle", 0,
  )
  assert_true(candidate > 0)
  let config = capture_toolbar_config_prepare(toolbar, candidate)
  assert_true(config > 0)
  assert_eq(@capture.toolbar_tool_enabled(toolbar, 1), 1)
  // Failure to save can discard the pure config; preferences and capture stay old.
  assert_eq(@capture.toolbar_config_close(config), 1)
  assert_eq(@capture.toolbar_tool_enabled(toolbar, 1), 1)
  let config = capture_toolbar_config_prepare(toolbar, candidate)
  assert_eq(
    @capture.toolbar_config_commit_many(
      "[{\"toolbar\":\{toolbar},\"candidate\":\{config}}]",
    ),
    1,
  )
  assert_eq(@capture.toolbar_tool_enabled(toolbar, 1), 0)
  assert_eq(
    @capture.toolbar_context(
      toolbar, "{\"hasRegion\":false,\"blocked\":false,\"fieldFocused\":false,\"pinAvailable\":true,\"edit\":0,\"editVersion\":0,\"measuredHeight\":0,\"capabilities\":31}",
    ),
    1,
  )
  let epoch = @capture.toolbar_value(toolbar, 2).to_int()
  assert_eq(
    @capture.toolbar_activate(toolbar, epoch, "builtin.image.rectangle"),
    0,
  )
  assert_eq(
    @capture.toolbar_activate(toolbar, epoch, "builtin.capture.scroll"),
    0,
  )
  assert_eq(@capture.toolbar_activate(toolbar, epoch, "builtin.image.text"), 1)
  assert_eq(
    @capture.toolbar_ack(
      toolbar,
      @capture.toolbar_value(toolbar, 6).to_int(),
      1,
      "",
    ),
    1,
  )
  assert_eq(@capture.toolbar_close(toolbar), 1)
  assert_eq(tool_registry_snapshot_close(old), 1)
  assert_eq(tool_registry_snapshot_close(candidate), 1)
  @capture.image_session_dispose(image)
  @capture.editor_style_dispose(style)
}
