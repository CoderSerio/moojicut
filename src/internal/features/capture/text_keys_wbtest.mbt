///|
test "native numeric arrow keys share range, draft history and IME rules" {
  let session = image_session_create(640, 480)
  let style = editor_style_create()
  let initial_font = editor_style_get(style, 3, 3)
  let edit = tx_begin(session, style, 0, "")
  let original = image_session_document(session)
  let up = @ui_frame.input_event(6, 0, 0, 0, 0, 0, "ArrowUp")
  let down = @ui_frame.input_event(6, 0, 0, 0, 0, 0, "ArrowDown")
  let key = fn(event : String) {
    text_ui_event(
      session,
      edit,
      text_value(session, edit, 0).to_int(),
      event,
      271,
      34,
    )
  }
  // No field focused: do not hijack the native key.
  assert_eq(key(up), 0)
  assert_eq(tx_replace(session, edit, "style.fontSize", "31.25"), 1)
  assert_eq(key(up), 1)
  assert_eq(text_value(session, edit, 4), 32.25)
  assert_eq(key(down), 1)
  assert_eq(text_value(session, edit, 4), 31.25)
  assert_eq(key(@ui_frame.input_event(6, 0, 0, 0, 0, 1, "ArrowUp")), 0)
  assert_eq(tx_replace(session, edit, "style.fontSize", "-"), 1)
  assert_eq(key(up), 0)
  assert_eq(
    image_string(tx_field(session, edit, "style.fontSize"), "raw", ""),
    "-",
  )
  assert_eq(tx_replace(session, edit, "style.opacity", "99"), 1)
  assert_eq(key(up), 1)
  assert_eq(text_value(session, edit, 3), 1)
  assert_eq(key(up), 1)
  assert_eq(text_value(session, edit, 3), 1)
  assert_eq(
    tx_field_event(
      session,
      edit,
      "style.opacity",
      Json::object({
        "type": Json("compositionStart"),
        "start": Json(0),
        "end": Json(3),
        "selection": Json::object({ "kind": Json("unknown") }),
      }),
    ),
    1,
  )
  assert_eq(key(down), 0)
  assert_eq(image_session_document(session), original)
  assert_eq(editor_style_get(style, 3, 1), 1)
  assert_eq(editor_style_get(style, 3, 3), initial_font)
  assert_eq(
    text_cancel(session, edit, text_value(session, edit, 0).to_int()),
    1,
  )
  let body = tx_begin(session, style, 1, "")
  assert_eq(text_ui_event(session, body, 0, up, 271, 34), 0)
  image_session_dispose(session)
  editor_style_dispose(style)
}
