///|
test "declarative drag command commits two existing shapes as one undoable edit" {
  let id = image_session_create(320, 240)
  assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 20, 30, 0x123456, 4, 0.5, 1, 12), 1)
  assert_eq(image_session_shape_event(id, 0, 140, 100), 1)
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_preview_value(id, 0), 1)
  assert_eq(image_session_preview_value(id, 9), 0)
  assert_eq(image_session_shape_event(id, 1, 140, 100), 1)
  assert_eq(image_session_count(id), 2)
  assert_eq(image_session_value(id, 0, 0), 1)
  assert_eq(image_session_value(id, 1, 0), 3)
  assert_eq(image_session_text(id, 1), "1")
  assert_eq(image_session_value(id, 1, 5), (0x123456).to_double())
  assert_eq(image_session_value(id, 1, 8), 0.5)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_count(id), 2)
  assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 40, 50, 0, 4, 1, 0, 12), 1)
  assert_eq(image_session_shape_event(id, 2, 80, 90), 1)
  assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 40, 50, 0, 4, 1, 0, 12), 1)
  assert_eq(image_session_shape_event(id, 1, 80, 90), 1)
  assert_eq(image_session_text(id, 3), "2")
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 2)
  image_session_dispose(id)
}

///|
test "stale or unknown contributions do not mutate the image or consume a number" {
  let id = image_session_create(320, 240)
  assert_eq(image_session_tool_begin(id, "unknown", 20, 30, 0, 4, 1, 0, 12), 0)
  assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 20, 30, 0, 4, 1, 0, 12), 1)
  assert_eq(image_session_add(id, 1, 10, 10, 30, 30, 0, 3), 1)
  assert_eq(image_session_shape_event(id, 1, 140, 100), 0)
  assert_eq(image_session_count(id), 1)
  assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 20, 30, 0, 4, 1, 0, 12), 1)
  assert_eq(image_session_shape_event(id, 1, 140, 100), 1)
  assert_eq(image_session_text(id, 2), "1")
  image_session_dispose(id)
}

///|
test "JSON and typed contribution hosts produce the same validated atomic command" {
  let id = image_session_create(320, 240)
  let rectangle = Json::object({ "type": Json("rect"), "x": Json(20), "y": Json(30),
    "width": Json(120), "height": Json(70), "color": Json("#123456"), "stroke": Json(4), "opacity": Json(0.5) })
  let doc = Json::object(native_image_sessions[id].document)
  let request = Json::object({ "document": doc, "expectedRevision": Json(0),
    "command": Json("capture.numberedRectangle"), "rectangle": rectangle })
  let response = @json.parse(@annotation_tools.contribution_command_json(request.stringify())) catch { _ => Json::null() }
  let command = match response { Object({ "ok": True, "command": command, .. }) => command; _ => abort("expected valid command") }
  assert_eq(Json::object(native_image_sessions[id].document), doc)
  assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 20, 30, 0x123456, 4, 0.5, 0, 12), 1)
  assert_eq(image_session_shape_event(id, 1, 140, 100), 1)
  let generated = match command { Object({ "annotations": annotations, .. }) => annotations; _ => Json::null() }
  // Reducer fills normalized defaults; compare through that same authoritative reducer.
  let applied = native_image_document(@image.image_apply(Json::object({ "document": doc,
    "expectedRevision": Json(0), "command": command }).stringify())).unwrap()
  assert_eq(applied["annotations"], Json::array(native_image_annotations(id)))
  assert_true(generated != Json::null())
  let stale = @json.parse(@annotation_tools.contribution_command_json(Json::object({
    "document": Json::object(native_image_sessions[id].document), "expectedRevision": Json(0),
    "command": Json("capture.numberedRectangle"), "rectangle": rectangle }).stringify())) catch { _ => Json::null() }
  assert_eq(@test_support.model_test_field(stale, "ok"), Json(false))
  image_session_dispose(id)
}

///|
test "small numbered gestures do not consume history and labels fit multiple digits" {
  let id = image_session_create(320, 240)
  let original = Json::object(native_image_sessions[id].document)
  for size in [(2.0, 4.0), (4.0, 80.0), (80.0, 4.0)] {
    assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 20, 20, 0, 4, 1, 0, 12), 1)
    assert_eq(image_session_shape_event(id, 1, 20 + size.0, 20 + size.1), 0)
    assert_eq(image_session_count(id), 0)
    assert_eq(Json::object(native_image_sessions[id].document), original)
  }
  for i in 1..=10 {
    assert_eq(image_session_tool_begin(id, "capture.numberedRectangle", 20, 20, 0, 4, 1, 0, 12), 1)
    assert_eq(image_session_shape_event(id, 1, 60, 60), 1)
    assert_eq(image_session_text(id, i * 2 - 1), i.to_string())
  }
  let label = match native_image_annotations(id)[19] {
    Object(fields) => fields
    _ => abort("expected numbered label")
  }
  let width = match label["width"] { Number(n, ..) => n; _ => 0.0 }
  let height = match label["height"] { Number(n, ..) => n; _ => 0.0 }
  let font = match label["fontSize"] { Number(n, ..) => n; _ => 0.0 }
  assert_true(font >= 8 && font * 2 <= width && font * 1.5 <= height)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 18)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_text(id, 19), "10")
  image_session_dispose(id)
}

///|
test "JSON contributions reject off-canvas rectangles without changing the document" {
  let id = image_session_create(320, 240)
  let doc = Json::object(native_image_sessions[id].document)
  for rect in [(300, 20, 40, 40), (20, 220, 40, 40), (400, 300, 40, 40), (-1, 20, 40, 40)] {
    let response = @json.parse(@annotation_tools.contribution_command_json(Json::object({
      "document": doc, "expectedRevision": Json(0), "command": Json("capture.numberedRectangle"),
      "rectangle": Json::object({ "x": Json(rect.0), "y": Json(rect.1),
        "width": Json(rect.2), "height": Json(rect.3) }),
    }).stringify())) catch { _ => Json::null() }
    assert_eq(@test_support.model_test_field(response, "ok"), Json(false))
  }
  assert_eq(Json::object(native_image_sessions[id].document), doc)
  assert_eq(image_session_count(id), 0)
  image_session_dispose(id)
}
