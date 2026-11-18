///|
fn prop_begin(s : Int32, bank : Int32, tool : Int32, id : String) -> Int32 {
  properties_begin(s, bank, tool, id, image_session_revision(s), "")
}

///|
fn prop_shape(s : Int32, edit : Int32, shape : Int32) -> Int32 {
  tx_event(
    s,
    edit,
    Json::object({ "type": Json("shape"), "value": Json(shape) }),
  )
}

///|
fn prop_ui(s : Int32, e : Int32, event : Json) -> Int32 {
  text_ui_event(
    s,
    e,
    text_value(s, e, 0).to_int(),
    event.stringify(),
    text_value(s, e, 13),
    text_value(s, e, 14),
  )
}

///|
fn prop_frame(s : Int32, e : Int32) -> Map[String, Json] {
  tx_object(
    text_frame(s, e, 0, text_value(s, e, 13), text_value(s, e, 14), 1, 0),
  )
}

///|
fn prop_node(frame : Map[String, Json], id : String) -> Map[String, Json] {
  match frame.get("semantics") {
    Some(Array(nodes)) =>
      for node in nodes {
        if node is Object(m) && m.get("id") == Some(Json(id)) {
          return m
        }
      }
    _ => ()
  }
  abort("Missing property semantic")
}

///|
fn prop_commit(s : Int32, e : Int32) -> Int32 {
  let ticket = tx_prepare(s, e, 1, 0)
  if ticket == 0 {
    return 0
  }
  candidate_commit(s, ticket)
}

///|
test "nontext defaults use shared fields and candidate publication without touching document history" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let before = image_session_document(s)
  let e = prop_begin(s, bank, 1, "")
  assert_true(e > 0)
  assert_eq(text_value(s, e, 15), 1)
  assert_eq(tx_replace(s, e, "style.stroke", "4.75"), 1)
  assert_eq(tx_replace(s, e, "style.opacity", "25"), 1)
  assert_eq(prop_shape(s, e, 1), 1)
  assert_eq(text_value(s, e, 16), 4.75)
  assert_eq(text_value(s, e, 17), 1)
  assert_eq(image_session_document(s), before)
  assert_eq(editor_style_get(bank, 1, 2), 4)
  let preview = tx_prepare(s, e, 0, 0)
  assert_true(preview > 0)
  assert_eq(candidate_commit(s, preview), 0)
  assert_eq(candidate_document(preview), before)
  assert_eq(prop_commit(s, e), 1)
  assert_eq(editor_style_get(bank, 1, 2), 4.75)
  assert_eq(editor_style_get(bank, 1, 1), 0.25)
  assert_eq(editor_style_get(bank, 1, 4), 1)
  assert_eq(editor_style_get(bank, 2, 2), 4)
  assert_eq(image_session_document(s), before)
  let next = prop_begin(s, bank, 2, "")
  assert_eq(tx_replace(s, next, "style.stroke", "9.5"), 1)
  assert_eq(text_cancel(s, next, text_value(s, next, 0).to_int()), 1)
  assert_eq(editor_style_get(bank, 2, 2), 4)
  tx_cleanup(s, bank)
}

///|
test "existing arrow style preserves exact endpoints metadata and fractional values in one undo" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  assert_eq(
    image_session_command(
      s, 0, "{\"type\":\"add\",\"annotations\":[{\"id\":\"a\",\"type\":\"arrow\",\"x\":300,\"y\":200,\"x2\":40,\"y2\":50,\"stroke\":3.5,\"opacity\":0.123,\"color\":\"#AABBCC\",\"arrowHead\":\"both\"}]}",
    ),
    1,
  )
  let original = image_session_document(s)
  assert_eq(prop_begin(s, bank, 1, "a"), 0)
  let noop = prop_begin(s, bank, 2, "a")
  assert_eq(prop_commit(s, noop), 1)
  assert_eq(image_session_document(s), original)
  let e = prop_begin(s, bank, 2, "a")
  assert_eq(tx_replace(s, e, "style.stroke", "-"), 1)
  assert_eq(tx_prepare(s, e, 0, 0), 0)
  assert_eq(prop_commit(s, e), 0)
  assert_eq(tx_replace(s, e, "style.stroke", "5.25"), 1)
  assert_eq(
    tx_event(
      s,
      e,
      Json::object({ "type": Json("color"), "rgb": Json(0x123456) }),
    ),
    1,
  )
  let preview = tx_object(text_text(s, e, 3))
  assert_eq(preview.get("x2"), Some(Json(40)))
  assert_eq(preview.get("y2"), Some(Json(50)))
  assert_eq(preview.get("arrowHead"), Some(Json("both")))
  assert_eq(preview.get("stroke"), Some(Json(5.25)))
  assert_eq(image_session_document(s), original)
  assert_eq(prop_commit(s, e), 1)
  assert_eq(image_session_revision(s), 2)
  assert_eq(editor_style_get(bank, 2, 2), 4)
  assert_eq(image_session_undo(s), 1)
  let restored = tx_object(image_session_document(s))
  assert_eq(restored.get("annotations"), tx_object(original).get("annotations"))
  tx_cleanup(s, bank)
}

