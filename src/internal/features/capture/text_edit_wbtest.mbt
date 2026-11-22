///|
fn tx_object(text : String) -> Map[String, Json] {
  match (@json.parse(text) catch { _ => abort("Expected transaction JSON") }) {
    Object(m) => m
    _ => abort("Expected transaction object")
  }
}

///|
fn tx_field(session : Int32, edit : Int32, id : String) -> Map[String, Json] {
  let snapshot = tx_object(text_snapshot(session, edit))
  match snapshot.get("fields") {
    Some(Array(items)) =>
      for item in items {
        if item is Object(m) && m.get("id") == Some(Json(id)) {
          return m
        }
      }
    _ => ()
  }
  abort("Expected an editable field")
}

///|
fn tx_event(session : Int32, edit : Int32, event : Json) -> Int32 {
  text_event_json(
    session,
    edit,
    text_value(session, edit, 0).to_int(),
    event.stringify(),
  )
}

///|
fn tx_field_event(
  session : Int32,
  edit : Int32,
  id : String,
  event : Json,
) -> Int32 {
  let field = tx_field(session, edit, id)
  tx_event(
    session,
    edit,
    Json::object({
      "type": Json("field"),
      "id": Json(id),
      "token": field["token"],
      "expectedVersion": field["version"],
      "edit": event,
    }),
  )
}

///|
fn tx_replace(
  session : Int32,
  edit : Int32,
  id : String,
  text : String,
) -> Int32 {
  let raw = image_string(tx_field(session, edit, id), "raw", "")
  tx_field_event(
    session,
    edit,
    id,
    Json::object({
      "type": Json("replace"),
      "start": Json(0),
      "end": Json(raw.length()),
      "text": Json(text),
      "selection": Json::object({ "kind": Json("unknown") }),
    }),
  )
}

///|
fn tx_prepare(
  session : Int32,
  edit : Int32,
  purpose : Int32,
  height : Double,
) -> Int32 {
  text_prepare(
    session,
    edit,
    text_value(session, edit, 0).to_int(),
    purpose,
    height,
  )
}

///|
fn tx_begin(session : Int32, style : Int32, mode : Int32, id : String) -> Int32 {
  text_begin(
    session,
    style,
    mode,
    id,
    image_session_revision(session),
    10,
    20,
    200,
    40,
  )
}

///|
fn tx_cleanup(session : Int32, style : Int32) -> Unit {
  image_session_dispose(session)
  editor_style_dispose(style)
}

///|
test "text defaults remain drafts until one checked publication and cancel preserves the bank" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let before = image_session_document(s)
  let e = tx_begin(s, style, 0, "")
  assert_true(e > 0)
  assert_eq(tx_replace(s, e, "style.fontSize", "31.25"), 1)
  assert_eq(tx_replace(s, e, "style.opacity", "12.3"), 1)
  assert_eq(
    tx_event(
      s,
      e,
      Json::object({ "type": Json("color"), "rgb": Json(0x123456) }),
    ),
    1,
  )
  assert_eq(editor_style_get(style, 3, 3), 32)
  assert_eq(editor_style_get(style, 3, 1), 1)
  assert_eq(image_session_document(s), before)
  let candidate = tx_prepare(s, e, 1, 0)
  assert_true(candidate > 0)
  assert_eq(candidate_document(candidate), before)
  assert_eq(candidate_ready(s, candidate), 1)
  assert_eq(candidate_commit(s, candidate), 1)
  assert_eq(editor_style_get(style, 3, 3), 31.25)
  assert_true((editor_style_get(style, 3, 1) - 0.123).abs() < 0.000000000001)
  assert_eq(editor_style_get(style, 3, 0), (0x123456).to_double())
  assert_eq(image_session_document(s), before)
  assert_eq(text_value(s, e, 0), -1)
  assert_eq(candidate_commit(s, candidate), 0)
  let cancelled = tx_begin(s, style, 0, "")
  assert_eq(tx_replace(s, cancelled, "style.fontSize", "48"), 1)
  assert_eq(text_cancel(s, cancelled, text_value(s, cancelled, 0).to_int()), 1)
  assert_eq(editor_style_get(style, 3, 3), 31.25)
  assert_eq(image_session_document(s), before)
  tx_cleanup(s, style)
}

