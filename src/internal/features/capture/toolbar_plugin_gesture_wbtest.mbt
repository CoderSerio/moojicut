///|
fn pg_entries() -> Array[CaptureToolbarContribution] {
  let entries = tb_entries()
  for
    (id, interaction, effect) in [
      ("box", 2, "capture.annotations.add"),
      ("inspect", 0, "result.text"),
    ] {
    entries.push({
      id: "user.com.example.capture/" + id,
      title: id,
      icon: "plugin",
      command: "plugin.run",
      payload: Json::object({ "effect": Json(effect) }).stringify(),
      reason: "",
      slot: 0,
      kind: 0,
      interaction,
      capability: 16,
      enabled: true,
      available: true,
    })
  }
  entries
}

///|
fn pg_context(
  toolbar : Int32,
  session : Int32,
  edit : Int32,
  capabilities : Int32,
) -> Int32 {
  toolbar_context(
    toolbar,
    Json::object({
      "hasRegion": Json(true),
      "blocked": Json(false),
      "fieldFocused": Json(edit != 0),
      "pinAvailable": Json(true),
      "edit": Json(edit),
      "editVersion": Json(
        if edit == 0 {
          0
        } else {
          text_value(session, edit, 0).to_int()
        },
      ),
      "measuredHeight": Json(40),
      "capabilities": Json(capabilities),
    }).stringify(),
  )
}

///|
fn pg_open() -> (Int32, Int32, Int32) raise {
  let image = image_session_create_viewport(640, 480, 100, 80, 320, 180)
  let style = editor_style_create()
  let toolbar = toolbar_open(image, style, pg_entries())
  assert_true(toolbar > 0)
  assert_eq(pg_context(toolbar, image, 0, 31), 1)
  assert_eq(tb_activate(toolbar, "user.com.example.capture/box"), 1)
  assert_eq(tb_ack(toolbar, 1), 1)
  (image, style, toolbar)
}

///|
fn pg_begin(image : Int32, x : Double, y : Double) -> Int32 {
  image_session_tool_begin(image, "plugin.run", x, y, 0x123456, 3.5, 0.6, 1, 12)
}

///|
test "user rectangle uses shared source preview and dispatches one viewport-relative effect without editing" {
  let (image, style, toolbar) = pg_open()
  let before = image_session_document(image)
  assert_eq(pg_begin(image, 280, 200), 1)
  assert_eq(image_session_shape_event(image, 0, 120, 100), 1)
  assert_eq(image_session_preview_value(image, 0), 1)
  assert_eq(image_session_preview_value(image, 1), 120)
  assert_eq(image_session_preview_value(image, 2), 100)
  assert_eq(image_session_preview_value(image, 3), 160)
  assert_eq(image_session_preview_value(image, 4), 100)
  assert_eq(image_session_preview_value(image, 9), 0)
  assert_eq(image_session_document(image), before)
  assert_eq(toolbar_value(toolbar, 5), 0)
  assert_eq(image_session_shape_event(image, 1, 120, 100), 1)
  assert_eq(image_session_preview_value(image, 0), 0)
  assert_eq(image_session_document(image), before)
  assert_eq(image_session_undo(image), 1)
  assert_eq(image_session_document(image), before)
  assert_eq(toolbar_value(toolbar, 5), 8)
  assert_eq(toolbar_text(toolbar, 2), "user.com.example.capture/box")
  assert_eq(
    @json.parse(toolbar_text(toolbar, 3)),
    @json.parse(
      (
        #|{"effect":"capture.annotations.add","capture":{"width":320,"height":180,"format":"png","revision":0},"selection":{"x":20,"y":20,"width":160,"height":100}}
      ),
    ),
  )
  let ticket = toolbar_value(toolbar, 6).to_int()
  assert_eq(image_session_shape_event(image, 1, 20, 30), 1)
  assert_eq(toolbar_value(toolbar, 6), ticket.to_double())
  assert_eq(pg_begin(image, 120, 100), 0)
  assert_eq(toolbar_ack(toolbar, ticket, 1, ""), 1)
  assert_eq(toolbar_ack(toolbar, ticket, 1, ""), 0)
  assert_eq(toolbar_value(toolbar, 5), 0)
  assert_eq(toolbar_value(toolbar, 1), 2)
  assert_eq(toolbar_text(toolbar, 0), "user.com.example.capture/box")
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 1, 1000, 1000), 1)
  let payload = tx_object(toolbar_text(toolbar, 3))
  assert_eq(
    payload["selection"],
    Json::object({
      "x": Json(20),
      "y": Json(20),
      "width": Json(300),
      "height": Json(160),
    }),
  )
  assert_eq(tb_ack(toolbar, 0), 1)
  assert_eq(image_session_document(image), before)
  tb_cleanup(toolbar, image, style)
}

