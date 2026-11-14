///|
fn model_test_result(text : String) -> Json raise {
  let result = @json.parse(text)
  assert_true(result is Object({ "ok": True, .. }))
  result
}

///|
fn model_test_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap()
    _ => abort("Expected an object")
  }
}

///|
fn model_test_items(value : Json) -> Array[Json] {
  match value {
    Array(items) => items
    _ => abort("Expected an array")
  }
}

///|
fn image_test_create() -> Json raise {
  model_test_field(
    model_test_result(image_create("{\"width\":1200,\"height\":900}")),
    "document",
  )
}

///|
fn image_test_apply(document : Json, command : Json) -> Json raise {
  let request = Json::object({
    "document": document,
    "command": command,
    "expectedRevision": model_test_field(document, "revision"),
  })
  model_test_field(
    model_test_result(image_apply(request.stringify())),
    "document",
  )
}

///|
fn image_test_rect(id : String) -> Json {
  Json::object({
    "id": Json(id),
    "type": Json("rect"),
    "x": Json(100),
    "y": Json(150),
    "width": Json(200),
    "height": Json(90),
    "color": Json("#ff00AA"),
    "stroke": Json(3),
    "opacity": Json(1),
  })
}

///|
fn image_test_first(document : Json) -> Json {
  model_test_items(model_test_field(document, "annotations"))[0]
}

///|
test "image crop and annotation edits share one undo history" {
  let mut document = image_test_create()
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"crop","rect":{"x":30,"y":20,"width":500,"height":400}}
      ),
    ),
  )
  document = image_test_apply(
    document,
    Json::object({
      "type": Json("add"),
      "annotations": Json::array([image_test_rect("rect-1")]),
    }),
  )
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"move","id":"rect-1","dx":25,"dy":30}
      ),
    ),
  )
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"crop","rect":{"x":90,"y":100,"width":50,"height":50}}
      ),
    ),
  )
  assert_true(
    model_test_field(image_test_first(document), "width") == Json(200),
  )
  document = image_test_apply(document, @json.parse("{\"type\":\"undo\"}"))
  assert_true(
    model_test_field(model_test_field(document, "viewport"), "width") ==
    Json(500),
  )
  document = image_test_apply(document, @json.parse("{\"type\":\"undo\"}"))
  assert_true(model_test_field(image_test_first(document), "x") == Json(100))
  document = image_test_apply(document, @json.parse("{\"type\":\"redo\"}"))
  assert_true(model_test_field(image_test_first(document), "x") == Json(125))
  expect_error(
    image_apply(
      Json::object({
        "document": document,
        "expectedRevision": Json(0),
        "command": Json::object({
          "type": Json("remove"),
          "ids": Json::array([Json("rect-1")]),
        }),
      }).stringify(),
    ),
    "revision_conflict",
  )
  document = image_test_apply(document, @json.parse("{\"type\":\"undo\"}"))
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"update","id":"rect-1","patch":{"color":"#00ff00"}}
      ),
    ),
  )
  assert_eq(model_test_items(model_test_field(document, "redo")).length(), 0)
}

///|
test "large freehand histories exceed 64 KiB without changing prior snapshots" {
  let points = Array::makei(2000, i => {
    Json::object({ "x": Json(i % 1000), "y": Json(i / 10 % 800) })
  })
  let mut document = image_test_apply(
    image_test_create(),
    Json::object({
      "type": Json("add"),
      "annotations": Json::array([
        Json::object({
          "id": Json("stroke"),
          "type": Json("marker"),
          "x": Json(0),
          "y": Json(0),
          "points": Json::array(points),
          "color": Json("#ffbb00"),
          "stroke": Json(24),
          "opacity": Json(0.3),
        }),
      ]),
    }),
  )
  for _ in 0..<5 {
    document = image_test_apply(
      document,
      @json.parse(
        (
          #|{"type":"move","id":"stroke","dx":1,"dy":1}
        ),
      ),
    )
  }
  assert_true(document.stringify().length() > 65536)
  let restored = image_test_apply(document, @json.parse("{\"type\":\"undo\"}"))
  let previous_point = model_test_items(
      model_test_field(image_test_first(restored), "points"),
    )[0]
  let current_point = model_test_items(
      model_test_field(image_test_first(document), "points"),
    )[0]
  assert_true(model_test_field(previous_point, "x") == Json(4))
  assert_true(model_test_field(current_point, "x") == Json(5))
}

///|
test "image completion rebases objects and discards pixel-dependent history" {
  let mut document = image_test_apply(
    image_test_create(),
    Json::object({
      "type": Json("add"),
      "annotations": Json::array([image_test_rect("rect-1")]),
    }),
  )
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"crop","rect":{"x":80,"y":120,"width":200,"height":200}}
      ),
    ),
  )
  let completed = model_test_field(
    model_test_result(
      image_finalize(Json::object({ "document": document }).stringify()),
    ),
    "document",
  )
  assert_true(model_test_field(completed, "width") == Json(200))
  assert_true(model_test_field(image_test_first(completed), "x") == Json(20))
  assert_true(model_test_field(image_test_first(completed), "y") == Json(30))
  assert_true(
    model_test_field(model_test_field(completed, "viewport"), "x") == Json(0),
  )
  assert_eq(model_test_items(model_test_field(completed, "undo")).length(), 0)
  assert_eq(model_test_items(model_test_field(completed, "redo")).length(), 0)
  assert_eq(
    number_result(completed.stringify(), "revision"),
    number_result(document.stringify(), "revision") + 1,
  )
}