///|
test "new Unicode composition and fractional RGBA publish as one image undo with read-only PNG candidate" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let before = image_session_document(s)
  let e = tx_begin(s, style, 1, "")
  let id = text_text(s, e, 0)
  assert_true(id != "")
  let unknown = Json::object({ "kind": Json("unknown") })
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({
        "type": Json("compositionStart"),
        "start": Json(0),
        "end": Json(0),
        "selection": unknown,
      }),
    ),
    1,
  )
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({
        "type": Json("compositionUpdate"),
        "text": Json("ni"),
        "selection": unknown,
      }),
    ),
    1,
  )
  let composing = text_snapshot(s, e)
  let composing_frame = @ui_frame.open(text_frame(s, e, 1, 200, 40, 1, 0))
  assert_true(composing_frame > 0)
  assert_eq(@ui_frame.field_count(composing_frame), 1)
  assert_eq(@ui_frame.field_value(composing_frame, 0, 6), 0)
  assert_eq(@ui_frame.field_value(composing_frame, 0, 10), 0)
  assert_eq(@ui_frame.field_value(composing_frame, 0, 11), 2)
  assert_eq(@ui_frame.field_value(composing_frame, 0, 13), 0)
  assert_eq(@ui_frame.close(composing_frame), 1)
  assert_eq(tx_prepare(s, e, 0, 40), 0)
  assert_eq(tx_prepare(s, e, 1, 40), 0)
  assert_eq(text_snapshot(s, e), composing)
  assert_eq(image_session_document(s), before)
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({
        "type": Json("compositionCommit"),
        "text": Json("你好\n🌙"),
        "selection": unknown,
      }),
    ),
    1,
  )
  assert_eq(tx_replace(s, e, "style.fontSize", "31.25"), 1)
  assert_eq(tx_replace(s, e, "style.opacity", "35"), 1)
  assert_eq(
    tx_event(
      s,
      e,
      Json::object({ "type": Json("color"), "rgb": Json(0x112233) }),
    ),
    1,
  )
  let snapshot = text_snapshot(s, e)
  let preview = tx_prepare(s, e, 0, 66.5)
  assert_true(preview > 0)
  let preview_document = candidate_document(preview)
  assert_eq(candidate_commit(s, preview), 0)
  assert_eq(text_snapshot(s, e), snapshot)
  assert_eq(image_session_document(s), before)
  assert_eq(editor_style_get(style, 3, 3), 32)
  assert_eq(image_session_count(s), 0)
  let exportable = @image.image_finalize(
    Json::object({ "document": @json.parse(preview_document) }).stringify(),
  )
  assert_eq(tx_object(exportable).get("ok"), Some(Json(true)))
  let candidate = tx_prepare(s, e, 1, 66.5)
  assert_eq(candidate_document(preview), "")
  assert_eq(candidate_document(candidate), preview_document)
  assert_eq(candidate_commit(s, candidate), 1)
  assert_eq(image_session_annotation_id(s, 0), id)
  assert_eq(image_session_text(s, 0), "你好\n🌙")
  assert_eq(image_session_value(s, 0, 7), 31.25)
  assert_eq(image_session_value(s, 0, 8), 0.35)
  assert_eq(image_session_value(s, 0, 4), 66.5)
  assert_eq(editor_style_get(style, 3, 3), 31.25)
  assert_eq(image_session_undo(s), 1)
  assert_eq(image_session_count(s), 0)
  assert_eq(image_session_redo(s), 1)
  assert_eq(image_session_annotation_id(s, 0), id)
  assert_eq(image_session_text(s, 0), "你好\n🌙")
  tx_cleanup(s, style)
}