///|
test "cancel tiny release and tool change discard user previews and retain builtin gesture behavior" {
  let (image, style, toolbar) = pg_open()
  let before = image_session_document(image)
  assert_eq(pg_begin(image, 99, 100), 0)
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 1, 121, 101), 1)
  assert_eq(toolbar_value(toolbar, 5), 0)
  assert_eq(image_session_document(image), before)
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 0, 220, 170), 1)
  assert_eq(image_session_shape_event(image, 2, 0, 0), 1)
  assert_eq(image_session_preview_value(image, 0), 0)
  assert_eq(image_session_shape_event(image, 1, 220, 170), 1)
  assert_eq(toolbar_value(toolbar, 5), 0)
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 0, 220, 170), 1)
  assert_eq(tb_activate(toolbar, "builtin.image.rectangle"), 1)
  assert_eq(image_session_preview_value(image, 0), 0)
  assert_eq(tb_ack(toolbar, 1), 1)
  assert_eq(image_session_shape_event(image, 1, 220, 170), 1)
  assert_eq(image_session_document(image), before)
  assert_eq(pg_begin(image, 120, 100), 0)
  assert_eq(
    image_session_tool_begin(
      image, "capture.numberedRectangle", 120, 100, 0, 3, 1, 0, 12,
    ),
    1,
  )
  assert_eq(image_session_shape_event(image, 1, 220, 170), 1)
  assert_eq(image_session_count(image), 2)
  assert_eq(image_session_undo(image), 1)
  assert_eq(image_session_count(image), 0)
  assert_eq(tb_activate(toolbar, "user.com.example.capture/inspect"), 1)
  assert_eq(toolbar_value(toolbar, 5), 8)
  assert_eq(
    @json.parse(toolbar_text(toolbar, 3)),
    Json::object({ "effect": Json("result.text") }),
  )
  assert_eq(tb_ack(toolbar, 1), 1)
  tb_cleanup(toolbar, image, style)
}

///|
test "configuration preflight cannot erase an active user gesture or accept a late release after removal" {
  let (image, style, toolbar) = pg_open()
  let (peer, peer_style, peer_toolbar) = pg_open()
  let before = image_session_document(image)
  let entries = pg_entries().filter(e => e.id != "user.com.example.capture/box")
  let peer_candidate = toolbar_config_prepare(peer_toolbar, entries)
  assert_true(peer_candidate > 0)
  assert_eq(pg_begin(peer, 120, 100), 0)
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 0, 220, 170), 1)
  assert_eq(toolbar_config_prepare(toolbar, entries), 0)
  assert_eq(
    toolbar_config_commit_many(
      "[{\"toolbar\":\{peer_toolbar},\"candidate\":\{peer_candidate}},{\"toolbar\":\{toolbar},\"candidate\":0}]",
    ),
    0,
  )
  assert_eq(image_session_preview_value(image, 3), 100)
  assert_eq(image_session_document(image), before)
  assert_eq(toolbar_text(peer_toolbar, 0), "user.com.example.capture/box")
  assert_eq(image_session_shape_event(image, 2, 0, 0), 1)
  let candidate = toolbar_config_prepare(toolbar, entries)
  assert_true(candidate > 0)
  assert_eq(
    toolbar_config_commit_many(
      "[{\"toolbar\":\{peer_toolbar},\"candidate\":\{peer_candidate}},{\"toolbar\":\{toolbar},\"candidate\":\{candidate}}]",
    ),
    1,
  )
  assert_eq(toolbar_text(toolbar, 0), "host.select")
  assert_eq(pg_begin(image, 120, 100), 0)
  assert_eq(image_session_shape_event(image, 1, 220, 170), 1)
  assert_eq(toolbar_value(toolbar, 5), 0)
  assert_eq(image_session_document(image), before)
  tb_cleanup(peer_toolbar, peer, peer_style)
  tb_cleanup(toolbar, image, style)
}

///|
test "stale screenshot permissions and competing drafts invalidate user gestures without publication" {
  let (image, style, toolbar) = pg_open()
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_add(image, 1, 10, 10, 30, 30, 0, 3), 1)
  let changed = image_session_document(image)
  assert_eq(image_session_shape_event(image, 1, 220, 170), 0)
  assert_eq(image_session_preview_value(image, 0), 0)
  assert_eq(image_session_document(image), changed)
  assert_eq(toolbar_value(toolbar, 5), 0)
  let edit = tx_begin(image, style, 1, "")
  assert_true(edit > 0)
  assert_eq(
    tx_field_event(
      image,
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
  let composing = text_snapshot(image, edit)
  assert_eq(pg_begin(image, 120, 100), 0)
  assert_eq(text_snapshot(image, edit), composing)
  assert_eq(text_cancel(image, edit, text_value(image, edit, 0).to_int()), 1)
  let candidate = image_session_prepare_command(
    image,
    0,
    image_session_revision(image),
    "null",
    "null",
  )
  assert_true(candidate > 0)
  assert_eq(pg_begin(image, 120, 100), 0)
  assert_eq(candidate_ready(image, candidate), 1)
  assert_eq(candidate_close(candidate), 1)
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 0, 220, 170), 1)
  assert_eq(pg_context(toolbar, image, 0, 0), 1)
  assert_eq(image_session_shape_event(image, 1, 220, 170), 0)
  assert_eq(image_session_preview_value(image, 0), 0)
  assert_eq(toolbar_value(toolbar, 5), 0)
  assert_eq(pg_context(toolbar, image, 0, 31), 1)
  assert_eq(pg_begin(image, 120, 100), 1)
  assert_eq(image_session_shape_event(image, 0, 220, 170), 1)
  assert_eq(toolbar_close(toolbar), 1)
  assert_eq(image_session_preview_value(image, 0), 0)
  assert_eq(image_session_shape_event(image, 1, 220, 170), 1)
  assert_eq(image_session_document(image), changed)
  tx_cleanup(image, style)
}
