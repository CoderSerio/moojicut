///|
test "shape is frozen at begin and shared commands carry renderable variant data" {
  let id = open(800, 500)
  for (kind, shape, expected) in [(1, 1, "ellipse"), (4, 1, "redact"), (4, 2, "mosaic")] {
    assert_eq(at(send(id, {"type":Json("begin"),"id":Json("shape"),"kind":Json(kind),
      "shape":Json(shape),"blockSize":Json(24),"x":Json(40),"y":Json(50),
      "stroke":Json(4),"opacity":Json(0.3),"color":Json("#123456")}), "ok"), Json(true))
    let preview = at(point(id, "move", 200, 150), "preview")
    assert_eq(at(preview, "type"), Json(expected))
    if shape == 2 {
      assert_eq(at(preview, "blockSize"), Json(24))
      assert_eq(at(preview, "opacity"), Json(1))
    }
    if kind == 4 && shape == 1 { assert_eq(at(preview, "shape"), Json("ellipse")) }
    assert_eq(at(point(id, "end", 200, 150), "command.annotations.0"), preview)
  }
  close(id)
}