///|
test "existing text uses stable IDs and object style does not contaminate creation defaults" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  assert_eq(image_session_add(s, 1, 0, 0, 20, 20, 0, 2), 1)
  assert_eq(image_session_set_text(s, "original"), 1)
  assert_eq(
    image_session_add_rgba(s, 3, 10, 20, 200, 40, 0x123456, 3, 24, 0.8),
    1,
  )
  let id = image_session_annotation_id(s, 1)
  assert_eq(image_session_remove(s, 0), 1)
  let e = tx_begin(s, style, 2, id)
  assert_true(e > 0)
  assert_eq(text_value(s, e, 4), 24)
  assert_eq(tx_replace(s, e, "annotation.text", "edited🌙"), 1)
  assert_eq(tx_replace(s, e, "style.fontSize", "42.5"), 1)
  assert_eq(tx_replace(s, e, "style.opacity", "25"), 1)
  assert_eq(
    tx_event(
      s,
      e,
      Json::object({ "type": Json("color"), "rgb": Json(0xffffff) }),
    ),
    1,
  )
  assert_eq(candidate_commit(s, tx_prepare(s, e, 1, 55)), 1)
  assert_eq(image_session_count(s), 1)
  assert_eq(image_session_annotation_id(s, 0), id)
  assert_eq(image_session_text(s, 0), "edited🌙")
  assert_eq(image_session_value(s, 0, 7), 42.5)
  assert_eq(editor_style_get(style, 3, 3), 32)
  assert_eq(editor_style_get(style, 3, 1), 1)
  assert_eq(editor_style_get(style, 3, 0), (0xf26769).to_double())
  assert_eq(image_session_undo(s), 1)
  assert_eq(image_session_text(s, 0), "original")
  assert_eq(image_session_value(s, 0, 7), 24)
  assert_eq(image_session_redo(s), 1)
  let unchanged = tx_begin(s, style, 2, id)
  let revision = image_session_revision(s)
  assert_eq(candidate_commit(s, tx_prepare(s, unchanged, 1, 55)), 1)
  assert_eq(image_session_revision(s), revision)
  tx_cleanup(s, style)
}

///|
test "whitespace policy is shared for new and existing text while cancel never deletes" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let blank = tx_begin(s, style, 1, "")
  assert_eq(tx_replace(s, blank, "annotation.text", "\n \t\u{00a0}\u{3000}"), 1)
  assert_eq(tx_replace(s, blank, "style.fontSize", "40"), 1)
  assert_eq(candidate_commit(s, tx_prepare(s, blank, 1, 0)), 1)
  assert_eq(image_session_count(s), 0)
  assert_eq(image_session_revision(s), 0)
  assert_eq(editor_style_get(style, 3, 3), 40)
  assert_eq(image_session_set_text(s, "keep"), 1)
  assert_eq(image_session_add(s, 3, 10, 20, 200, 40, 0, 3), 1)
  let id = image_session_annotation_id(s, 0)
  let cancelled = tx_begin(s, style, 2, id)
  assert_eq(tx_replace(s, cancelled, "annotation.text", ""), 1)
  assert_eq(text_cancel(s, cancelled, text_value(s, cancelled, 0).to_int()), 1)
  assert_eq(image_session_text(s, 0), "keep")
  let removed = tx_begin(s, style, 2, id)
  assert_eq(tx_replace(s, removed, "annotation.text", " \n"), 1)
  assert_eq(candidate_commit(s, tx_prepare(s, removed, 1, 0)), 1)
  assert_eq(image_session_count(s), 0)
  assert_eq(image_session_undo(s), 1)
  assert_eq(image_session_text(s, 0), "keep")
  tx_cleanup(s, style)
}

///|
test "invalid numeric drafts and IME block preflight without hiding raw text or clamping" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let e = tx_begin(s, style, 1, "")
  assert_eq(tx_replace(s, e, "annotation.text", "test"), 1)
  let document = image_session_document(s)
  for raw in ["", "-", "1.", "NaN", "129", "7.9", "12px", "1,5"] {
    assert_eq(tx_replace(s, e, "style.fontSize", raw), 1)
    assert_eq(
      image_string(tx_field(s, e, "style.fontSize"), "raw", "missing"),
      raw,
    )
    assert_eq(text_value(s, e, 12), 0)
    assert_eq(text_value(s, e, 4), 32)
    assert_eq(tx_prepare(s, e, 1, 40), 0)
    assert_eq(
      tx_event(
        s,
        e,
        Json::object({
          "type": Json("step"),
          "id": Json("style.fontSize"),
          "delta": Json(1),
        }),
      ),
      0,
    )
    assert_eq(editor_style_get(style, 3, 3), 32)
    assert_eq(image_session_document(s), document)
  }
  assert_eq(tx_replace(s, e, "style.fontSize", "31.25"), 1)
  assert_eq(
    tx_event(
      s,
      e,
      Json::object({
        "type": Json("step"),
        "id": Json("style.fontSize"),
        "delta": Json(1),
      }),
    ),
    1,
  )
  assert_eq(text_value(s, e, 4), 32.25)
  assert_eq(tx_replace(s, e, "style.opacity", "100.1"), 1)
  assert_eq(tx_prepare(s, e, 1, 40), 0)
  assert_eq(tx_replace(s, e, "style.opacity", "0"), 1)
  assert_eq(text_value(s, e, 3), 0)
  assert_eq(text_value(s, e, 12), 1)
  assert_eq(tx_prepare(s, e, 1, 0), 0)
  assert_eq(candidate_commit(s, tx_prepare(s, e, 1, 1000)), 1)
  assert_eq(image_session_value(s, 0, 4), 460)
  assert_eq(image_session_value(s, 0, 8), 0)
  assert_eq(image_session_value(s, 0, 7), 32.25)
  tx_cleanup(s, style)
}

