///|
fn test_source(ms : Int32) -> String {
  Json::object({
    "durationMs": Json(ms),
    "width": Json(1920),
    "height": Json(1080),
    "hasAudio": Json(true),
  }).stringify()
}

///|
fn success(value : String) -> Map[String, Json] raise {
  object(@test_support.model_test_result(value))
}

///|
fn test_session(ms : Int32) -> Int32 raise {
  integer(success(open(test_source(ms), "")), "session", 0, 2147483647).to_int()
}

///|
fn current(id : Int32) -> Map[String, Json] raise {
  success(snapshot(id))
}

///|
fn edit(id : Int32, op : Json) -> Map[String, Json] raise {
  let state = current(id)
  success(
    command(
      id,
      Json::object({ "expectedRevision": state["revision"], "op": op }).stringify(),
    ),
  )
}

///|
fn simple(id : Int32, kind : String, clip : String) -> Map[String, Json] raise {
  edit(id, Json::object({ "type": Json(kind), "clipId": Json(clip) }))
}

///|
fn split_at(
  id : Int32,
  clip : String,
  ticks : Double,
) -> Map[String, Json] raise {
  edit(
    id,
    Json::object({
      "type": Json("split"),
      "clipId": Json(clip),
      "atTicks": Json(ticks),
    }),
  )
}

///|
fn clip(id : Int32, name : String) -> Map[String, Json] raise {
  let doc = @protocol.object_field(current(id), "document")
  match doc["clips"] {
    Array(values) =>
      for value in values {
        let fields = object(value)
        if fields["id"] == Json(name) {
          return fields
        }
      }
    _ => ()
  }
  abort("Missing clip \{name}")
}

///|
fn duration(id : Int32) -> Double raise {
  integer(
    @protocol.object_field(current(id), "plan"),
    "outputDurationTicks",
    0,
    max_ticks,
  )
}

///|
fn expect_failure(id : Int32, op : Json, code : String) -> Unit raise {
  let before = current(id)
  @test_support.expect_error(
    command(
      id,
      Json::object({ "expectedRevision": before["revision"], "op": op }).stringify(),
    ),
    code,
  )
  assert_eq(Json::object(current(id)), Json::object(before))
}

///|
test "global crop and mute reuse v1 normalization and form atomic undoable edits" {
  let id = test_session(4000)
  let original = current(id)
  let crop = @json.parse(
    "{\"type\":\"crop\",\"crop\":{\"x\":11,\"y\":17,\"width\":501,\"height\":301}}",
  )
  let legacy = success(@video.video_open(test_source(4000), ""))
  let legacy_id = integer(legacy, "session", 0, 2147483647).to_int()
  let old_cropped = success(@video.video_command(legacy_id, crop.stringify()))
  let changed = success(
    command(
      id,
      Json::object({
        "expectedRevision": original["revision"],
        "operations": Json::array([
          crop,
          @json.parse("{\"type\":\"mute\",\"muted\":true}"),
        ]),
      }).stringify(),
    ),
  )
  let doc = @protocol.object_field(changed, "document")
  let plan = @protocol.object_field(changed, "plan")
  assert_eq(
    doc["crop"],
    @protocol.object_field(old_cropped, "document")["crop"],
  )
  assert_eq(
    doc["crop"],
    @json.parse("{\"x\":11,\"y\":17,\"width\":500,\"height\":300}"),
  )
  assert_eq(doc["muted"], Json(true))
  assert_eq(plan["audio"], Json::array([]))
  assert_eq(plan["outputDurationTicks"], Json(360000))
  assert_eq(doc["clips"], @protocol.object_field(original, "document")["clips"])
  assert_eq(changed["revision"], Json(1))
  let reopened = success(open(test_source(4000), Json::object(doc).stringify()))
  assert_eq(reopened["plan"], changed["plan"])
  close(integer(reopened, "session", 0, 2147483647).to_int())
  assert_eq(
    edit(id, @json.parse("{\"type\":\"undo\"}"))["plan"],
    original["plan"],
  )
  assert_eq(
    edit(id, @json.parse("{\"type\":\"redo\"}"))["plan"],
    changed["plan"],
  )
  let before = current(id)
  @test_support.expect_error(
    command(
      id,
      Json::object({
        "expectedRevision": before["revision"],
        "operations": Json::array([
          @json.parse("{\"type\":\"mute\",\"muted\":false}"),
          @json.parse(
            "{\"type\":\"crop\",\"crop\":{\"x\":1919,\"y\":0,\"width\":2,\"height\":2}}",
          ),
        ]),
      }).stringify(),
    ),
    "invalid_input",
  )
  assert_eq(Json::object(current(id)), Json::object(before))
  for
    invalid in [
      "{\"type\":\"mute\",\"muted\":1}", "{\"type\":\"crop\",\"crop\":{\"x\":0.5,\"y\":0,\"width\":10,\"height\":10}}",
      "{\"type\":\"crop\",\"crop\":{\"x\":0,\"y\":0,\"width\":1,\"height\":10}}",
    ] {
    expect_failure(id, @json.parse(invalid), "invalid_input")
  }
  ignore(edit(id, @json.parse("{\"type\":\"crop\",\"crop\":null}")))
  let unmuted = edit(id, @json.parse("{\"type\":\"mute\",\"muted\":false}"))
  assert_eq(unmuted["plan"], original["plan"])
  assert_eq(
    edit(id, @json.parse("{\"type\":\"mute\",\"muted\":false}"))["revision"],
    unmuted["revision"],
  )
  @video.video_dispose(legacy_id)
  close(id)
}

