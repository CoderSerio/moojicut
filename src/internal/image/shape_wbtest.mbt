///|
test "shape switches preserve identity and bounds with one undoable edit" {
  for kind in ["rect", "redact"] {
    let original = image_test_apply(image_test_create(), @json.parse(
      "{\"type\":\"add\",\"annotations\":[{\"id\":\"shape\",\"type\":\"\{kind}\",\"x\":20,\"y\":30,\"width\":100,\"height\":80}]}"))
    let changed = image_test_apply(original, @json.parse("{\"type\":\"setShape\",\"id\":\"shape\",\"shape\":1}"))
    let annotation = image_test_first(changed)
    assert_eq(@test_support.model_test_field(annotation, "id"), Json("shape"))
    assert_eq(@test_support.model_test_field(annotation, "x"), Json(20))
    assert_eq(@test_support.model_test_field(annotation, "type"), Json(if kind == "rect" { "ellipse" } else { "redact" }))
    if kind == "redact" { assert_eq(@test_support.model_test_field(annotation, "shape"), Json("ellipse")) }
    let undone = image_test_apply(changed, @json.parse("{\"type\":\"undo\"}"))
    assert_eq(image_test_first(undone), image_test_first(original))
    if kind == "redact" {
      let mosaic = image_test_apply(changed, @json.parse("{\"type\":\"setShape\",\"id\":\"shape\",\"shape\":2}"))
      assert_eq(@test_support.model_test_field(image_test_first(mosaic), "type"), Json("mosaic"))
      assert_eq(@test_support.model_test_field(image_test_first(mosaic), "opacity"), Json(1))
      assert_eq(@test_support.model_test_field(image_test_first(mosaic), "blockSize"), Json(12))
    } else {
      @test_support.expect_error(image_apply(Json::object({"document": changed,
        "command": @json.parse("{\"type\":\"setShape\",\"id\":\"shape\",\"shape\":2}")}).stringify()), "invalid_command")
    }
  }
}

///|
test "ellipse and mosaic hit tests follow the visible geometry and mask stacking" {
  let outline = @json.parse("[{\"id\":\"outline\",\"type\":\"ellipse\",\"x\":20,\"y\":20,\"width\":120,\"height\":80}]")
  assert_eq(selection_test_hit(outline, 80, 20), Json("outline"))
  assert_eq(selection_test_hit(outline, 80, 60), Json::null())
  assert_eq(selection_test_hit(outline, 21, 21), Json::null())
  let cover = @json.parse("[{\"id\":\"cover\",\"type\":\"redact\",\"shape\":\"ellipse\",\"x\":20,\"y\":20,\"width\":120,\"height\":80}]")
  assert_eq(selection_test_hit(cover, 80, 60), Json("cover"))
  assert_eq(selection_test_hit(cover, 21, 21), Json::null())
  let mosaic = @json.parse("[{\"id\":\"mask\",\"type\":\"mosaic\",\"x\":20,\"y\":20,\"width\":120,\"height\":80},{\"id\":\"text\",\"type\":\"text\",\"x\":20,\"y\":20,\"width\":120,\"height\":80,\"text\":\"under mask\"}]")
  assert_eq(selection_test_hit(mosaic, 80, 60), Json("mask"))
}