///|
test "stale events and candidates preserve drafts while cancel retires all field callbacks" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let e = tx_begin(s, style, 1, "")
  assert_eq(tx_replace(s, e, "annotation.text", "first"), 1)
  let field = tx_field(s, e, "annotation.text")
  let stale = tx_prepare(s, e, 1, 40)
  assert_eq(tx_replace(s, e, "annotation.text", "second"), 1)
  let current = text_snapshot(s, e)
  let late = Json::object({
    "type": Json("field"),
    "id": Json("annotation.text"),
    "token": field["token"],
    "expectedVersion": field["version"],
    "edit": Json::object({
      "type": Json("select"),
      "selection": Json::object({ "kind": Json("unknown") }),
    }),
  })
  assert_eq(tx_event(s, e, late), 0)
  assert_eq(candidate_commit(s, stale), 0)
  assert_eq(text_snapshot(s, e), current)
  assert_eq(image_session_count(s), 0)
  let candidate = tx_prepare(s, e, 1, 40)
  assert_eq(candidate_document(stale), "")
  assert_eq(image_session_add(s, 1, 0, 0, 20, 20, 0, 3), 1)
  assert_eq(candidate_ready(s, candidate), 0)
  assert_eq(tx_replace(s, e, "annotation.text", "third"), 0)
  assert_eq(tx_prepare(s, e, 1, 40), 0)
  assert_eq(text_text(s, e, 1), "second")
  let version = text_value(s, e, 0).to_int()
  assert_eq(text_cancel(s, e, version - 1), 0)
  assert_eq(text_cancel(s, e, version), 1)
  assert_eq(candidate_document(candidate), "")
  let reopened = tx_begin(s, style, 1, "")
  assert_true(reopened > e)
  assert_eq(text_event_json(s, e, version, late.stringify()), 0)
  assert_eq(text_text(s, reopened, 1), "")
  let new_candidate = tx_prepare(s, reopened, 1, 0)
  assert_true(new_candidate > candidate)
  image_session_dispose(s)
  assert_eq(candidate_ready(s, new_candidate), 0)
  assert_eq(candidate_document(new_candidate), "")
  editor_style_dispose(style)
}

///|
test "multi-window publication validates all candidates before publishing any state" {
  let a = image_session_create(640, 480)
  let b = image_session_create(640, 480)
  let sa = editor_style_create()
  let sb = editor_style_create()
  let ea = tx_begin(a, sa, 1, "")
  let eb = tx_begin(b, sb, 1, "")
  assert_eq(tx_replace(a, ea, "annotation.text", "window A"), 1)
  assert_eq(tx_replace(b, eb, "annotation.text", "window B"), 1)
  assert_eq(tx_replace(a, ea, "style.fontSize", "40"), 1)
  assert_eq(tx_replace(b, eb, "style.fontSize", "48"), 1)
  let ca = tx_prepare(a, ea, 1, 40)
  let old_cb = tx_prepare(b, eb, 1, 40)
  assert_eq(tx_replace(b, eb, "annotation.text", "window B updated"), 1)
  let batch = fn(cb : Int32) {
    Json::array([
      Json::object({ "session": Json(a), "candidate": Json(ca) }),
      Json::object({ "session": Json(b), "candidate": Json(cb) }),
    ]).stringify()
  }
  assert_eq(candidate_commit_many(batch(old_cb)), 0)
  assert_eq(image_session_count(a), 0)
  assert_eq(image_session_count(b), 0)
  assert_eq(editor_style_get(sa, 3, 3), 32)
  assert_eq(editor_style_get(sb, 3, 3), 32)
  assert_eq(candidate_ready(a, ca), 1)
  let cb = tx_prepare(b, eb, 1, 40)
  assert_eq(candidate_commit_many(batch(cb)), 1)
  assert_eq(image_session_text(a, 0), "window A")
  assert_eq(image_session_text(b, 0), "window B updated")
  assert_eq(editor_style_get(sa, 3, 3), 40)
  assert_eq(editor_style_get(sb, 3, 3), 48)
  assert_eq(candidate_commit_many(batch(cb)), 0)
  tx_cleanup(a, sa)
  tx_cleanup(b, sb)
}