///|
test "180 seconds becomes 60 seconds with linked audio and target duration roundtrip" {
  let id = test_session(180000)
  let changed = edit(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":3,\"den\":1}}",
    ),
  )
  assert_eq(changed["revision"], Json(1))
  assert_eq(duration(id), 5400000)
  for name in ["v1", "a1"] {
    let c = clip(id, name)
    assert_eq(c["sourceStartTicks"], Json(0))
    assert_eq(c["sourceEndTicks"], Json(16200000))
    assert_eq(c["durationTicks"], Json(5400000))
  }
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"a1\",\"targetDurationTicks\":16200000}",
      ),
    ),
  )
  assert_eq(duration(id), 16200000)
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"targetDurationTicks\":5400000}",
      ),
    ),
  )
  assert_eq(duration(id), 5400000)
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":5,\"den\":1}}",
    ),
    "unsupported_speed",
  )
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":3,\"den\":1},\"targetDurationTicks\":5400000}",
    ),
    "invalid_input",
  )
  close(id)
}

///|
test "split reorder speed delete undo unlink offset and saved v2 plan roundtrip" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  ignore(split_at(id, "v2", 180000))
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"move\",\"clipId\":\"v3\",\"beforeClipId\":\"v2\"}",
      ),
    ),
  )
  assert_eq(clip(id, "v3")["startTicks"], Json(90000))
  assert_eq(clip(id, "a3")["startTicks"], Json(90000))
  assert_eq(clip(id, "v2")["startTicks"], Json(270000))
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v3\",\"rate\":{\"num\":3,\"den\":1}}",
      ),
    ),
  )
  assert_eq(duration(id), 240000)
  assert_eq(clip(id, "v2")["startTicks"], Json(150000))
  ignore(simple(id, "remove", "v2"))
  assert_eq(duration(id), 150000)
  ignore(edit(id, @json.parse("{\"type\":\"undo\"}")))
  assert_eq(duration(id), 240000)
  ignore(simple(id, "unlink", "v3"))
  assert_eq(clip(id, "v3")["linkGroup"], Json::null())
  assert_eq(clip(id, "a3")["linkGroup"], Json::null())
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"offset\",\"clipId\":\"a3\",\"deltaTicks\":3000}"),
    ),
  )
  assert_eq(clip(id, "a3")["startTicks"], Json(93000))
  assert_eq(clip(id, "v3")["startTicks"], Json(90000))
  let saved = current(id)
  assert_eq(saved["revision"], Json(8))
  let reopened = success(open(test_source(4000), saved["document"].stringify()))
  assert_eq(reopened["plan"], saved["plan"])
  assert_eq(reopened["document"], saved["document"])
  assert_eq(reopened["canUndo"], Json(false))
  close(integer(reopened, "session", 0, 2147483647).to_int())
  close(id)
}

