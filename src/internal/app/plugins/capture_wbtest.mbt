///|
let test_package_id = "com.example.numbered-box"

///|
let test_box_id = "user.com.example.numbered-box/box"

///|
let test_text_id = "user.com.example.numbered-box/info"

///|
fn test_manifest() -> String {
  let text =
    #|{"apiVersion":2,"pluginId":"com.example.numbered-box","name":"Numbered Box",
    #|"version":"1.0.0","entry":"plugin.wasm","runtime":"extism-1","tools":[
    #|{"toolId":"box","title":"编号框","gesture":"dragRect","effect":"capture.annotations.add"},
    #|{"toolId":"info","title":"查看尺寸","gesture":"invoke","effect":"result.text"}]}
  text
}

///|
let test_health = "{\"apiVersion\":2,\"operation\":\"health\",\"toolIds\":[\"box\",\"info\"]}"

///|
fn prepare_test_package(runtime : @runtime.Runtime) -> PluginInstallation raise {
  prepare_plugin_installation(
    runtime,
    test_manifest(),
    "b3384f2af44caed917e49bd9154d3560f56d7ac14d2e9983a15f47a6af123456",
    0,
    [test_box_id, test_text_id],
  )
}

///|
fn install_test_package(runtime : @runtime.Runtime) -> InstalledPlugin raise {
  let installation = prepare_test_package(runtime)
  assert_true(installation.validate_health(test_health))
  assert_true(installation.begin_publish())
  installation.publish_complete(true).unwrap()
}

///|
fn test_box_output(id : String) -> String {
  let annotations =
    #|[{"type":"rect","x":8,"y":12,"width":64,"height":32,"color":"#ef4444","stroke":3},
    #|{"type":"text","x":10,"y":14,"width":60,"height":28,"color":"#ef4444","fontSize":12,"text":"1"}]
  "{\"apiVersion\":2,\"invocationId\":\"\{id}\",\"kind\":\"annotations\",\"annotations\":\{annotations}}"
}

///|
fn test_box_region() -> @contract.PluginSelection {
  { x: 8, y: 12, width: 64, height: 32, }
}

///|
test "plugin becomes invocable only after health and durable package publication" {
  let runtime = @runtime.Runtime::new()
  let cancelled = prepare_test_package(runtime)
  cancelled.cancel()
  assert_true(cancelled.needs_cancel())
  assert_false(runtime.quiescent())
  cancelled.health_failed()
  assert_true(runtime.quiescent())
  assert_false(cancelled.begin_publish())
  let installation = prepare_test_package(runtime)
  assert_false(installation.begin_publish())
  assert_true(installation.validate_health(test_health))
  assert_true(installation.begin_publish())
  assert_true(runtime.package_snapshot(test_package_id) is None)
  assert_true(installation.publish_complete(false) is None)
  assert_true(runtime.package_snapshot(test_package_id) is None)
  ignore(install_test_package(runtime))
  assert_true(runtime.package_snapshot(test_package_id) is Some(_))
}

///|
test "leased numbered box applies through the capture document with a single undo" {
  let runtime = @runtime.Runtime::new()
  let plugin = install_test_package(runtime)
  let image = @capture.image_session_create_viewport(
    640, 480, 100, 80, 320, 180,
  )
  defer @capture.image_session_dispose(image)
  let owner = runtime.open_owner(image, 0).unwrap()
  let call = plugin.begin_capture_call(
    owner,
    test_box_id,
    "box-27",
    Some(test_box_region()),
  )
  assert_true(call.complete(test_box_output("box-27")) is DocumentChanged)
  assert_eq(@capture.image_session_count(image), 2)
  assert_eq(@capture.image_session_revision(image), 1)
  assert_true(call.complete(test_box_output("box-27")) is Discarded)
  assert_eq(@capture.image_session_undo(image), 1)
  assert_eq(@capture.image_session_count(image), 0)
}

///|
test "disabled and stale captures cannot apply a result, unrelated tools keep their lease" {
  let runtime = @runtime.Runtime::new()
  let plugin = install_test_package(runtime)
  let image = @capture.image_session_create(320, 180)
  defer @capture.image_session_dispose(image)
  let owner = runtime.open_owner(image, 0).unwrap()
  let box = plugin.begin_capture_call(
    owner,
    test_box_id,
    "box-28",
    Some(test_box_region()),
  )
  let info = plugin.begin_capture_call(owner, test_text_id, "info-42", None)
  let edit = runtime
    .prepare_configuration(
      test_package_id,
      runtime.package_generation(test_package_id),
      true,
      [{ id: test_text_id, effect: "result.text", }],
    )
    .unwrap()
  assert_true(edit.begin_publish())
  assert_true(edit.publish_complete(true))
  assert_true(box.needs_cancel())
  assert_true(box.complete(test_box_output("box-28")) is Discarded)
  let output = "{\"apiVersion\":2,\"invocationId\":\"info-42\",\"kind\":\"text\",\"title\":\"尺寸\",\"text\":\"320 × 180\"}"
  guard info.complete(output) is ShowText(title, text) else {
    fail("expected text")
  }
  assert_eq(title, "尺寸")
  assert_eq(text, "320 × 180")
  assert_eq(@capture.image_session_revision(image), 0)
  let after_edit = plugin.begin_capture_call(
    owner,
    test_text_id,
    "info-43",
    None,
  )
  assert_eq(@capture.image_session_crop(image, 0, 0, 200, 120), 1)
  assert_true(after_edit.complete(output) is Discarded)
  assert_eq(@capture.image_session_count(image), 0)
}
