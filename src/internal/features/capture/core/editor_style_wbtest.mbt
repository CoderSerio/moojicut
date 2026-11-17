///|
test "document style validation shares domains while preserving legacy defaults and fractions" {
  let base = image_test_create()
  let annotation : Map[String, Json] = {
    "id": Json("styled-text"), "type": Json("text"), "text": Json("月光"),
    "x": Json(10), "y": Json(20), "width": Json(120), "height": Json(60),
    "opacity": Json(0.123), "stroke": Json(2.5), "fontSize": Json(31.25),
  }
  let make_command = () => Json::object({ "type": Json("add"), "annotations": Json::array([Json::object(annotation)]) })
  let document = image_test_apply(base, make_command())
  let saved = image_test_first(document)
  assert_eq(@test_support.model_test_field(saved, "opacity"), Json(0.123))
  assert_eq(@test_support.model_test_field(saved, "stroke"), Json(2.5))
  assert_eq(@test_support.model_test_field(saved, "fontSize"), Json(31.25))
  for (property, key) in [(1, "opacity"), (2, "stroke"), (3, "fontSize")] {
    let previous = annotation[key]
    for value in [editor_style_min(property) - 0.1, editor_style_max(property) + 0.1] {
      annotation[key] = Json(value)
      @test_support.expect_error(image_apply(Json::object({ "document": base, "command": make_command() }).stringify()), "invalid_annotation")
    }
    annotation[key] = previous
  }
  annotation.remove("opacity")
  annotation.remove("stroke")
  annotation.remove("fontSize")
  let legacy = image_test_first(image_test_apply(base, make_command()))
  assert_eq(@test_support.model_test_field(legacy, "opacity"), Json(1))
  assert_eq(@test_support.model_test_field(legacy, "stroke"), Json(3))
  assert_eq(@test_support.model_test_field(legacy, "fontSize"), Json(24))
}