///|
test "atomic batches revision conflicts and cached retries do not partly commit or duplicate clips" {
  let id = test_session(4000)
  let before = current(id)
  let failed = Json::object({
    "expectedRevision": Json(0),
    "requestId": Json("attempt"),
    "operations": Json::array([
      @json.parse("{\"type\":\"split\",\"clipId\":\"v1\",\"atTicks\":90000}"),
      @json.parse("{\"type\":\"remove\",\"clipId\":\"missing\"}"),
    ]),
  }).stringify()
  @test_support.expect_error(command(id, failed), "unknown_clip")
  assert_eq(Json::object(current(id)), Json::object(before))
  let request = Json::object({
    "expectedRevision": Json(0),
    "requestId": Json("accepted"),
    "operations": Json::array([
      @json.parse("{\"type\":\"split\",\"clipId\":\"v1\",\"atTicks\":90000}"),
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v2\",\"rate\":{\"num\":3,\"den\":1}}",
      ),
    ]),
  }).stringify()
  let accepted = success(command(id, request))
  assert_eq(accepted["revision"], Json(1))
  assert_eq(duration(id), 180000)
  assert_eq(Json::object(success(command(id, request))), Json::object(accepted))
  @test_support.expect_error(
    command(
      id, "{\"expectedRevision\":0,\"type\":\"unlink\",\"clipId\":\"v1\"}",
    ),
    "revision_conflict",
  )
  @test_support.expect_error(
    command(
      id, "{\"expectedRevision\":1,\"requestId\":\"accepted\",\"type\":\"unlink\",\"clipId\":\"v1\"}",
    ),
    "request_id_conflict",
  )
  ignore(edit(id, @json.parse("{\"type\":\"undo\"}")))
  assert_eq(duration(id), 360000)
  assert_eq(current(id)["revision"], Json(2))
  assert_eq(current(id)["canUndo"], Json(false))
  ignore(split_at(id, "v1", 6000))
  assert_eq(clip(id, "v3")["startTicks"], Json(6000))
  assert_eq(current(id)["revision"], Json(3))
  assert_eq(current(id)["canRedo"], Json(false))
  let latest = current(id)
  assert_eq(Json::object(success(command(id, request))), Json::object(accepted))
  assert_eq(Json::object(current(id)), Json::object(latest))
  close(id)
}

///|
test "non-ripple removal leaves a gap and removing last video is rejected atomically" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  ignore(split_at(id, "v2", 180000))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"remove\",\"clipId\":\"v2\",\"ripple\":false}"),
    ),
  )
  assert_eq(duration(id), 360000)
  assert_eq(clip(id, "v3")["startTicks"], Json(180000))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"remove\",\"clipId\":\"v1\",\"ripple\":false}"),
    ),
  )
  expect_failure(
    id,
    @json.parse("{\"type\":\"remove\",\"clipId\":\"v3\"}"),
    "empty_output",
  )
  close(id)
}

///|
test "independent audio never silently ripples and offset permits an explicit audio tail" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  ignore(simple(id, "unlink", "v1"))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"offset\",\"clipId\":\"a1\",\"deltaTicks\":3000}"),
    ),
  )
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":3,\"den\":1}}",
    ),
    "ambiguous_ripple",
  )
  expect_failure(
    id,
    @json.parse("{\"type\":\"move\",\"clipId\":\"a1\",\"beforeClipId\":null}"),
    "independent_audio_move",
  )
  expect_failure(
    id,
    @json.parse("{\"type\":\"offset\",\"clipId\":\"a1\",\"deltaTicks\":-6000}"),
    "invalid_clip",
  )
  expect_failure(
    id,
    @json.parse("{\"type\":\"offset\",\"clipId\":\"a2\",\"deltaTicks\":3000}"),
    "linked_audio",
  )
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":3,\"den\":1},\"ripple\":false}",
      ),
    ),
  )
  assert_eq(clip(id, "a1")["durationTicks"], Json(90000))
  assert_eq(clip(id, "v1")["durationTicks"], Json(30000))
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"offset\",\"clipId\":\"a1\",\"deltaTicks\":360000}",
      ),
    ),
  )
  assert_eq(duration(id), 453000)
  close(id)
}

