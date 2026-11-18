///|
fn at(value : Json, path : String) -> Json {
  let mut value = value
  for key in path.split(".") {
    value = match value {
      Object(fields) => fields.get(key.to_owned()).unwrap()
      Array(items) if key == "0" => items[0]
      _ => abort("invalid fixture path")
    }
  }
  value
}

///|
fn Json::array_length(self : Json) -> Int32 {
  match self {
    Array(items) => items.length()
    _ => abort("expected array")
  }
}

///|
fn expect_frame(
  actual : FixedArray[Double],
  expected : Array[Double],
) -> Unit raise {
  for i in 0..<4 {
    assert_eq(actual[i], expected[i])
  }
}

///|
fn send(id : Int32, fields : Map[String, Json]) -> Json {
  fields["session"] = Json(id)
  // Explicit contribution capabilities injected by the feature root in production.
  if fields.get("type") == Some(Json("begin")) {
    if !fields.contains("blockSize") { fields["blockSize"] = Json(12) }
    if !fields.contains("shapeCount") {
      fields["shapeCount"] = Json(match fields.get("kind") {
        Some(Number(1,..)) => 2
        Some(Number(4,..)) => 3
        _ => 0
      })
    }
  }
  @json.parse(event(Json::object(fields).stringify())) catch {
    _ => abort("invalid response")
  }
}

///|
fn begin(id : Int32, kind : Int32, x : Double, y : Double) -> Json {
  send(id, {
    "type": Json("begin"),
    "id": Json("shape"),
    "kind": Json(kind),
    "x": Json(x),
    "y": Json(y),
    "stroke": Json(4),
    "opacity": Json(0.6),
    "color": Json("#ff0000"),
  })
}

///|
fn point(id : Int32, phase : String, x : Double, y : Double) -> Json {
  send(id, { "type": Json(phase), "x": Json(x), "y": Json(y) })
}

///|
test "three tools preview without editing and commit through the same image commands" {
  for kind in [1, 2, 4] {
    let id = open(800, 500)
    let created = @json.parse(
      @image.image_create("{\"width\":800,\"height\":500}"),
    ) catch {
      _ => abort("document")
    }
    let doc = at(created, "document")
    assert_eq(at(begin(id, kind, 300, 200), "active"), Json(true))
    let preview = point(id, "move", 80, 60)
    assert_eq(at(preview, "command"), Json::null())
    assert_eq(at(preview, "preview.id"), Json("shape"))
    assert_eq(at(preview, "preview.x"), Json(if kind == 2 { 300 } else { 80 }))
    assert_eq(at(preview, "preview.opacity"), Json(0.6))
    assert_eq(
      at(preview, "preview.type"),
      Json(
        if kind == 1 {
          "rect"
        } else if kind == 2 {
          "arrow"
        } else {
          "redact"
        },
      ),
    )
    let ended = point(id, "end", 80, 60)
    assert_eq(at(ended, "command.annotations.0"), at(preview, "preview"))
    let edited = @json.parse(
      @image.image_apply(
        Json::object({
          "document": doc,
          "expectedRevision": at(doc, "revision"),
          "command": at(ended, "command"),
        }).stringify(),
      ),
    ) catch {
      _ => abort("command")
    }
    assert_eq(at(edited, "ok"), Json(true))
    assert_eq(at(edited, "document.annotations.0"), at(preview, "preview"))
    assert_eq(at(edited, "document.undo").array_length(), 1)
    let undo = @json.parse(
      @image.image_apply(
        Json::object({
          "document": at(edited, "document"),
          "expectedRevision": at(edited, "document.revision"),
          "command": Json::object({ "type": Json("undo") }),
        }).stringify(),
      ),
    ) catch {
      _ => abort("undo")
    }
    assert_eq(at(undo, "document.annotations"), Json::array([]))
    assert_eq(at(point(id, "end", 80, 60), "command"), Json::null())
    close(id)
  }
}

///|
test "cancellation isolation validation and stale handles cannot commit a draft" {
  let first = open(800, 500)
  let second = open(800, 500)
  assert_eq(at(begin(first, 2, 40, 40), "ok"), Json(true))
  assert_eq(at(begin(first, 4, 10, 10), "ok"), Json(false))
  assert_eq(at(point(second, "end", 100, 100), "command"), Json::null())
  // Invalid input leaves the live transaction intact.
  assert_eq(
    at(
      send(first, { "type": Json("move"), "x": Json("bad"), "y": Json(50) }),
      "ok",
    ),
    Json(false),
  )
  assert_eq(at(point(first, "move", 100, 40), "preview.type"), Json("arrow"))
  assert_eq(at(send(first, { "type": Json("cancel") }), "active"), Json(false))
  assert_eq(at(point(first, "end", 100, 100), "command"), Json::null())
  close(first)
  assert_eq(at(point(first, "move", 100, 100), "ok"), Json(false))
  close(second)
}

///|
test "tiny drags have no history while directed arrows and clamped covers remain valid" {
  let id = open(800, 500)
  for kind in [1, 2, 4] {
    let _ = begin(id, kind, 20, 20)
    assert_eq(at(point(id, "end", 21, 21), "command"), Json::null())
  }
  let _ = begin(id, 1, 20, 20)
  assert_eq(at(point(id, "end", 100, 20), "command"), Json::null())
  let _ = begin(id, 2, 100, 40)
  let arrow = at(point(id, "end", 20, 40), "command.annotations.0")
  assert_eq(at(arrow, "x"), Json(100))
  assert_eq(at(arrow, "x2"), Json(20))
  assert_eq(at(arrow, "height"), Json(1))
  let _ = begin(id, 4, 760, 460)
  let cover = at(point(id, "end", 1200, 900), "command.annotations.0")
  assert_eq(at(cover, "width"), Json(40))
  assert_eq(at(cover, "height"), Json(40))
  close(id)
}

///|
test "toolbar follows the lower right edge and fits each content configuration" {
  let small = toolbar_frame(1000, 700, 100, 60, 600, 400, 330, 0)
  expect_frame(small, [358.0, 466.0, 342.0, 40.0])
  let properties = toolbar_frame(1000, 700, 100, 60, 600, 400, 330, 410)
  expect_frame(properties, [278.0, 466.0, 422.0, 72.0])
  let above = toolbar_frame(1000, 700, 100, 300, 600, 380, 330, 0)
  expect_frame(above, [358.0, 254.0, 342.0, 40.0])
  let full = toolbar_frame(1000, 700, 0, 0, 1000, 700, 330, 0)
  expect_frame(full, [650.0, 652.0, 342.0, 40.0])
  let narrow = toolbar_frame(200, 150, 2, 2, 80, 60, 500, 400)
  expect_frame(narrow, [8.0, 68.0, 184.0, 72.0])
}

///|
test "native font metrics participate in toolbar placement" {
  // Native accessibility fonts need 100pt: the 72pt default would overflow.
  let tall = measured_toolbar_frame(800, 400, 100, 120, 500, 190, 440, 100)
  expect_frame(tall, [160.0, 14.0, 440.0, 100.0])
  let narrow = measured_toolbar_frame(300, 200, 0, 0, 300, 200, 600, 250)
  expect_frame(narrow, [8.0, 8.0, 284.0, 184.0])
}