///|
test "image undo is bounded to 100 edits and a multi-object deletion is atomic" {
  let mut document = image_test_apply(
    image_test_create(),
    Json::object({
      "type": Json("add"),
      "annotations": Json::array([
        image_test_rect("rect-1"),
        image_test_rect("rect-2"),
      ]),
    }),
  )
  for _ in 0..<105 {
    document = image_test_apply(
      document,
      @json.parse(
        (
          #|{"type":"move","id":"rect-1","dx":1,"dy":0}
        ),
      ),
    )
  }
  assert_eq(model_test_items(model_test_field(document, "undo")).length(), 100)
  let before = model_test_field(document, "annotations")
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"remove","ids":["rect-1","rect-2"]}
      ),
    ),
  )
  assert_eq(
    model_test_items(model_test_field(document, "annotations")).length(),
    0,
  )
  document = image_test_apply(document, @json.parse("{\"type\":\"undo\"}"))
  assert_true(model_test_field(document, "annotations") == before)
}

///|
test "image styles and IDs are validated and filled covers retain opacity" {
  let document = image_test_create()
  for
    (key, value) in [
      ("color", Json("#zzzzzz")),
      ("width", Json(-1)),
      ("opacity", Json(2)),
      ("type", Json("unknown")),
    ] {
    let fields = match image_test_rect("rect-1") {
      Object(fields) => fields
      _ => abort("rect")
    }
    fields[key] = value
    expect_error(
      image_apply(
        Json::object({
          "document": document,
          "command": Json::object({
            "type": Json("add"),
            "annotations": Json::array([Json::object(fields)]),
          }),
        }).stringify(),
      ),
      "invalid_annotation",
    )
  }
  let add = Json::object({
    "type": Json("add"),
    "annotations": Json::array([image_test_rect("rect-1")]),
  })
  let with_rect = image_test_apply(document, add)
  expect_error(
    image_apply(
      Json::object({ "document": with_rect, "command": add }).stringify(),
    ),
    "duplicate_id",
  )
  let redacted = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"add","annotations":[{"id":"mask","type":"redact","x":0,"y":0,"width":40,"height":30,"opacity":0.2,"color":"#225577"}]}
      ),
    ),
  )
  assert_true(
    model_test_field(image_test_first(redacted), "opacity") == Json(0.2),
  )
  assert_eq(model_test_field(image_test_first(redacted), "color"), Json("#225577"))
  let finalized = model_test_result(image_finalize(Json::object({ "document": redacted }).stringify()))
  assert_eq(model_test_field(image_test_first(model_test_field(finalized, "document")), "opacity"), Json(0.2))
  let mosaic = image_test_apply(document, @json.parse((
    #|{"type":"add","annotations":[{"id":"mosaic","type":"mosaic","x":0,"y":0,"width":40,"height":30,"opacity":0.2}]}
  )))
  assert_eq(model_test_field(image_test_first(mosaic), "opacity"), Json(1))
}

///|
test "text edits retain Unicode and geometry through undo redo and export" {
  let content = "中文标注 ✂️\n可以再次编辑"
  let mut document = image_test_apply(
    image_test_create(),
    Json::object({
      "type": Json("add"),
      "annotations": Json::array([
        Json::object({
          "id": Json("text-1"),
          "type": Json("text"),
          "x": Json(100),
          "y": Json(150),
          "width": Json(240),
          "height": Json(96),
          "text": Json("第一版 🙂"),
          "fontSize": Json(24),
          "color": Json("#ef4444"),
        }),
      ]),
    }),
  )
  let added = model_test_field(document, "annotations")
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"move","id":"text-1","dx":25.5,"dy":-10.25}
      ),
    ),
  )
  let moved = model_test_field(document, "annotations")
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"resize","id":"text-1","rect":{"width":360,"height":144}}
      ),
    ),
  )
  let resized = model_test_field(document, "annotations")
  // Resizing the text box does not implicitly change its typography.
  assert_true(
    model_test_field(image_test_first(document), "fontSize") == Json(24),
  )
  document = image_test_apply(
    document,
    Json::object({
      "type": Json("update"),
      "id": Json("text-1"),
      "patch": Json::object({
        "text": Json(content),
        "fontSize": Json(36),
        "color": Json("#09a6ff"),
      }),
    }),
  )
  let edited = model_test_field(document, "annotations")
  // Each completed gesture or edit is one undo step, with no partial styles.
  for expected in [resized, moved, added] {
    document = image_test_apply(document, @json.parse("{\"type\":\"undo\"}"))
    assert_true(model_test_field(document, "annotations") == expected)
  }
  for expected in [moved, resized, edited] {
    document = image_test_apply(document, @json.parse("{\"type\":\"redo\"}"))
    assert_true(model_test_field(document, "annotations") == expected)
  }
  document = image_test_apply(
    document,
    @json.parse(
      (
        #|{"type":"crop","rect":{"x":80,"y":100,"width":600,"height":400}}
      ),
    ),
  )
  let completed = model_test_field(
    model_test_result(
      image_finalize(Json::object({ "document": document }).stringify()),
    ),
    "document",
  )
  let text = image_test_first(completed)
  assert_true(model_test_field(text, "id") == Json("text-1"))
  assert_true(model_test_field(text, "text") == Json(content))
  assert_true(model_test_field(text, "x") == Json(45.5))
  assert_true(model_test_field(text, "y") == Json(39.75))
  assert_true(model_test_field(text, "width") == Json(360))
  assert_true(model_test_field(text, "height") == Json(144))
  assert_true(model_test_field(text, "fontSize") == Json(36))
  assert_true(model_test_field(text, "color") == Json("#09a6ff"))
  assert_eq(model_test_items(model_test_field(completed, "undo")).length(), 0)
  assert_true(model_test_field(document, "annotations") == edited)
}