///|
test "1.5x split keeps exact fractional frame source bounds and trim preserves the untouched edge" {
  let id = test_session(300)
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":3,\"den\":2}}",
      ),
    ),
  )
  ignore(split_at(id, "v1", 3000))
  assert_eq(clip(id, "v1")["sourceEndTicks"], Json(4500))
  assert_eq(clip(id, "v2")["sourceStartTicks"], Json(4500))
  assert_eq(clip(id, "a2")["sourceStartTicks"], Json(4500))
  assert_eq(clip(id, "v2")["durationTicks"], Json(15000))
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"trim\",\"clipId\":\"v2\",\"sourceStartTicks\":4500,\"sourceEndTicks\":18000}",
      ),
    ),
  )
  assert_eq(clip(id, "v2")["sourceStartTicks"], Json(4500))
  assert_eq(clip(id, "a2")["sourceStartTicks"], Json(4500))
  assert_eq(clip(id, "v2")["durationTicks"], Json(9000))
  close(id)
}

///|
test "non-integral split rounds one shared source tick and preserves complete output duration" {
  let initial = success(open(test_source(200), ""))
  let doc = @protocol.object_field(initial, "document")
  let values = match doc["clips"] {
    Array(values) => values
    _ => abort("clips")
  }
  for value in values {
    let fields = object(value)
    fields["sourceEndTicks"] = Json(10001)
    fields["durationTicks"] = Json(9000)
  }
  let state = success(open(test_source(200), Json::object(doc).stringify()))
  let id = integer(state, "session", 0, 2147483647).to_int()
  ignore(split_at(id, "v1", 3000))
  let a = clip(id, "v1")
  let b = clip(id, "v2")
  assert_eq(a["sourceEndTicks"], Json(3334))
  assert_eq(b["sourceStartTicks"], a["sourceEndTicks"])
  assert_eq(b["sourceEndTicks"], Json(10001))
  assert_true(3334.0 - 10001.0 / 3 < 0.5)
  assert_eq(duration(id), 9000)
  close(id)
  close(integer(initial, "session", 0, 2147483647).to_int())
}

///|
test "frame quantization reports actual bounds and never expands subframe speed into one frame" {
  let id = test_session(100)
  ignore(split_at(id, "v1", 4500))
  assert_eq(clip(id, "v1")["durationTicks"], Json(6000))
  assert_eq(clip(id, "v2")["durationTicks"], Json(3000))
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":3,\"den\":1}}",
    ),
    "too_short",
  )
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"targetDurationTicks\":2999}",
    ),
    "invalid_input",
  )
  close(id)
}

///|
test "v1 migration uses actual retained intervals and preserves crop mute and source metadata" {
  let draft = "{\"schemaVersion\":1,\"trim\":{\"startMs\":1000,\"endMs\":9000},\"cuts\":[{\"startMs\":2000,\"endMs\":4000}],\"crop\":{\"x\":10,\"y\":10,\"width\":501,\"height\":301},\"muted\":true,\"preset\":\"quality\"}"
  let migrated = success(open(test_source(10000), draft))
  let id = integer(migrated, "session", 0, 2147483647).to_int()
  assert_eq(clip(id, "v1")["sourceStartTicks"], Json(90000))
  assert_eq(clip(id, "v2")["sourceStartTicks"], Json(360000))
  assert_eq(clip(id, "v2")["startTicks"], Json(90000))
  assert_eq(duration(id), 540000)
  let plan = @protocol.object_field(migrated, "plan")
  assert_eq(plan["audio"], Json::array([]))
  assert_eq(@protocol.object_field(plan, "crop")["width"], Json(500))
  assert_eq(clip(id, "a2")["durationTicks"], clip(id, "v2")["durationTicks"])
  ignore(simple(id, "unlink", "a2"))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"offset\",\"clipId\":\"a2\",\"deltaTicks\":3000}"),
    ),
  )
  assert_eq(duration(id), 543000)
  assert_eq(
    @protocol.object_field(current(id), "plan")["audio"],
    Json::array([]),
  )
  @test_support.expect_error(
    open(test_source(12000), migrated["document"].stringify()),
    "source_mismatch",
  )
  close(id)
}

