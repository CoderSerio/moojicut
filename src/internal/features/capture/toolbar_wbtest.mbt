///|
fn tb_entries() -> Array[CaptureToolbarContribution] {
  [
    {
      id: "builtin.image.rectangle",
      title: "矩形",
      icon: "rectangle",
      command: "capture.annotate",
      payload: "{}",
      reason: "",
      slot: 0,
      kind: 1,
      interaction: 1,
      capability: 0,
      enabled: true,
      available: true,
    },
    {
      id: "builtin.image.text",
      title: "文字",
      icon: "text",
      command: "capture.annotate",
      payload: "{}",
      reason: "",
      slot: 0,
      kind: 3,
      interaction: 1,
      capability: 0,
      enabled: true,
      available: true,
    },
    {
      id: "builtin.image.pin",
      title: "贴图",
      icon: "pin",
      command: "pin",
      payload: "{}",
      reason: "",
      slot: 1,
      kind: 0,
      interaction: 0,
      capability: 0,
      enabled: true,
      available: true,
    },
    {
      id: "builtin.capture.ocr",
      title: "文字识别",
      icon: "ocr",
      command: "ocr",
      payload: "{}",
      reason: "",
      slot: 0,
      kind: 0,
      interaction: 0,
      capability: 1,
      enabled: true,
      available: false,
    },
  ]
}

///|
fn tb_facts(t : Int32, s : Int32, edit : Int32, focused : Bool) -> Int32 {
  toolbar_context(
    t,
    Json::object({
      "hasRegion": Json(true),
      "blocked": Json(false),
      "fieldFocused": Json(focused),
      "pinAvailable": Json(true),
      "edit": Json(edit),
      "editVersion": Json(
        if edit == 0 {
          0
        } else {
          text_value(s, edit, 0).to_int()
        },
      ),
      "measuredHeight": Json(40),
      "capabilities": Json(0),
    }).stringify(),
  )
}

///|
fn tb_activate(t : Int32, id : String) -> Int32 {
  toolbar_activate(t, toolbar_value(t, 2).to_int(), id)
}

///|
fn tb_ack(t : Int32, ok : Int32) -> Int32 {
  toolbar_ack(
    t,
    toolbar_value(t, 6).to_int(),
    ok,
    if ok == 1 {
      ""
    } else {
      "native output failed"
    },
  )
}

///|
fn tb_cleanup(t : Int32, s : Int32, bank : Int32) -> Unit {
  ignore(toolbar_close(t))
  tx_cleanup(s, bank)
}

///|
test "toolbar uses stable IDs backend facts and explicit one-shot effect ACK" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let t = toolbar_open(s, bank, tb_entries())
  assert_true(t > 0)
  assert_eq(toolbar_open(s, bank, tb_entries()), 0)
  assert_eq(tb_facts(t, s, 0, false), 1)
  let epoch = toolbar_value(t, 2).to_int()
  assert_eq(tb_facts(t, s, 0, false), 1)
  assert_eq(toolbar_value(t, 2), epoch.to_double())
  assert_eq(tb_activate(t, "builtin.capture.ocr"), 0)
  assert_eq(tb_activate(t, "builtin.image.rectangle"), 1)
  assert_eq(toolbar_value(t, 0), 1)
  assert_eq(toolbar_text(t, 0), "builtin.image.rectangle")
  let ticket = toolbar_value(t, 6).to_int()
  assert_eq(toolbar_activate(t, epoch, "host.select"), 0)
  assert_eq(tb_activate(t, "host.confirm"), 0)
  assert_eq(toolbar_ack(t, ticket, 1, ""), 1)
  assert_eq(toolbar_ack(t, ticket, 1, ""), 0)
  assert_eq(tb_activate(t, "host.confirm"), 1)
  assert_eq(tb_ack(t, 0), 1)
  assert_eq(toolbar_text(t, 4), "native output failed")
  assert_eq(
    toolbar_event(
      t,
      toolbar_value(t, 2).to_int(),
      "{\"type\":\"pointerMove\",\"x\":0,\"y\":0}",
    ),
    1,
  )
  assert_eq(toolbar_text(t, 4), "")
  tb_cleanup(t, s, bank)
}

