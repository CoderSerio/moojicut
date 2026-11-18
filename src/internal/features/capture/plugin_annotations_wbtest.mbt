///|
fn plugin_rect() -> Json {
  Json::object({
    "type": Json("rect"),
    "x": Json(0),
    "y": Json(0),
    "width": Json(180),
    "height": Json(120),
    "color": Json("#A0b1C2"),
    "stroke": Json(2.5),
  })
}

///|
fn plugin_label() -> Json {
  Json::object({
    "type": Json("text"),
    "x": Json(10.5),
    "y": Json(20.25),
    "width": Json(150),
    "height": Json(40),
    "color": Json("#FFFFFF"),
    "text": Json("你好 🌙"),
    "fontSize": Json(31.25),
  })
}

///|
fn plugin_patch(raw : Json, key : String, value : Json) -> Json {
  let source = match raw {
    Object(m) => m
    _ => abort("expected object")
  }
  let changed = text_copy(source)
  changed[key] = value
  Json::object(changed)
}

///|
test "plugin rect and Unicode label map cropped pixels and commit as one undo" {
  let session = image_session_create_viewport(640, 480, 120, 70, 200, 150)
  let before = image_session_document(session)
  let annotations = Json::array([plugin_rect(), plugin_label()]).stringify()
  let ticket = image_session_prepare_plugin_annotations(session, 0, annotations)
  assert_true(ticket > 0)
  assert_eq(image_session_document(session), before)
  assert_eq(candidate_count(ticket), 2)
  assert_eq(candidate_value(ticket, 0, 1), 120)
  assert_eq(candidate_value(ticket, 0, 2), 70)
  assert_eq(candidate_value(ticket, 1, 1), 130.5)
  assert_eq(candidate_value(ticket, 1, 2), 90.25)
  assert_eq(candidate_value(ticket, 1, 7), 31.25)
  assert_eq(candidate_ready(session, ticket), 1)
  assert_eq(candidate_commit(session, ticket), 1)
  let first = image_session_annotation_id(session, 0)
  let second = image_session_annotation_id(session, 1)
  assert_true(first != second && first.has_prefix("plugin-"))
  assert_eq(image_session_text(session, 1), "你好 🌙")
  assert_eq(image_session_revision(session), 1)
  assert_eq(
    native_image_annotation(session, 0).unwrap()["color"],
    Json("#a0b1c2"),
  )
  assert_eq(image_session_undo(session), 1)
  assert_eq(image_session_count(session), 0)
  assert_eq(image_session_redo(session), 1)
  assert_eq(image_session_count(session), 2)
  assert_eq(image_session_annotation_id(session, 1), second)
  assert_eq(image_session_undo(session), 1)
  let replacement = image_session_prepare_plugin_annotations(
    session,
    image_session_revision(session),
    annotations,
  )
  assert_true(replacement > 0)
  assert_eq(candidate_commit(session, replacement), 1)
  assert_true(image_session_annotation_id(session, 0) != first)
  assert_eq(candidate_commit(session, ticket), 0)
  image_session_dispose(session)
}

///|
test "plugin annotation validation is bounded exact and all or nothing" {
  let session = image_session_create_viewport(640, 480, 100, 60, 200, 150)
  let before = image_session_document(session)
  let invalid = [
    plugin_patch(plugin_rect(), "type", Json("mosaic")),
    plugin_patch(plugin_rect(), "id", Json("native-1")),
    plugin_patch(plugin_rect(), "x", Json(-1)),
    plugin_patch(plugin_rect(), "width", Json(201)),
    plugin_patch(plugin_rect(), "height", Json(0)),
    plugin_patch(plugin_rect(), "color", Json("#GG0000")),
    plugin_patch(plugin_rect(), "stroke", Json(24.1)),
    plugin_patch(plugin_rect(), "x", Json("0")),
    plugin_patch(plugin_label(), "fontSize", Json(7.9)),
    plugin_patch(plugin_label(), "fontSize", Json(96.1)),
    plugin_patch(plugin_label(), "text", Json("\u{3000}\u{00a0}")),
    plugin_patch(plugin_label(), "text", Json("line\nlabel")),
    plugin_patch(plugin_label(), "text", Json("label\u{0085}")),
    plugin_patch(plugin_label(), "text", Json("🌙".repeat(41))),
    Json::object({ "type": Json("text") }),
  ]
  for item in invalid {
    assert_eq(
      image_session_prepare_plugin_annotations(
        session,
        0,
        Json::array([plugin_rect(), item]).stringify(),
      ),
      0,
    )
    assert_eq(image_session_document(session), before)
  }
  for
    input in [
      "[]",
      "{}",
      "null",
      "[",
      " ".repeat(65537),
      "[{\"type\":\"rect\",\"type\":\"text\"}]",
      "[{\"type\":\"rect\",\"x\":1e999,\"y\":0,\"width\":1,\"height\":1,\"color\":\"#000000\",\"stroke\":1}]",
      "🌙".unsafe_substring(start=0, end=1),
    ] {
    assert_eq(image_session_prepare_plugin_annotations(session, 0, input), 0)
    assert_eq(image_session_document(session), before)
  }
  assert_eq(
    image_session_prepare_plugin_annotations(
      session,
      0,
      Json::array(Array::make(17, plugin_rect())).stringify(),
    ),
    0,
  )
  let maximum = image_session_prepare_plugin_annotations(
    session,
    0,
    Json::array(
      Array::make(
        16,
        plugin_patch(plugin_label(), "text", Json("🌙".repeat(40))),
      ),
    ).stringify(),
  )
  assert_true(maximum > 0)
  assert_eq(candidate_count(maximum), 16)
  assert_eq(candidate_close(maximum), 1)
  assert_eq(image_session_document(session), before)
  image_session_dispose(session)
}

