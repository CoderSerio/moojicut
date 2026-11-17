///|
fn selection_test_hit(annotations : Json, x : Double, y : Double) -> Json raise {
  let result = @test_support.model_test_result(image_selection(Json::object({
    "action": Json("hit"), "annotations": annotations, "x": Json(x), "y": Json(y), "tolerance": Json(4),
  }).stringify()))
  @test_support.model_test_field(@test_support.model_test_field(result, "document"), "id")
}

///|
test "annotation hits follow visible cover order and do not claim empty rectangle interiors" {
  let annotations = @json.parse((
    #|[{"id":"rect","type":"rect","x":20,"y":20,"width":120,"height":100},
    #| {"id":"cover","type":"redact","x":50,"y":50,"width":40,"height":40},
    #| {"id":"text","type":"text","x":60,"y":60,"width":50,"height":40,"text":"label"}]
  ))
  assert_eq(selection_test_hit(annotations, 21, 60), Json("rect"))
  assert_eq(selection_test_hit(annotations, 70, 70), Json("cover"))
  assert_eq(selection_test_hit(annotations, 100, 70), Json("text"))
  assert_eq(selection_test_hit(annotations, 35, 40), Json::null())
  assert_eq(selection_test_hit(annotations, 180, 140), Json::null())
}

///|
test "reversed arrows hit strokes and heads but not their empty bounding box" {
  let annotations = @json.parse((
    #|[{"id":"arrow","type":"arrow","x":180,"y":160,"x2":40,"y2":20,"stroke":4}]
  ))
  assert_eq(selection_test_hit(annotations, 100, 80), Json("arrow"))
  assert_eq(selection_test_hit(annotations, 44, 32), Json("arrow"))
  assert_eq(selection_test_hit(annotations, 50, 150), Json::null())
}

///|
fn selection_test_transform(annotation : Json, handle : Int, x : Double, y : Double) -> Json raise {
  @test_support.model_test_field(@test_support.model_test_result(image_selection(Json::object({
    "action": Json("transform"), "annotation": annotation,
    "sourceWidth": Json(200), "sourceHeight": Json(180),
    "anchorX": Json(0), "anchorY": Json(0), "x": Json(x), "y": Json(y), "handle": Json(handle),
  }).stringify())), "document")
}

///|
test "arrow moves clamp both endpoints and endpoint resize can reverse direction" {
  let arrow = @json.parse((
    #|{"id":"arrow","type":"arrow","x":180,"y":160,"x2":40,"y2":20,"stroke":4}
  ))
  let moved = selection_test_transform(arrow, -1, 100, 100)
  assert_eq(@test_support.model_test_field(moved, "x"), Json(200))
  assert_eq(@test_support.model_test_field(moved, "y"), Json(180))
  assert_eq(@test_support.model_test_field(moved, "x2"), Json(60))
  assert_eq(@test_support.model_test_field(moved, "y2"), Json(40))
  let resized = selection_test_transform(arrow, 0, -200, -200)
  assert_eq(@test_support.model_test_field(resized, "x"), Json(0))
  assert_eq(@test_support.model_test_field(resized, "y"), Json(0))
  assert_eq(@test_support.model_test_field(resized, "x2"), Json(40))
  assert_eq(@test_support.model_test_field(resized, "y2"), Json(20))
}

///|
test "rectangle resize preserves styles and obeys image bounds" {
  let rectangle = @json.parse((
    #|{"id":"rect","type":"rect","x":20,"y":30,"width":100,"height":70,"opacity":0.25,"color":"#00ff00"}
  ))
  let resized = selection_test_transform(rectangle, 4, 500, 500)
  assert_eq(@test_support.model_test_field(resized, "width"), Json(180))
  assert_eq(@test_support.model_test_field(resized, "height"), Json(150))
  assert_eq(@test_support.model_test_field(resized, "opacity"), Json(0.25))
  assert_eq(@test_support.model_test_field(resized, "color"), Json("#00ff00"))
}

///|
test "shared arrowhead geometry covers thick short and reversed visible wings" {
  // Known horizontal 20px-stroke geometry: a 70px wing at +/-0.5 radians.
  assert_true((image_arrowhead_value(0, 100, 200, 100, 20, 0) - 138.5692206676739).abs() < 0.000001)
  assert_true((image_arrowhead_value(0, 100, 200, 100, 20, 1) - 66.4402122977058).abs() < 0.000001)
  assert_true((image_arrowhead_value(0, 100, 200, 100, 20, 3) - 133.5597877022942).abs() < 0.000001)
  for (x, y, x2, y2, stroke) in [(0.0, 100.0, 200.0, 100.0, 20.0),
    (100.0, 100.0, 110.0, 100.0, 96.0), (200.0, 160.0, 40.0, 20.0, 32.0)] {
    let arrow = match image_annotation(Json::object({
      "id": Json("arrow"), "type": Json("arrow"), "x": Json(x), "y": Json(y),
      "x2": Json(x2), "y2": Json(y2), "stroke": Json(stroke),
    })) { Object(m) => m; _ => Map([]) }
    for field in [0, 2] {
      let hx = image_arrowhead_value(x, y, x2, y2, stroke, field)
      let hy = image_arrowhead_value(x, y, x2, y2, stroke, field + 1)
      assert_true(annotation_contains(arrow, hx, hy, 0))
      assert_true(annotation_contains(arrow, (hx + x2) / 2, (hy + y2) / 2, 0))
    }
  }
  assert_eq(image_arrowhead_value(10, 20, 10, 20, 4, 0), 10)
  assert_eq(image_arrowhead_value(10, 20, 10, 20, 4, 3), 20)
  assert_eq(image_arrowhead_value(0, 0, 10, 10, 4, -1), 0)
  assert_eq(image_arrowhead_value(0, 0, 10, 10, 0.0 / 0.0, 0), 0)
}