///|
test "malformed v2 state and missing revision are rejected without trusting a supplied plan" {
  let id = test_session(4000)
  @test_support.expect_error(
    command(id, "{\"type\":\"split\",\"clipId\":\"v1\",\"atTicks\":90000}"),
    "invalid_input",
  )
  let state = current(id)
  let doc = @protocol.object_field(state, "document")
  doc["timebase"] = Json(1000)
  @test_support.expect_error(
    open(test_source(4000), Json::object(doc).stringify()),
    "invalid_input",
  )
  doc["timebase"] = Json(90000)
  doc["captions"] = Json::array([])
  @test_support.expect_error(
    open(test_source(4000), Json::object(doc).stringify()),
    "unsupported_field",
  )
  assert_eq(current(id)["revision"], Json(0))
  close(id)
  @test_support.expect_error(snapshot(id), "unknown_session")
}

///|
test "seven-day split uses exact integer rounding near a half tick" {
  let source = "{\"durationMs\":604800000,\"width\":1920,\"height\":1080,\"hasAudio\":false}"
  let initial = success(open(source, ""))
  let doc = @protocol.object_field(initial, "document")
  let values = match doc["clips"] {
    Array(values) => values
    _ => abort("clips")
  }
  for value in values {
    let fields = object(value)
    fields["sourceEndTicks"] = Json(52346568836.0)
    fields["durationTicks"] = Json(53767332000.0)
  }
  let state = success(open(source, Json::object(doc).stringify()))
  let id = integer(state, "session", 0, 2147483647).to_int()
  ignore(split_at(id, "v1", 39885324000))
  // Exact quotient: 38831382935 + 8961148/17922444, just below half.
  assert_eq(clip(id, "v1")["sourceEndTicks"], Json(38831382935.0))
  assert_eq(clip(id, "v2")["sourceStartTicks"], Json(38831382935.0))
  assert_eq(duration(id), 53767332000)
  close(id)
  close(integer(initial, "session", 0, 2147483647).to_int())
}

///|
test "redo advances revision and moving the first linked clip to the end preserves each source" {
  let id = test_session(3000)
  ignore(split_at(id, "v1", 90000))
  ignore(split_at(id, "v2", 180000))
  let before = current(id)
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"move\",\"clipId\":\"a1\",\"beforeClipId\":null}"),
    ),
  )
  assert_eq(clip(id, "v2")["startTicks"], Json(0))
  assert_eq(clip(id, "v3")["startTicks"], Json(90000))
  assert_eq(clip(id, "v1")["startTicks"], Json(180000))
  assert_eq(clip(id, "a1")["startTicks"], Json(180000))
  assert_eq(clip(id, "v1")["sourceStartTicks"], Json(0))
  let moved = current(id)
  ignore(edit(id, @json.parse("{\"type\":\"undo\"}")))
  assert_eq(current(id)["plan"], before["plan"])
  assert_eq(current(id)["revision"], Json(4))
  ignore(edit(id, @json.parse("{\"type\":\"redo\"}")))
  assert_eq(current(id)["plan"], moved["plan"])
  assert_eq(current(id)["revision"], Json(5))
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"trim\",\"clipId\":\"v1\",\"sourceStartTicks\":0,\"sourceEndTicks\":6000,\"linked\":false}",
    ),
    "linked_clip",
  )
  close(id)
}

///|
test "trim preserves clip start and explicitly distinguishes ripple from overlap" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"trim\",\"clipId\":\"v1\",\"sourceStartTicks\":0,\"sourceEndTicks\":180000,\"ripple\":false}",
    ),
    "overlap",
  )
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"trim\",\"clipId\":\"v1\",\"sourceStartTicks\":3000,\"sourceEndTicks\":90000}",
      ),
    ),
  )
  assert_eq(clip(id, "v1")["startTicks"], Json(0))
  assert_eq(clip(id, "a1")["sourceStartTicks"], Json(3000))
  assert_eq(clip(id, "v2")["startTicks"], Json(87000))
  assert_eq(clip(id, "a2")["startTicks"], Json(87000))
  assert_eq(duration(id), 357000)
  close(id)
}

