///|
test "geometry preserves fractional text style, stable ID and undo without pending text" {
  let session = image_session_create(640, 480)
  let id = "note\"中"
  let annotation : Json = Json::object({
    "id": Json(id),
    "type": Json("text"),
    "text": Json("第一行\r\nemoji 😀"),
    "x": Json(10.25),
    "y": Json(20.5),
    "width": Json(200.75),
    "height": Json(100.125),
    "fontSize": Json(31.25),
    "color": Json("#ABCDEF"),
    "opacity": Json(0.123),
  })
  assert_eq(
    image_session_command(
      session,
      0,
      Json::object({
        "type": Json("add"),
        "annotations": Json::array([annotation]),
      }).stringify(),
    ),
    1,
  )
  let original = image_session_document(session)
  let revision = image_session_revision(session)
  assert_eq(
    image_session_geometry(
      session, revision, id, 10.25, 20.5, 200.75, 100.125, -1,
    ),
    1,
  )
  assert_eq(image_session_document(session), original)
  // Poison the old two-step text slot: geometry must not consume it.
  assert_eq(image_session_set_text(session, "unrelated pending text"), 1)
  assert_eq(
    image_session_geometry(
      session, revision, id, 30.5, 40.25, 200.75, 100.125, -1,
    ),
    1,
  )
  let moved = native_image_annotation(session, 0).unwrap()
  assert_eq(moved["text"], Json("第一行\r\nemoji 😀"))
  assert_eq(moved["fontSize"], Json(31.25))
  assert_eq(moved["color"], Json("#ABCDEF"))
  assert_eq(moved["opacity"], Json(0.123))
  assert_eq(
    image_session_geometry(session, revision, id, 0, 0, 200, 100, -1),
    0,
  )
  let moved_revision = image_session_revision(session)
  assert_eq(
    image_session_geometry(
      session, moved_revision, "missing", 0, 0, 200, 100, -1,
    ),
    0,
  )
  assert_eq(
    image_session_geometry(session, moved_revision, id, 0, 0, 0, 100, -1),
    0,
  )
  assert_eq(
    image_session_geometry(
      session,
      moved_revision,
      id,
      0,
      0,
      200,
      100,
      1.0 / 0.0,
    ),
    0,
  )
  assert_eq(image_session_revision(session), moved_revision)
  assert_eq(
    image_session_geometry(
      session, moved_revision, id, 30.5, 40.25, 300, 150, 46.875,
    ),
    1,
  )
  assert_eq(image_session_value(session, 0, 7), 46.875)
  assert_eq(image_session_undo(session), 1)
  assert_eq(image_session_value(session, 0, 7), 31.25)
  assert_eq(image_session_value(session, 0, 1), 30.5)
  assert_eq(image_session_undo(session), 1)
  assert_eq(image_session_value(session, 0, 1), 10.25)
  let style = editor_style_create()
  let edit = text_begin(
    session,
    style,
    2,
    id,
    image_session_revision(session),
    0,
    0,
    1,
    1,
  )
  assert_true(edit > 0)
  assert_eq(
    image_session_geometry(
      session,
      image_session_revision(session),
      id,
      0,
      0,
      200,
      100,
      -1,
    ),
    0,
  )
  assert_eq(text_cancel(session, edit, 0), 1)
  image_session_dispose(session)
  editor_style_dispose(style)
}

///|
test "geometry maps signed arrow extents through the existing reducer" {
  let session = image_session_create(640, 480)
  assert_eq(image_session_add(session, 2, 100, 80, -30, 20, 0x123456, 3), 1)
  let id = image_session_annotation_id(session, 0)
  let revision = image_session_revision(session)
  assert_eq(
    image_session_geometry(
      session, revision, id, 90.5, 70.25, -50.5, -20.25, -1,
    ),
    1,
  )
  let arrow = native_image_annotation(session, 0).unwrap()
  assert_eq(arrow["x2"], Json(40))
  assert_eq(arrow["y2"], Json(50))
  assert_eq(image_session_value(session, 0, 3), -50.5)
  assert_eq(image_session_value(session, 0, 4), -20.25)
  let current = image_session_revision(session)
  assert_eq(
    image_session_geometry(session, current, id, 90.5, 70.25, -50.5, -20.25, 24),
    0,
  )
  assert_eq(image_session_geometry(session, current, id, 65536, 0, 1, 1, -1), 0)
  assert_eq(image_session_revision(session), current)
  image_session_dispose(session)
}