///|
test "plugin preparation rejects text numeric and IME drafts without replacing them" {
  let session = image_session_create(640, 480)
  let style = editor_style_create()
  let input = Json::array([plugin_rect(), plugin_label()]).stringify()
  let defaults = tx_begin(session, style, 0, "")
  assert_true(defaults > 0)
  assert_eq(tx_replace(session, defaults, "style.opacity", "."), 1)
  let draft = text_snapshot(session, defaults)
  assert_eq(image_session_prepare_plugin_annotations(session, 0, input), 0)
  assert_eq(text_snapshot(session, defaults), draft)
  assert_eq(
    text_cancel(session, defaults, text_value(session, defaults, 0).to_int()),
    1,
  )
  let edit = tx_begin(session, style, 1, "")
  assert_eq(
    tx_field_event(
      session,
      edit,
      "annotation.text",
      Json::object({
        "type": Json("compositionStart"),
        "start": Json(0),
        "end": Json(0),
        "selection": Json::object({ "kind": Json("unknown") }),
      }),
    ),
    1,
  )
  assert_eq(
    tx_field_event(
      session,
      edit,
      "annotation.text",
      Json::object({
        "type": Json("compositionUpdate"),
        "text": Json("ni"),
        "selection": Json::object({ "kind": Json("unknown") }),
      }),
    ),
    1,
  )
  let composition = text_snapshot(session, edit)
  assert_eq(image_session_prepare_plugin_annotations(session, 0, input), 0)
  assert_eq(text_snapshot(session, edit), composition)
  assert_eq(image_session_count(session), 0)
  assert_eq(
    text_cancel(session, edit, text_value(session, edit, 0).to_int()),
    1,
  )
  let pending = image_session_prepare_command(session, 0, 0, "null", "null")
  assert_true(pending > 0)
  assert_eq(image_session_prepare_plugin_annotations(session, 0, input), 0)
  assert_eq(candidate_ready(session, pending), 1)
  assert_eq(candidate_close(pending), 1)
  let accepted = image_session_prepare_plugin_annotations(session, 0, input)
  assert_true(accepted > 0)
  assert_eq(candidate_close(accepted), 1)
  tx_cleanup(session, style)
}

///|
test "plugin candidates never consume an active or newly started shape gesture" {
  let session = image_session_create(640, 480)
  let input = Json::array([plugin_rect()]).stringify()
  assert_eq(image_session_shape_begin(session, 1, 10, 10, 0, 3, 1, 0, 12), 1)
  // No move/preview yet: activity cannot be inferred from a non-null preview.
  assert_eq(image_session_prepare_plugin_annotations(session, 0, input), 0)
  assert_eq(image_session_shape_event(session, 1, 90, 80), 1)
  assert_eq(image_session_count(session), 1)
  let ticket = image_session_prepare_plugin_annotations(session, 1, input)
  assert_true(ticket > 0)
  assert_eq(image_session_shape_begin(session, 1, 100, 100, 0, 3, 1, 0, 12), 1)
  assert_eq(candidate_ready(session, ticket), 0)
  assert_eq(candidate_commit(session, ticket), 0)
  assert_eq(image_session_shape_event(session, 1, 180, 180), 1)
  assert_eq(image_session_count(session), 2)
  assert_eq(candidate_commit(session, ticket), 0) // The completed drag changed revision.
  assert_eq(candidate_close(ticket), 1)
  let next = image_session_prepare_plugin_annotations(session, 2, input)
  assert_true(next > 0)
  assert_eq(image_session_shape_begin(session, 1, 200, 200, 0, 3, 1, 0, 12), 1)
  assert_eq(candidate_commit(session, next), 0)
  assert_eq(image_session_shape_event(session, 2, 200, 200), 1)
  assert_eq(candidate_ready(session, next), 1)
  assert_eq(candidate_commit(session, next), 1)
  assert_eq(image_session_count(session), 3)
  assert_false(plugin_annotation_gestures.contains(next))
  image_session_dispose(session)
}

///|
test "plugin IDs avoid host document collisions and stale revisions cannot publish" {
  let session = image_session_create(640, 480)
  let collision = "plugin-\{plugin_annotation_batch.val}-0"
  let item = plugin_patch(plugin_rect(), "id", Json(collision))
  assert_eq(
    image_session_command(
      session,
      0,
      Json::object({ "type": Json("add"), "annotations": Json::array([item]) }).stringify(),
    ),
    1,
  )
  let input = Json::array([plugin_rect()]).stringify()
  assert_eq(image_session_prepare_plugin_annotations(session, 0, input), 0)
  let ticket = image_session_prepare_plugin_annotations(session, 1, input)
  assert_true(ticket > 0)
  assert_eq(candidate_commit(session, ticket), 1)
  assert_eq(image_session_annotation_id(session, 0), collision)
  assert_true(image_session_annotation_id(session, 1) != collision)
  let stale = image_session_prepare_plugin_annotations(session, 2, input)
  assert_true(stale > 0)
  assert_eq(image_session_crop(session, 30, 30, 320, 200), 1)
  let after_crop = image_session_document(session)
  assert_eq(candidate_commit(session, stale), 0)
  assert_eq(image_session_document(session), after_crop)
  assert_eq(candidate_close(stale), 1)
  image_session_dispose(session)
  assert_eq(image_session_prepare_plugin_annotations(session, 3, input), 0)
}