///|
test "silent sources stay silent and invalid orphan links cannot be reopened" {
  let source = "{\"durationMs\":4000,\"width\":1920,\"height\":1080,\"hasAudio\":false}"
  let state = success(open(source, ""))
  let id = integer(state, "session", 0, 2147483647).to_int()
  assert_eq(clip(id, "v1")["linkGroup"], Json::null())
  assert_eq(@protocol.object_field(state, "plan")["audio"], Json::array([]))
  ignore(split_at(id, "v1", 90000))
  assert_eq(clip(id, "v2")["linkGroup"], Json::null())
  let doc = @protocol.object_field(current(id), "document")
  let values = match doc["clips"] {
    Array(values) => values
    _ => abort("clips")
  }
  object(values[0])["linkGroup"] = Json("g1")
  @test_support.expect_error(
    open(source, Json::object(doc).stringify()),
    "invalid_link",
  )
  close(id)
}

///|
test "evicted retry receipts fail stale revision instead of applying an old operation twice" {
  let id = test_session(4000)
  let original = "{\"expectedRevision\":0,\"requestId\":\"first\",\"type\":\"unlink\",\"clipId\":\"a1\"}"
  ignore(success(command(id, original)))
  for i in 0..<65 {
    let state = current(id)
    ignore(
      success(
        command(
          id,
          Json::object({
            "expectedRevision": state["revision"],
            "requestId": Json("offset-\{i}"),
            "type": Json("offset"),
            "clipId": Json("a1"),
            "deltaTicks": Json(if i % 2 == 0 { 3000 } else { -3000 }),
          }).stringify(),
        ),
      ),
    )
  }
  let before = current(id)
  @test_support.expect_error(command(id, original), "revision_conflict")
  assert_eq(Json::object(current(id)), Json::object(before))
  close(id)
}

///|
test "audio slowdown is atomically refused while unlinked video and silent media may slow down" {
  let id = test_session(4000)
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":1,\"den\":2}}",
    ),
    "unsupported_audio_slowdown",
  )
  ignore(simple(id, "unlink", "a1"))
  expect_failure(
    id,
    @json.parse(
      "{\"type\":\"setSpeed\",\"clipId\":\"a1\",\"targetDurationTicks\":720000,\"ripple\":false}",
    ),
    "unsupported_audio_slowdown",
  )
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":1,\"den\":2},\"ripple\":false}",
      ),
    ),
  )
  assert_eq(clip(id, "v1")["durationTicks"], Json(720000))
  assert_eq(clip(id, "a1")["durationTicks"], Json(360000))
  assert_eq(duration(id), 720000)
  close(id)
  let source = "{\"durationMs\":4000,\"width\":1920,\"height\":1080,\"hasAudio\":false}"
  let state = success(open(source, ""))
  let silent = integer(state, "session", 0, 2147483647).to_int()
  ignore(
    edit(
      silent,
      @json.parse(
        "{\"type\":\"setSpeed\",\"clipId\":\"v1\",\"rate\":{\"num\":1,\"den\":4}}",
      ),
    ),
  )
  assert_eq(duration(silent), 1440000)
  assert_eq(
    @protocol.object_field(current(silent), "plan")["audio"],
    Json::array([]),
  )
  close(silent)
}

///|
test "removeGap closes an exact internal gap once and preserves boundary touching audio" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  ignore(split_at(id, "v2", 180000))
  ignore(simple(id, "unlink", "v1"))
  ignore(simple(id, "unlink", "v3"))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"remove\",\"clipId\":\"v2\",\"ripple\":false}"),
    ),
  )
  let gap = @json.parse(
    "{\"type\":\"removeGap\",\"startTicks\":90000,\"endTicks\":180000}",
  )
  let before = current(id)
  for
    invalid in [
      "{\"type\":\"removeGap\",\"startTicks\":93000,\"endTicks\":180000}", "{\"type\":\"removeGap\",\"startTicks\":90000,\"endTicks\":177000}",
      "{\"type\":\"removeGap\",\"startTicks\":89999,\"endTicks\":180000}", "{\"type\":\"removeGap\",\"startTicks\":0,\"endTicks\":180000}",
    ] {
    expect_failure(id, @json.parse(invalid), "invalid_gap")
  }
  // A valid first operation followed by a stale gap is one failed transaction.
  @test_support.expect_error(
    command(
      id,
      Json::object({
        "expectedRevision": before["revision"],
        "operations": Json::array([gap, gap]),
      }).stringify(),
    ),
    "invalid_gap",
  )
  assert_eq(Json::object(current(id)), Json::object(before))
  let removed = edit(id, gap)
  assert_eq(
    integer(removed, "revision", 0, max_ticks),
    integer(before, "revision", 0, max_ticks) + 1,
  )
  assert_eq(duration(id), 270000)
  for name in ["v1", "a1"] {
    assert_eq(clip(id, name)["startTicks"], Json(0))
    assert_eq(clip(id, name)["durationTicks"], Json(90000))
  }
  for name in ["v3", "a3"] {
    assert_eq(clip(id, name)["startTicks"], Json(90000))
    assert_eq(clip(id, name)["sourceStartTicks"], Json(180000))
    assert_eq(clip(id, name)["sourceEndTicks"], Json(360000))
  }
  expect_failure(id, gap, "invalid_gap")
  @test_support.expect_error(
    command(
      id,
      Json::object({ "expectedRevision": before["revision"], "op": gap }).stringify(),
    ),
    "revision_conflict",
  )
  let undone = edit(id, @json.parse("{\"type\":\"undo\"}"))
  assert_eq(undone["plan"], before["plan"])
  assert_eq(
    edit(id, @json.parse("{\"type\":\"redo\"}"))["plan"],
    removed["plan"],
  )
  close(id)
}