///|
test "pin renders exact unpublished candidate and failure preserves numeric draft" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let t = toolbar_open(s, bank, tb_entries())
  assert_eq(
    image_session_add_rgba(s, 1, 10, 20, 100, 50, 0x112233, 3, 24, 1),
    1,
  )
  let id = image_session_annotation_id(s, 0)
  let e = properties_begin(s, bank, 1, id, image_session_revision(s), "")
  assert_eq(tx_replace(s, e, "style.stroke", "7.25"), 1)
  let before = image_session_document(s)
  assert_eq(tb_facts(t, s, e, false), 1)
  assert_eq(tb_activate(t, "builtin.image.pin"), 1)
  let candidate = toolbar_value(t, 7).to_int()
  assert_eq(candidate_count(candidate), 1)
  assert_eq(candidate_value(candidate, 0, 6), 7.25)
  assert_eq(candidate_viewport_value(candidate, 2), 640)
  assert_eq(image_session_document(s), before)
  assert_eq(tb_ack(t, 0), 1)
  assert_eq(image_session_document(s), before)
  assert_eq(text_value(s, e, 16), 7.25)
  assert_eq(tb_activate(t, "builtin.image.pin"), 1)
  assert_eq(tb_ack(t, 1), 1)
  assert_eq(image_session_value(s, 0, 6), 7.25)
  assert_eq(text_value(s, e, 0), -1)
  assert_eq(image_session_undo(s), 1)
  assert_eq(image_session_value(s, 0, 6), 3)
  tb_cleanup(t, s, bank)
}

///|
test "invalid or stale property measurements veto selection and output without publishing" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let t = toolbar_open(s, bank, tb_entries())
  let e = prop_begin(s, bank, 1, "")
  assert_eq(tb_facts(t, s, e, false), 1)
  assert_eq(tx_replace(s, e, "style.stroke", "-"), 1)
  assert_eq(tb_activate(t, "builtin.image.text"), 0)
  assert_eq(tb_activate(t, "host.confirm"), 0)
  assert_eq(tx_replace(s, e, "style.stroke", "7.25"), 1)
  assert_eq(tb_activate(t, "builtin.image.text"), 0) // stale measured version
  assert_eq(tb_facts(t, s, e, false), 1)
  assert_eq(tb_activate(t, "builtin.image.text"), 1)
  assert_eq(editor_style_get(bank, 1, 2), 7.25)
  assert_eq(text_value(s, e, 0), -1)
  assert_eq(tb_ack(t, 1), 1)
  tb_cleanup(t, s, bank)
}

///|
test "toolbar undo follows root field history then authoritative document history" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let t = toolbar_open(s, bank, tb_entries())
  assert_eq(image_session_add(s, 1, 10, 10, 30, 40, 0x123456, 3), 1)
  let e = prop_begin(s, bank, 1, "")
  assert_eq(tx_replace(s, e, "style.stroke", "6.25"), 1)
  assert_eq(tb_facts(t, s, e, true), 1)
  assert_eq(tb_activate(t, "host.undo"), 1)
  assert_eq(text_value(s, e, 16), 4)
  assert_eq(image_session_count(s), 1)
  assert_eq(tb_ack(t, 1), 1)
  assert_eq(tb_facts(t, s, e, false), 1)
  assert_eq(tb_activate(t, "host.undo"), 1)
  assert_eq(image_session_count(s), 0)
  assert_eq(tb_ack(t, 1), 1)
  assert_eq(tb_facts(t, s, 0, false), 1)
  assert_eq(tb_activate(t, "host.redo"), 1)
  assert_eq(image_session_count(s), 1)
  assert_eq(tb_ack(t, 1), 1)
  tb_cleanup(t, s, bank)
}

///|
test "selected text property row does not impersonate a visible body editor for history" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let t = toolbar_open(s, bank, tb_entries())
  assert_eq(image_session_add_styled(s, 3, 10, 10, 200, 40, 0x123456, 3, 24), 1)
  let e = text_begin(
    s,
    bank,
    2,
    image_session_annotation_id(s, 0),
    image_session_revision(s),
    0,
    0,
    0,
    0,
  )
  assert_true(e > 0)
  let facts = Json::object({
    "hasRegion": Json(true),
    "blocked": Json(false),
    "fieldFocused": Json(false),
    "bodyEditing": Json(true),
    "pinAvailable": Json(true),
    "edit": Json(e),
    "editVersion": Json(text_value(s, e, 0).to_int()),
    "measuredHeight": Json(40),
  })
  assert_eq(toolbar_context(t, facts.stringify()), 1)
  assert_eq(tb_activate(t, "host.undo"), 0)
  assert_eq(image_session_count(s), 1)
  assert_eq(tb_facts(t, s, e, false), 1) // no visible body, only the selected object's property row
  assert_eq(tb_activate(t, "host.undo"), 1)
  assert_eq(image_session_count(s), 0)
  assert_eq(tb_ack(t, 1), 1)
  assert_eq(tb_facts(t, s, 0, false), 1)
  assert_eq(tb_activate(t, "host.redo"), 1)
  assert_eq(image_session_count(s), 1)
  assert_eq(tb_ack(t, 1), 1)
  tb_cleanup(t, s, bank)
}

