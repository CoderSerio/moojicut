///|
fn video_test_source() -> String {
  "{\"durationMs\":10000,\"width\":1920,\"height\":1080,\"hasAudio\":true}"
}

///|
test "clearing cuts and reset remove the legacy single-cut field" {
  let draft =
    #|{"schemaVersion":1,"trim":{"startMs":0,"endMs":10000},"cut":{"startMs":1000,"endMs":2000},"cuts":[],"crop":null,"muted":false,"preset":"share"}
  for action in ["clearCuts", "reset"] {
    let state = model_test_result(video_open(video_test_source(), draft))
    let id = number_result(state.stringify(), "session").to_int()
    assert_eq(number_result(model_test_field(state, "plan").stringify(), "outputDurationMs"), 9000)
    let changed = video_test_command(id, Json::object({ "type": Json(action) }).stringify())
    assert_eq(number_result(model_test_field(changed, "plan").stringify(), "outputDurationMs"), 10000)
    let restored = video_test_command(id, "{\"type\":\"undo\"}")
    assert_eq(number_result(model_test_field(restored, "plan").stringify(), "outputDurationMs"), 9000)
    video_dispose(id)
  }
}

///|
fn video_test_command(id : Int32, command : String) -> Json raise {
  model_test_result(video_command(id, command))
}

///|
test "overlapping video cuts merge and rejected edits preserve document and history" {
  let mut state = model_test_result(video_open(video_test_source(), ""))
  let id = number_result(state.stringify(), "session").to_int()
  for
    command in [
      "{\"type\":\"cut\",\"cut\":{\"startMs\":4000,\"endMs\":6000}}", "{\"type\":\"cut\",\"cut\":{\"startMs\":2000,\"endMs\":4500}}",
      "{\"type\":\"cut\",\"cut\":{\"startMs\":6000,\"endMs\":7000}}",
    ] {
    state = video_test_command(id, command)
  }
  let segments = model_test_field(model_test_field(state, "plan"), "segments")
  expect_json(
    segments.stringify(),
    (
      #|[{"sourceStartMs":0,"sourceEndMs":2000,"outputStartMs":0,"outputEndMs":2000},{"sourceStartMs":7000,"sourceEndMs":10000,"outputStartMs":2000,"outputEndMs":5000}]
    ),
  )
  state = video_test_command(
    id,
    (
      #|{"type":"trim","trim":{"startMs":3000,"endMs":9000}}
    ),
  )
  assert_eq(
    number_result(
      model_test_field(state, "plan").stringify(),
      "outputDurationMs",
    ),
    2000,
  )
  state = video_test_command(
    id,
    (
      #|{"type":"trim","trim":{"startMs":0,"endMs":10000}}
    ),
  )
  assert_eq(
    number_result(
      model_test_field(state, "plan").stringify(),
      "outputDurationMs",
    ),
    5000,
  )
  let before = video_snapshot(id)
  expect_error(
    video_command(
      id,
      (
        #|{"type":"cut","cut":{"startMs":0,"endMs":10000}}
      ),
    ),
    "empty_output",
  )
  expect_json(video_snapshot(id), before)
  state = video_test_command(id, "{\"type\":\"undo\"}")
  assert_eq(
    number_result(
      model_test_field(state, "plan").stringify(),
      "outputDurationMs",
    ),
    2000,
  )
  state = video_test_command(id, "{\"type\":\"redo\"}")
  assert_eq(
    number_result(
      model_test_field(state, "plan").stringify(),
      "outputDurationMs",
    ),
    5000,
  )
  ignore(video_test_command(id, "{\"type\":\"undo\"}"))
  state = video_test_command(id, "{\"type\":\"mute\",\"muted\":true}")
  assert_true(model_test_field(state, "canRedo") == Json(false))
  video_dispose(id)
}

///|
test "video drafts preserve source metadata and reset is undoable" {
  let mut state = model_test_result(video_open(video_test_source(), ""))
  let id = number_result(state.stringify(), "session").to_int()
  state = video_test_command(
    id,
    (
      #|{"type":"crop","crop":{"x":11,"y":17,"width":501,"height":301}}
    ),
  )
  expect_json(
    model_test_field(model_test_field(state, "document"), "crop").stringify(),
    (
      #|{"x":11,"y":17,"width":500,"height":300}
    ),
  )
  state = video_test_command(
    id,
    (
      #|{"type":"cut","cut":{"startMs":2000,"endMs":5000}}
    ),
  )
  expect_json(
    video_seek(id, 3000),
    (
      #|{"ok":true,"sourceMs":5000,"outputMs":2000,"atEnd":false}
    ),
  )
  assert_eq(number_result(video_seek(id, 6000), "outputMs"), 3000)
  assert_true(
    model_test_field(model_test_result(video_seek(id, 10000)), "atEnd") ==
    Json(true),
  )
  let draft = model_test_field(state, "document")
  let modified = match @json.parse(draft.stringify()) {
    Object(fields) => fields
    _ => abort("draft")
  }
  modified["source"] = @json.parse(
    "{\"durationMs\":10000,\"width\":99,\"height\":1080,\"hasAudio\":true}",
  )
  let reopened = model_test_result(
    video_open(video_test_source(), Json::object(modified).stringify()),
  )
  assert_true(
    model_test_field(
      model_test_field(model_test_field(reopened, "document"), "source"),
      "width",
    ) ==
    Json(1920),
  )
  assert_true(
    model_test_field(reopened, "plan") == model_test_field(state, "plan"),
  )
  video_dispose(number_result(reopened.stringify(), "session").to_int())
  state = video_test_command(id, "{\"type\":\"reset\"}")
  assert_true(
    model_test_field(model_test_field(state, "document"), "crop") ==
    Json::null(),
  )
  assert_eq(
    number_result(
      model_test_field(state, "plan").stringify(),
      "outputDurationMs",
    ),
    10000,
  )
  state = video_test_command(id, "{\"type\":\"undo\"}")
  assert_true(model_test_field(state, "document") == draft)
  video_dispose(id)
}

///|
test "legacy single cuts combine with multiple cuts and malformed intervals are rejected" {
  let plan = model_test_result(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":0,"endMs":10000},"cut":{"startMs":1000,"endMs":2000},"cuts":[{"startMs":6000,"endMs":7000},{"startMs":2000,"endMs":3000}]}
      ),
    ),
  )
  assert_eq(number_result(plan.stringify(), "outputDurationMs"), 7000)
  expect_json(
    model_test_field(plan, "segments").stringify(),
    (
      #|[{"sourceStartMs":0,"sourceEndMs":1000,"outputStartMs":0,"outputEndMs":1000},{"sourceStartMs":3000,"sourceEndMs":6000,"outputStartMs":1000,"outputEndMs":4000},{"sourceStartMs":7000,"sourceEndMs":10000,"outputStartMs":4000,"outputEndMs":7000}]
    ),
  )
  expect_error(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":0,"endMs":10000},"cuts":[{"startMs":1,"endMs":null}]}
      ),
    ),
    "invalid_input",
  )
}