///|
test "generic command candidates retain old host preflight without importing documents" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let before = image_session_document(s)
  let command = "{\"type\":\"add\",\"annotations\":[{\"id\":\"external-id\",\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":20,\"height\":20}]}"
  let defaults = "{\"tool\":1,\"values\":{\"0\":1193046,\"2\":5.5}}"
  let candidate = image_session_prepare_command(s, style, 0, command, defaults)
  assert_true(candidate > 0)
  assert_eq(image_session_document(s), before)
  assert_eq(editor_style_get(style, 1, 2), 4)
  // A failed configuration storage simply releases its prepared ticket.
  assert_eq(candidate_close(candidate), 1)
  assert_eq(image_session_document(s), before)
  assert_eq(editor_style_get(style, 1, 2), 4)
  let publish = image_session_prepare_command(s, style, 0, command, defaults)
  assert_eq(candidate_commit(s, publish), 1)
  assert_eq(image_session_annotation_id(s, 0), "external-id")
  assert_eq(editor_style_get(style, 1, 2), 5.5)
  assert_eq(image_session_command(s, 0, "{\"type\":\"undo\"}"), 0)
  assert_eq(image_session_command(s, 1, "{\"type\":\"undo\"}"), 1)
  assert_eq(image_session_count(s), 0)
  assert_eq(image_session_command(s, 2, before), 0)
  let pending = tx_begin(s, style, 0, "")
  assert_true(pending > 0)
  assert_eq(image_session_prepare_command(s, style, 2, "null", defaults), 0)
  tx_cleanup(s, style)
}

///|
test "root field routing enforces stable IDs exact versions and UTF16 boundaries" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let e = tx_begin(s, style, 1, "")
  assert_eq(tx_replace(s, e, "annotation.text", "A🌙B"), 1)
  let before = text_snapshot(s, e)
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({
        "type": Json("select"),
        "selection": Json::object({
          "kind": Json("undirected"),
          "anchor": Json(1),
          "focus": Json(2),
        }),
      }),
    ),
    0,
  )
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({
        "type": Json("select"),
        "selection": Json::object({
          "kind": Json("unknown"),
          "anchor": Json(0),
          "focus": Json(0),
        }),
      }),
    ),
    0,
  )
  assert_eq(text_snapshot(s, e), before)
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({ "type": Json("undo") }),
    ),
    1,
  )
  assert_eq(text_text(s, e, 1), "")
  assert_eq(text_value(s, e, 11), 1)
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({ "type": Json("redo") }),
    ),
    1,
  )
  assert_eq(text_text(s, e, 1), "A🌙B")
  assert_eq(
    tx_field(s, e, "annotation.text").get("selectionKnown"),
    Some(Json(false)),
  )
  let old = tx_prepare(s, e, 1, 40)
  assert_eq(editor_style_set(style, 3, 3, 40), 1)
  assert_eq(candidate_ready(s, old), 0)
  assert_eq(candidate_commit(s, old), 0)
  assert_eq(text_text(s, e, 1), "A🌙B")
  assert_eq(text_cancel(s, e, text_value(s, e, 0).to_int()), 1)
  tx_cleanup(s, style)
}