///|
test "configuration preflights all owners and atomically publishes property candidates" {
  let a = image_session_create(640, 480)
  let b = image_session_create(640, 480)
  let sa = editor_style_create()
  let sb = editor_style_create()
  let ta = toolbar_open(a, sa, tb_entries())
  let tb = toolbar_open(b, sb, tb_entries())
  let ea = prop_begin(a, sa, 1, "")
  let eb = prop_begin(b, sb, 1, "")
  assert_eq(tx_replace(a, ea, "style.stroke", "5.5"), 1)
  assert_eq(tx_replace(b, eb, "style.stroke", "6.5"), 1)
  assert_eq(tb_facts(ta, a, ea, false), 1)
  assert_eq(tb_facts(tb, b, eb, false), 1)
  let replacement = tb_entries().filter(e => e.kind != 1)
  let ca = toolbar_config_prepare(ta, replacement)
  let cb = toolbar_config_prepare(tb, replacement)
  assert_true(ca > 0 && cb > 0)
  assert_eq(editor_style_get(sa, 1, 2), 4)
  assert_eq(tx_replace(b, eb, "style.stroke", "-"), 1)
  let request = Json::array([
    Json::object({ "toolbar": Json(ta), "candidate": Json(ca) }),
    Json::object({ "toolbar": Json(tb), "candidate": Json(cb) }),
  ]).stringify()
  assert_eq(toolbar_config_commit_many(request), 0)
  assert_eq(editor_style_get(sa, 1, 2), 4)
  assert_eq(toolbar_tool_enabled(ta, 1), 1)
  assert_eq(text_value(a, ea, 16), 5.5)
  assert_eq(tx_replace(b, eb, "style.stroke", "6.5"), 1)
  assert_eq(tb_facts(tb, b, eb, false), 1)
  let cb2 = toolbar_config_prepare(tb, replacement)
  assert_true(cb2 > cb)
  assert_eq(
    toolbar_config_commit_many(
      Json::array([
        Json::object({ "toolbar": Json(ta), "candidate": Json(ca) }),
        Json::object({ "toolbar": Json(tb), "candidate": Json(cb2) }),
      ]).stringify(),
    ),
    1,
  )
  assert_eq(editor_style_get(sa, 1, 2), 5.5)
  assert_eq(editor_style_get(sb, 1, 2), 6.5)
  assert_eq(toolbar_tool_enabled(ta, 1), 0)
  assert_eq(text_value(a, ea, 0), -1)
  assert_eq(text_value(b, eb, 0), -1)
  assert_eq(toolbar_config_commit_many(request), 0)
  tb_cleanup(ta, a, sa)
  tb_cleanup(tb, b, sb)
}

///|
test "config retains enabled edit and retired pointer generation cannot activate replaced catalog" {
  let s = image_session_create(640, 480)
  let bank = editor_style_create()
  let t = toolbar_open(s, bank, tb_entries())
  let e = prop_begin(s, bank, 1, "")
  assert_eq(tb_facts(t, s, e, false), 1)
  let generation = toolbar_value(t, 2).to_int()
  assert_true(toolbar_frame(t, 500, 0) != "")
  let c = toolbar_config_prepare(t, tb_entries())
  assert_true(c > 0)
  assert_eq(
    toolbar_config_commit_many("[{\"toolbar\":\{t},\"candidate\":\{c}}]"),
    1,
  )
  assert_true(text_value(s, e, 0) >= 0)
  assert_eq(toolbar_activate(t, generation, "builtin.image.rectangle"), 0)
  assert_eq(toolbar_config_close(c), 0)
  tb_cleanup(t, s, bank)
}