///|
test "cover shape transition cannot hide invalid input and mosaic publishes shape plus pixels atomically" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  assert_eq(
    image_session_add_rgba(s, 4, 20, 30, 80, 90, 0x123456, 4, 24, 0.4),
    1,
  )
  let original = image_session_document(s)
  let e = prop_begin(s, bank, 4, image_session_annotation_id(s, 0))
  let opacity_token = tx_field(s, e, "style.opacity")["token"]
  assert_eq(tx_replace(s, e, "style.opacity", "-"), 1)
  assert_eq(prop_shape(s, e, 2), 0)
  assert_eq(
    prop_ui(
      s,
      e,
      Json::object({ "type": Json("activate"), "id": Json("style.shape.2") }),
    ),
    0,
  )
  assert_eq(
    prop_node(prop_frame(s, e), "style.shape.2").get("enabled"),
    Some(Json(false)),
  )
  assert_eq(text_value(s, e, 17), 0)
  assert_eq(tx_replace(s, e, "style.opacity", "40"), 1)
  assert_eq(prop_shape(s, e, 2), 1)
  assert_eq(text_value(s, e, 19), 48)
  assert_eq(tx_field(s, e, "style.opacity")["token"], opacity_token)
  assert_eq(tx_replace(s, e, "style.opacity", "25"), 0)
  assert_eq(
    tx_event(s, e, Json::object({ "type": Json("color"), "rgb": Json(0) })),
    0,
  )
  assert_eq(tx_replace(s, e, "style.blockSize", "16.5"), 1)
  assert_eq(prop_shape(s, e, 0), 0)
  assert_eq(prop_commit(s, e), 0)
  assert_eq(tx_replace(s, e, "style.blockSize", "16"), 1)
  let preview = tx_object(text_text(s, e, 3))
  assert_eq(preview.get("type"), Some(Json("mosaic")))
  assert_eq(preview.get("opacity"), Some(Json(1)))
  assert_eq(preview.get("blockSize"), Some(Json(16)))
  assert_eq(image_session_document(s), original)
  assert_eq(prop_commit(s, e), 1)
  assert_eq(image_session_revision(s), 2)
  assert_eq(image_session_value(s, 0, 9), 2)
  assert_eq(image_session_value(s, 0, 10), 16)
  assert_eq(editor_style_get(bank, 4, 4), 0)
  assert_eq(image_session_undo(s), 1)
  assert_eq(
    tx_object(image_session_document(s)).get("annotations"),
    tx_object(original).get("annotations"),
  )
  assert_eq(image_session_redo(s), 1)
  assert_eq(image_session_value(s, 0, 9), 2)
  tx_cleanup(s, bank)
}

///|
test "shape pointer sequence IME veto and hidden fields keep identity across descriptor changes" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let e = prop_begin(s, bank, 4, "")
  assert_eq(tx_replace(s, e, "style.opacity", "30"), 1)
  let original_field = tx_field(s, e, "style.opacity")
  assert_eq(
    tx_field_event(
      s,
      e,
      "style.opacity",
      Json::object({
        "type": Json("compositionStart"),
        "start": Json(0),
        "end": Json(2),
        "selection": Json::object({ "kind": Json("unknown") }),
      }),
    ),
    1,
  )
  assert_eq(prop_shape(s, e, 2), 0)
  assert_eq(
    tx_field_event(
      s,
      e,
      "style.opacity",
      Json::object({ "type": Json("compositionCancel") }),
    ),
    1,
  )
  let node = prop_node(prop_frame(s, e), "style.shape.2")
  let x = image_number(node, "x", 0) + 13
  let y = image_number(node, "y", 0) + 12
  assert_eq(
    prop_ui(
      s,
      e,
      Json::object({ "type": Json("pointerDown"), "x": Json(x), "y": Json(y) }),
    ),
    1,
  )
  assert_eq(
    prop_ui(
      s,
      e,
      Json::object({
        "type": Json("pointerUp"),
        "x": Json(x - 26),
        "y": Json(y),
      }),
    ),
    1,
  )
  assert_eq(text_value(s, e, 17), 0)
  assert_eq(
    prop_ui(
      s,
      e,
      Json::object({ "type": Json("pointerDown"), "x": Json(x), "y": Json(y) }),
    ),
    1,
  )
  assert_eq(
    prop_ui(
      s,
      e,
      Json::object({ "type": Json("pointerUp"), "x": Json(x), "y": Json(y) }),
    ),
    1,
  )
  assert_eq(text_value(s, e, 17), 2)
  assert_eq(prop_shape(s, e, 0), 1)
  let restored = tx_field(s, e, "style.opacity")
  assert_eq(restored.get("raw"), original_field.get("raw"))
  assert_eq(restored.get("token"), original_field.get("token"))
  assert_eq(text_value(s, e, 10), 1)
  assert_eq(tx_event(s, e, Json::object({ "type": Json("undo") })), 1)
  assert_eq(text_value(s, e, 17), 2)
  assert_eq(tx_event(s, e, Json::object({ "type": Json("redo") })), 1)
  assert_eq(text_value(s, e, 17), 0)
  assert_eq(editor_style_get(bank, 4, 4), 0)
  tx_cleanup(s, bank)
}

