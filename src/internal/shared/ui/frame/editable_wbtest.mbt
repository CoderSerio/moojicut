///|
fn input_fixture() -> Map[String, Json] {
  {
    "id": Json("caption"),
    "token": Json(9),
    "version": Json(3),
    "raw": Json("你🌙\n好"),
    "selection": Json::object({ "kind": Json("unknown") }),
    "marked": Json::object({ "start": Json(0), "end": Json(3) }),
    "x": Json(4),
    "y": Json(5),
    "width": Json(100),
    "height": Json(40),
    "fontSize": Json(0.25),
    "weight": Json("semibold"),
    "color": Json("#123456"),
    "opacity": Json(0.35),
    "multiline": Json(true),
    "label": Json("文字"),
    "focused": Json(true),
  }
}

///|
fn input_frame(fields : Array[Json], semantics~ : Array[Json] = []) -> String {
  Json::object({
    "ok": Json(true),
    "commands": Json::array([]),
    "editableFields": Json::array(fields),
    "semantics": Json::array(semantics),
  }).stringify()
}

///|
test "editable snapshots preserve unknown IME selection style and ownership after field retirement" {
  let h = open(input_frame([Json::object(input_fixture())]))
  assert_true(h > 0)
  assert_eq(field_count(h), 1)
  assert_eq(field_value(h, 0, 0), 9)
  assert_eq(field_value(h, 0, 1), 3)
  assert_eq(field_value(h, 0, 6), 0)
  assert_eq(field_value(h, 0, 7), 0)
  assert_eq(field_value(h, 0, 8), 0)
  assert_eq(field_value(h, 0, 10), 0)
  assert_eq(field_value(h, 0, 11), 3)
  assert_eq(field_value(h, 0, 15), 3)
  assert_eq(field_number(h, 0, 4), 4)
  assert_eq(field_number(h, 0, 8), 0.25)
  assert_eq(field_number(h, 0, 9), 0.35)
  let retained = field_text(h, 0, 1)
  assert_eq(retained, "你🌙\n好")
  assert_eq(field_text(h, 0, 3), "文字")
  assert_eq(close(h), 1)
  assert_eq(field_count(h), -1)
  assert_eq(field_value(h, 0, 0), -1)
  assert_eq(field_number(h, 0, 0), 0)
  assert_eq(field_text(h, 0, 0), "")
  assert_eq(retained, "你🌙\n好")
}

///|
test "invalid editable ranges identity and native accessibility conflicts reject the entire frame" {
  let field = input_fixture()
  let live = open(input_frame([Json::object(field)]))
  for
    (key, invalid) in [
      ("raw", Json("a\r\nb")),
      ("token", Json(9.5)),
      ("version", Json(-1)),
      ("fontSize", Json(0)),
      ("opacity", Json(2)),
      ("weight", Json("heavy")),
      ("enabled", Json(false)),
      ("canUndo", Json(true)),
      (
        "selection",
        Json::object({ "kind": Json("unknown"), "anchor": Json(0) }),
      ),
      (
        "selection",
        Json::object({
          "kind": Json("directed"),
          "anchor": Json(2),
          "focus": Json(3),
        }),
      ),
      (
        "selection",
        Json::object({
          "kind": Json("undirected"),
          "anchor": Json(3),
          "focus": Json(0),
        }),
      ),
      (
        "selection",
        Json::object({
          "kind": Json("directed"),
          "anchor": Json(5),
          "focus": Json(5),
        }),
      ),
      ("marked", Json::object({ "start": Json(1), "end": Json(2) })),
    ] {
    let previous = field.get(key)
    field[key] = invalid
    assert_eq(open(input_frame([Json::object(field)])), 0)
    match previous {
      Some(value) => field[key] = value
      None => field.remove(key)
    }
  }
  assert_eq(open(input_frame([Json::object(field), Json::object(field)])), 0)
  let another = input_fixture()
  another["id"] = Json("other")
  assert_eq(open(input_frame([Json::object(field), Json::object(another)])), 0)
  another["token"] = Json(10)
  assert_eq(open(input_frame([Json::object(field), Json::object(another)])), 0)
  another["focused"] = Json(false)
  let two = open(input_frame([Json::object(field), Json::object(another)]))
  assert_true(two > 0)
  assert_eq(close(two), 1)
  assert_eq(
    open(
      input_frame([Json::object(field)], semantics=[
        Json::object({
          "id": Json("caption"),
          "role": Json("staticText"),
          "x": Json(0),
          "y": Json(0),
          "width": Json(100),
          "height": Json(40),
        }),
      ]),
    ),
    0,
  )
  assert_eq(field_text(live, 0, 1), "你🌙\n好")
  assert_eq(close(live), 1)
}

///|
test "native text event encoder carries exact field identity and UTF16 facts without document effects" {
  let encoded = text_event(1, "caption", 91, 12, 1, 3, "你🌙\n", 2, 5, 5)
  let event = object(@json.parse(encoded))
  assert_eq(event["type"], Json("field"))
  assert_eq(event["id"], Json("caption"))
  assert_eq(event["token"], Json(91))
  assert_eq(event["expectedVersion"], Json(12))
  let edit = object(event["edit"])
  assert_eq(edit["start"], Json(1))
  assert_eq(edit["text"], Json("你🌙\n"))
  assert_eq(object(edit["selection"])["kind"], Json("undirected"))
  let unknown = object(
    @json.parse(text_event(4, "caption", 91, 13, 0, 0, "你好", 0, 0, 0)),
  )
  assert_eq(object(object(unknown["edit"])["selection"]).length(), 1)
  let undo = object(
    @json.parse(text_event(7, "caption", 91, 14, 0, 0, "", 0, 0, 0)),
  )
  assert_eq(object(undo["edit"])["type"], Json("undo"))
  assert_false(object(undo["edit"]).contains("selection"))
  assert_eq(text_event(1, "caption", 0, 0, 0, 0, "", 0, 0, 0), "")
  assert_eq(text_event(1, "caption", 1, 0, 0, 0, "a\r\nb", 0, 0, 0), "")
  assert_eq(
    text_event(
      1,
      "caption",
      1,
      0,
      0,
      0,
      "🌙".unsafe_substring(start=0, end=1),
      0,
      0,
      0,
    ),
    "",
  )
  assert_eq(text_event(3, "caption", 1, 0, 3, 1, "", 0, 0, 0), "")
  assert_eq(text_event(2, "caption", 1, 0, 0, 0, "", 0, 1, 1), "")
  assert_eq(text_event(7, "caption", 1, 0, 0, 0, "", 1, 0, 0), "")
  assert_eq(text_event(8, "caption", 1, 0, 0, 0, "not empty", 0, 0, 0), "")
}