///|
test "unchanged legacy line endings fractional opacity and color spelling do not create image history" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  assert_eq(
    image_session_command(
      s, 0, "{\"type\":\"add\",\"annotations\":[{\"id\":\"legacy\",\"type\":\"text\",\"x\":-10,\"y\":20,\"width\":700,\"height\":40,\"text\":\"a\\r\\nb\\rc\",\"fontSize\":31.25,\"opacity\":0.123,\"color\":\"#AABBCC\"}]}",
    ),
    1,
  )
  let document = image_session_document(s)
  let e = tx_begin(s, style, 2, "legacy")
  assert_eq(text_text(s, e, 1), "a\nb\nc")
  assert_eq(
    tx_field_event(
      s,
      e,
      "annotation.text",
      Json::object({
        "type": Json("select"),
        "selection": Json::object({ "kind": Json("unknown") }),
      }),
    ),
    1,
  )
  assert_eq(tx_replace(s, e, "annotation.text", "a\r\nb"), 0)
  assert_eq(
    tx_event(
      s,
      e,
      Json::object({ "type": Json("color"), "rgb": Json(0xaabbcc) }),
    ),
    1,
  )
  assert_eq(text_value(s, e, 3), 0.123)
  assert_eq(candidate_commit(s, tx_prepare(s, e, 1, 40)), 1)
  assert_eq(image_session_document(s), document)
  let changed = tx_begin(s, style, 2, "legacy")
  assert_eq(tx_replace(s, changed, "annotation.text", "a\nb\n🌙"), 1)
  assert_eq(candidate_commit(s, tx_prepare(s, changed, 1, 40)), 1)
  assert_eq(image_session_text(s, 0), "a\nb\n🌙")
  assert_eq(image_session_undo(s), 1)
  assert_eq(image_session_text(s, 0), "a\r\nb\rc")
  tx_cleanup(s, style)
}

///|
test "manual text height survives no-op and color opacity edits until body or font reflows" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  assert_eq(image_session_set_text(s, "first\r\nsecond"), 1)
  assert_eq(
    image_session_add_rgba(s, 3, 10, 20, 200, 200, 0x123456, 3, 24, 0.8),
    1,
  )
  let id = image_session_annotation_id(s, 0)
  let original = image_session_document(s)
  let unchanged = tx_begin(s, style, 2, id)
  let version = text_value(s, unchanged, 0).to_int()
  assert_eq(text_text(s, unchanged, 1), "first\nsecond")
  assert_eq(text_measured_height(s, unchanged, version, 40), 200)
  assert_eq(text_measured_height(s, unchanged, version, 0), 200)
  let preview = tx_prepare(s, unchanged, 0, 40)
  assert_eq(candidate_document(preview), original)
  assert_eq(image_session_document(s), original)
  assert_eq(candidate_commit(s, tx_prepare(s, unchanged, 1, 40)), 1)
  assert_eq(image_session_document(s), original)

  let colored = tx_begin(s, style, 2, id)
  assert_eq(
    tx_event(
      s,
      colored,
      Json::object({ "type": Json("color"), "rgb": Json(0xffffff) }),
    ),
    1,
  )
  assert_eq(tx_replace(s, colored, "style.opacity", "35"), 1)
  assert_eq(
    text_measured_height(s, colored, text_value(s, colored, 0).to_int(), 44),
    200,
  )
  assert_eq(candidate_commit(s, tx_prepare(s, colored, 1, 44)), 1)
  assert_eq(image_session_value(s, 0, 4), 200)
  assert_eq(image_session_value(s, 0, 5), (0xffffff).to_double())
  assert_eq(image_session_value(s, 0, 8), 0.35)
  assert_eq(image_session_text(s, 0), "first\r\nsecond")
  assert_eq(image_session_revision(s), 2)
  assert_eq(image_session_undo(s), 1)
  assert_eq(image_session_value(s, 0, 4), 200)
  assert_eq(image_session_value(s, 0, 5), (0x123456).to_double())
  assert_eq(image_session_value(s, 0, 8), 0.8)

  let resized = tx_begin(s, style, 2, id)
  assert_eq(tx_replace(s, resized, "style.fontSize", "31.25"), 1)
  assert_eq(
    text_measured_height(s, resized, text_value(s, resized, 0).to_int(), 55.5),
    55.5,
  )
  assert_eq(candidate_commit(s, tx_prepare(s, resized, 1, 55.5)), 1)
  assert_eq(image_session_value(s, 0, 4), 55.5)
  let changed = tx_begin(s, style, 2, id)
  assert_eq(
    tx_replace(s, changed, "annotation.text", "first\nsecond\nthird"),
    1,
  )
  assert_eq(
    text_measured_height(s, changed, text_value(s, changed, 0).to_int(), 90),
    90,
  )
  assert_eq(candidate_commit(s, tx_prepare(s, changed, 1, 90)), 1)
  assert_eq(image_session_value(s, 0, 4), 90)
  tx_cleanup(s, style)
}