///|
test "removeGap closes a leading gap but rejects empty past end and partial ranges" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"remove\",\"clipId\":\"v1\",\"ripple\":false}"),
    ),
  )
  let before = current(id)
  ignore(
    edit(
      id,
      @json.parse(
        "{\"type\":\"removeGap\",\"startTicks\":0,\"endTicks\":90000}",
      ),
    ),
  )
  assert_eq(duration(id), 270000)
  for name in ["v2", "a2"] {
    assert_eq(clip(id, name)["startTicks"], Json(0))
    assert_eq(clip(id, name)["sourceStartTicks"], Json(90000))
  }
  for
    invalid in [
      "{\"type\":\"removeGap\",\"startTicks\":270000,\"endTicks\":360000}", "{\"type\":\"removeGap\",\"startTicks\":0,\"endTicks\":0}",
      "{\"type\":\"removeGap\",\"startTicks\":90000,\"endTicks\":0}",
    ] {
    expect_failure(id, @json.parse(invalid), "invalid_gap")
  }
  assert_eq(
    edit(id, @json.parse("{\"type\":\"undo\"}"))["plan"],
    before["plan"],
  )
  close(id)
}

///|
test "removeGap atomically refuses audio occupying any part of the gap including muted tails" {
  let id = test_session(4000)
  ignore(split_at(id, "v1", 90000))
  ignore(split_at(id, "v2", 180000))
  ignore(simple(id, "unlink", "v2"))
  ignore(
    edit(
      id,
      @json.parse("{\"type\":\"remove\",\"clipId\":\"v2\",\"ripple\":false}"),
    ),
  )
  let gap = @json.parse(
    "{\"type\":\"removeGap\",\"startTicks\":90000,\"endTicks\":180000}",
  )
  expect_failure(id, gap, "ambiguous_ripple")
  for delta in [-3000, 90000] {
    ignore(
      edit(
        id,
        Json::object({
          "type": Json("offset"),
          "clipId": Json("a2"),
          "deltaTicks": Json(delta),
        }),
      ),
    )
    expect_failure(id, gap, "ambiguous_ripple")
  }
  close(id)
  let tail = test_session(4000)
  ignore(simple(tail, "unlink", "a1"))
  ignore(
    edit(
      tail,
      @json.parse(
        "{\"type\":\"offset\",\"clipId\":\"a1\",\"deltaTicks\":90000}",
      ),
    ),
  )
  let tail_gap = @json.parse(
    "{\"type\":\"removeGap\",\"startTicks\":360000,\"endTicks\":450000}",
  )
  expect_failure(tail, tail_gap, "ambiguous_ripple")
  let doc = @protocol.object_field(current(tail), "document")
  doc["muted"] = Json(true)
  let muted = integer(
    success(open(test_source(4000), Json::object(doc).stringify())),
    "session",
    0,
    2147483647,
  ).to_int()
  expect_failure(muted, tail_gap, "ambiguous_ripple")
  close(muted)
  close(tail)
}