///|
test "contribution owner fixes numbered rectangle shape without changing ordinary defaults" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  assert_eq(editor_style_set(bank, 1, 4, 1), 1)
  assert_eq(properties_begin(s, bank, 1, "", 0, "unknown.command"), 0)
  assert_eq(properties_begin(s, bank, 4, "", 0, "capture.numberedRectangle"), 0)
  let e = properties_begin(s, bank, 1, "", 0, "capture.numberedRectangle")
  assert_true(e > 0)
  assert_eq(text_value(s, e, 17), 0)
  assert_eq(text_value(s, e, 19), 7)
  assert_eq(prop_shape(s, e, 1), 0)
  assert_eq(tx_replace(s, e, "style.stroke", "6.5"), 1)
  assert_eq(prop_commit(s, e), 1)
  assert_eq(editor_style_get(bank, 1, 4), 1)
  assert_eq(editor_style_get(bank, 1, 2), 6.5)
  tx_cleanup(s, bank)
}

///|
test "mixed text and shape candidates publish together only after all versions still match" {
  let a = image_session_create(640, 480)
  let b = image_session_create(640, 480)
  let sa = editor_style_create()
  let sb = editor_style_create()
  let ea = tx_begin(a, sa, 1, "")
  assert_eq(tx_replace(a, ea, "annotation.text", "shared 🌙"), 1)
  let eb = prop_begin(b, sb, 1, "")
  assert_eq(tx_replace(b, eb, "style.stroke", "7.25"), 1)
  let ca = tx_prepare(a, ea, 1, 35)
  let cb = tx_prepare(b, eb, 1, 0)
  let request = Json::array([
    Json::object({ "session": Json(a), "candidate": Json(ca) }),
    Json::object({ "session": Json(b), "candidate": Json(cb) }),
  ]).stringify()
  assert_eq(tx_replace(b, eb, "style.stroke", "8.25"), 1)
  assert_eq(candidate_commit_many(request), 0)
  assert_eq(image_session_count(a), 0)
  assert_eq(editor_style_get(sb, 1, 2), 4)
  let cb2 = tx_prepare(b, eb, 1, 0)
  assert_eq(
    candidate_commit_many(
      Json::array([
        Json::object({ "session": Json(a), "candidate": Json(ca) }),
        Json::object({ "session": Json(b), "candidate": Json(cb2) }),
      ]).stringify(),
    ),
    1,
  )
  assert_eq(image_session_count(a), 1)
  assert_eq(editor_style_get(sb, 1, 2), 8.25)
  assert_eq(text_event_json(b, eb, 0, "{}"), 0)
  tx_cleanup(a, sa)
  tx_cleanup(b, sb)
}

///|
test "property frame validates on the shared ABI and renders shape label circle gap and four mosaic shades" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let e = prop_begin(s, bank, 4, "")
  let frame = prop_frame(s, e)
  let color = prop_node(frame, "style.color")
  assert_eq(color.get("width"), Some(Json(22)))
  assert_eq(color.get("height"), Some(Json(22)))
  let shape = prop_node(frame, "style.shape.2")
  assert_eq(
    image_number(color, "x", 0) - (image_number(shape, "x", 0) + 26),
    40,
  ) // group 8 + color label 26 + label gap 6
  let commands = match frame.get("commands") {
    Some(Array(a)) => a
    _ => []
  }
  let shades : Map[String, Bool] = Map([])
  let mut shape_label = false
  for command in commands {
    if command is Object(c) {
      if c.get("text") == Some(Json("形状")) {
        shape_label = true
      }
      if image_number(c, "width", 0) == 7 && image_number(c, "height", 0) == 7 {
        shades[image_string(c, "fill", "")] = true
      }
    }
  }
  assert_true(shape_label)
  assert_eq(shades.length(), 4)
  for dark in [0, 1] {
    let json = text_frame(s, e, 0, text_value(s, e, 13), 34, 1, dark)
    let handle = @ui_frame.open(json)
    assert_true(handle > 0)
    assert_eq(@ui_frame.field_count(handle), 1)
    assert_eq(@ui_frame.field_text(handle, 0, 0), "style.opacity")
    assert_eq(@ui_frame.close(handle), 1)
  }
  assert_eq(prop_shape(s, e, 2), 1)
  let handle = @ui_frame.open(
    text_frame(s, e, 0, text_value(s, e, 13), 34, 1, 0),
  )
  assert_true(handle > 0)
  assert_eq(@ui_frame.field_count(handle), 1)
  assert_eq(@ui_frame.field_text(handle, 0, 0), "style.blockSize")
  assert_eq(@ui_frame.close(handle), 1)
  tx_cleanup(s, bank)
}