///|
test "shared style-bank conflicts and duplicate candidates cannot partially publish a batch" {
  let a = image_session_create(640, 480)
  let b = image_session_create(640, 480)
  let style = editor_style_create()
  let ea = tx_begin(a, style, 0, "")
  let eb = tx_begin(b, style, 0, "")
  assert_eq(tx_replace(a, ea, "style.fontSize", "40"), 1)
  assert_eq(tx_replace(b, eb, "style.fontSize", "48"), 1)
  let ca = tx_prepare(a, ea, 1, 0)
  let cb = tx_prepare(b, eb, 1, 0)
  let first = Json::object({ "session": Json(a), "candidate": Json(ca) })
  assert_eq(candidate_commit_many(Json::array([first, first]).stringify()), 0)
  assert_eq(
    candidate_commit_many(
      Json::array([
        first,
        Json::object({ "session": Json(b), "candidate": Json(cb) }),
      ]).stringify(),
    ),
    0,
  )
  assert_eq(candidate_ready(a, ca), 1)
  assert_eq(candidate_ready(b, cb), 1)
  assert_eq(editor_style_get(style, 3, 3), 32)
  assert_eq(image_session_revision(a), 0)
  assert_eq(image_session_revision(b), 0)
  assert_eq(text_text(a, ea, 2), "")
  assert_eq(text_text(b, eb, 2), "")
  editor_style_dispose(style)
  assert_eq(candidate_commit(a, ca), 0)
  assert_eq(text_cancel(a, ea, text_value(a, ea, 0).to_int()), 1)
  image_session_dispose(a)
  image_session_dispose(b)
}

///|
test "real capture frames carry shared property geometry and versioned inline input without duplicate AX" {
  let s = image_session_create(640, 480)
  let style = editor_style_create()
  let e = tx_begin(s, style, 1, "")
  assert_eq(tx_replace(s, e, "annotation.text", "你好\n🌙"), 1)
  assert_eq(tx_replace(s, e, "style.fontSize", "31.25"), 1)
  assert_eq(tx_replace(s, e, "style.opacity", "35"), 1)
  let width = text_value(s, e, 13)
  let height = text_value(s, e, 14)
  assert_true(width > 200 && width < 300)
  assert_eq(height, 30)
  for dark in [0, 1] {
    let frame = text_frame(s, e, 0, width, height, 1, dark)
    let handle = @ui_frame.open(frame)
    assert_true(handle > 0)
    assert_eq(@ui_frame.semantic_count(handle), 5)
    assert_eq(@ui_frame.semantic_text(handle, 0, 0), "style.color")
    assert_eq(@ui_frame.semantic_text(handle, 1, 0), "style.opacity.increase")
    assert_eq(@ui_frame.semantic_text(handle, 4, 0), "style.fontSize.decrease")
    assert_eq(@ui_frame.field_count(handle), 2)
    assert_eq(@ui_frame.field_text(handle, 0, 0), "style.opacity")
    assert_eq(@ui_frame.field_text(handle, 1, 0), "style.fontSize")
    assert_eq(@ui_frame.field_text(handle, 1, 1), "31.25")
    assert_true(@ui_frame.field_number(handle, 0, 2) < @ui_frame.field_number(handle, 1, 2))
    assert_eq(@ui_frame.field_value(handle, 1, 6), 0)
    assert_eq(@ui_frame.field_value(handle, 1, 15), 0)
    let m = tx_object(frame)
    let fields = match m["editableFields"] {
      Array(a) => a
      _ => abort("fields")
    }
    assert_eq(fields.length(), 2)
    assert_eq(
      @test_support.model_test_field(fields[0], "id"),
      Json("style.opacity"),
    )
    assert_eq(
      @test_support.model_test_field(fields[1], "id"),
      Json("style.fontSize"),
    )
    assert_eq(@test_support.model_test_field(fields[1], "raw"), Json("31.25"))
    assert_eq(
      @test_support.model_test_field(fields[1], "selection"),
      Json::object({ "kind": Json("unknown") }),
    )
    assert_eq(@ui_frame.close(handle), 1)
  }
  let before = text_snapshot(s, e)
  assert_eq(text_measured_height(s, e, text_value(s, e, 0).to_int(), 1000), 460)
  assert_eq(
    text_measured_height(s, e, text_value(s, e, 0).to_int() - 1, 60),
    -1,
  )
  assert_eq(text_snapshot(s, e), before)
  let inline = text_frame(s, e, 1, 400, 120, 2, 0)
  let inline_handle = @ui_frame.open(inline)
  assert_true(inline_handle > 0)
  assert_eq(@ui_frame.command_count(inline_handle, 0), 0)
  assert_eq(@ui_frame.semantic_count(inline_handle), 0)
  assert_eq(@ui_frame.field_count(inline_handle), 1)
  assert_eq(@ui_frame.field_value(inline_handle, 0, 15), 3)
  let field_token = @ui_frame.field_value(inline_handle, 0, 0)
  let field_version = @ui_frame.field_value(inline_handle, 0, 1)
  let fields = match tx_object(inline)["editableFields"] {
    Array(a) => a
    _ => abort("fields")
  }
  assert_eq(fields.length(), 1)
  assert_eq(
    @test_support.model_test_field(fields[0], "raw"),
    Json("你好\n🌙"),
  )
  assert_eq(@test_support.model_test_field(fields[0], "fontSize"), Json(62.5))
  assert_eq(@test_support.model_test_field(fields[0], "opacity"), Json(0.35))
  assert_eq(@test_support.model_test_field(fields[0], "x"), Json(0))
  assert_eq(@ui_frame.close(inline_handle), 1)
  let row = @ui_frame.open(text_frame(s, e, 0, width, height, 1, 0))
  let x = @ui_frame.semantic_number(row, 0, 0) + 5
  let y = @ui_frame.semantic_number(row, 0, 1) + 5
  assert_eq(@ui_frame.close(row), 1)
  let version = text_value(s, e, 0).to_int()
  let pointer = fn(kind : String, x : Double, y : Double) {
    Json::object({ "type": Json(kind), "x": Json(x), "y": Json(y) }).stringify()
  }
  assert_eq(
    text_ui_event(s, e, version, pointer("pointerDown", x, y), width, height),
    1,
  )
  assert_eq(
    text_ui_event(s, e, version, pointer("pointerUp", x, y), width, height),
    2,
  )
  assert_eq(text_value(s, e, 0), version.to_double())
  assert_eq(text_text(s, e, 1), "你好\n🌙")
  assert_eq(image_session_revision(s), 0)
  assert_eq(
    tx_object(text_snapshot(s, e)).get("activeField"),
    Some(Json("style.color")),
  )
  assert_eq(
    text_ui_event(s, e, version, pointer("pointerDown", 0, 0), width, height),
    1,
  )
  assert_eq(
    text_ui_event(s, e, version, pointer("pointerUp", x, y), width, height),
    1,
  )
  assert_eq(
    text_ui_event(
      s, e, version, "{\"type\":\"activate\",\"id\":\"style.color\"}", width, height,
    ),
    2,
  )
  assert_eq(
    text_ui_event(
      s,
      e,
      version - 1,
      pointer("pointerDown", x, y),
      width,
      height,
    ),
    0,
  )
  let input = @ui_frame.text_event(
    2, "annotation.text", field_token, field_version, 0, 0, "", 2, 0, 5,
  )
  assert_true(input != "")
  assert_eq(text_event_json(s, e, version, input), 1)
  assert_eq(tx_event(s, e, tx_object(input) |> Json::object), 0)
  let updated = @ui_frame.open(text_frame(s, e, 1, 400, 120, 2, 0))
  assert_eq(@ui_frame.field_value(updated, 0, 6), 1)
  assert_eq(@ui_frame.field_value(updated, 0, 7), 0)
  assert_eq(@ui_frame.field_value(updated, 0, 9), 5)
  assert_eq(@ui_frame.close(updated), 1)
  let tiny = @ui_frame.open(text_frame(s, e, 1, 1, 1, 1.0 / 65536, 0))
  assert_true(tiny > 0)
  assert_eq(@ui_frame.field_number(tiny, 0, 8), 31.25 / 65536)
  assert_eq(@ui_frame.close(tiny), 1)
  // An unrelated mutation disables the stale input surface without invalid
  // disabled+focused metadata or overwriting the still-readable field draft.
  assert_eq(image_session_add(s, 1, 0, 0, 10, 10, 0, 3), 1)
  let stale = @ui_frame.open(text_frame(s, e, 1, 400, 120, 2, 0))
  assert_true(stale > 0)
  assert_eq(@ui_frame.field_value(stale, 0, 2), 0)
  assert_eq(@ui_frame.field_value(stale, 0, 4), 0)
  assert_eq(@ui_frame.field_text(stale, 0, 1), "你好\n🌙")
  assert_eq(@ui_frame.close(stale), 1)
  tx_cleanup(s, style)
}
