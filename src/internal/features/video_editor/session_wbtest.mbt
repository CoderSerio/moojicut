///|
let fixture_source : String = "{\"durationMs\":12000,\"width\":1920,\"height\":1080,\"hasAudio\":true}"

///|
test "restored v2 draft must save at the new destination before close" {
  let source = fixture()
  finish_effects(source)
  let draft = text(source, 1)
  dispose(source)
  let restored = open_unsaved("/recordings/session/source.webm", fixture_source, draft)
  assert_true(restored > 0)
  assert_eq(value(restored, 1), 1)
  assert_true(request_close(restored, false))
  let save = take_effect(restored)
  assert_eq(effect_kind(restored, save), 2)
  assert_eq(effect_text(restored, save), draft)
  assert_eq(take_effect(restored), 0)
  assert_true(ack(restored, save, 0, ""))
  let close = take_effect(restored)
  assert_eq(effect_kind(restored, close), 9)
  assert_true(ack(restored, close, 0, ""))
  assert_true(release(restored))
}

///|
fn fixture() -> Int32 raise {
  let id = open("/recordings/session/source.webm", fixture_source, "")
  assert_true(id > 0)
  id
}

///|
fn finish_effects(id : Int32) -> Unit raise {
  for _ in 0..<32 {
    let e = take_effect(id)
    if e == 0 {
      return
    }
    let kind = effect_kind(id, e)
    assert_true(kind >= 1 && kind <= 5)
    assert_true(ack(id, e, 0, ""))
  }
  abort("unexpected effect loop")
}

///|
fn dispose(id : Int32) -> Unit raise {
  finish_effects(id)
  assert_true(request_close(id, false))
  let e = take_effect(id)
  assert_eq(effect_kind(id, e), 9)
  assert_true(!release(id))
  assert_true(ack(id, e, 0, ""))
  assert_eq(value(id, 0), 3)
  assert_true(release(id))
  assert_eq(value(id, 0), -1)
}

///|
fn operation(id : Int32, op : Json) -> Bool {
  command(
    id,
    Json::object({ "expectedRevision": Json(number(id, 0)), "op": op }).stringify(),
  )
}

///|
fn activate(id : Int32, target : String) -> Bool {
  event(
    id,
    Json::object({ "type": Json("activate"), "id": Json(target) }).stringify(),
  )
}

///|
fn node(id : Int32, name : String) -> Map[String, Json] raise {
  let f = @test_support.model_test_result(frame(id, 1040, 700))
  for
    item in @test_support.model_test_items(
      @test_support.model_test_field(f, "semantics"),
    ) {
    match item {
      Object(m) if m.get("id") == Some(Json(name)) => return m
      _ => ()
    }
  }
  abort("missing semantic \{name}")
}

///|
fn pointer(id : Int32, kind : String, x : Double, y : Double) -> Bool {
  event(
    id,
    Json::object({ "type": Json(kind), "x": Json(x), "y": Json(y) }).stringify(),
  )
}

///|
fn clips(id : Int32) -> Array[Json] raise {
  let snapshot = @test_support.model_test_result(state(id))
  @test_support.model_test_items(
    @test_support.model_test_field(
      @test_support.model_test_field(snapshot, "document"),
      "clips",
    ),
  )
}

///|
fn clip_start(id : Int32, clip_id : String) -> Double raise {
  for clip in clips(id) {
    match clip {
      Object(m) if m.get("id") == Some(Json(clip_id)) =>
        return numeric(m, "startTicks")
      _ => ()
    }
  }
  abort("missing clip")
}

///|
test "real v2 UI split body drag linked gap delete undo durable reopen shares one authority" {
  let id = fixture()
  assert_eq(text(id, 0), "/recordings/session/source.webm")
  finish_effects(id)
  ignore(node(id, "play"))
  assert_true(playback(id, value(id, 6), 4000, false))
  assert_true(activate(id, "project-split"))
  assert_eq(clips(id).length(), 4)
  finish_effects(id)
  let clip = node(id, "clip:v2")
  let x = numeric(clip, "x") + numeric(clip, "width") / 2
  let y = numeric(clip, "y") + numeric(clip, "height") / 2
  let target = x + numeric(clip, "width") * 0.25
  let revision = number(id, 0)
  assert_true(pointer(id, "pointerDown", x, y))
  assert_true(pointer(id, "pointerMove", target, y))
  assert_eq(value(id, 4), 1)
  assert_eq(number(id, 0), revision)
  assert_true(pointer(id, "pointerUp", target, y))
  assert_eq(number(id, 0), revision + 1)
  assert_eq(clip_start(id, "v2"), 540000)
  assert_eq(clip_start(id, "a2"), 540000)
  finish_effects(id)
  assert_true(activate(id, "gap:360000:540000"))
  assert_true(
    event(
      id, "{\"type\":\"key\",\"key\":\"Delete\",\"mod\":false,\"shift\":false}",
    ),
  )
  assert_eq(clip_start(id, "v2"), 360000)
  finish_effects(id)
  assert_true(activate(id, "undo"))
  assert_eq(clip_start(id, "v2"), 540000)
  finish_effects(id)
  let draft = text(id, 1)
  dispose(id)
  let reopened = open("/recordings/session/source.webm", fixture_source, draft)
  assert_true(reopened > id)
  assert_eq(value(reopened, 1), 0)
  assert_eq(clip_start(reopened, "a2"), 540000)
  assert_eq(text(reopened, 1), draft)
  dispose(reopened)
}

///|
test "immutable effect plans and serial saved revisions reject stale and foreign acknowledgements" {
  let id = fixture()
  let old_apply = take_effect(id)
  assert_eq(effect_kind(id, old_apply), 1)
  let old_plan = effect_plan(id, old_apply)
  let old_generation = effect_generation(id, old_apply)
  assert_eq(@project.media_plan_value(old_plan, 2), 1)
  let old_save = take_effect(id)
  assert_eq(effect_kind(id, old_save), 2)
  let old_bytes = effect_text(id, old_save)
  assert_true(
    operation(
      id,
      Json::object({
        "type": Json("split"),
        "clipId": Json("v1"),
        "atTicks": Json(360000),
      }),
    ),
  )
  assert_true(
    operation(
      id,
      Json::object({
        "type": Json("move"),
        "clipId": Json("v2"),
        "startTicks": Json(540000),
        "linked": Json(true),
      }),
    ),
  )
  assert_eq(number(id, 0), 2)
  assert_eq(@project.media_plan_value(old_plan, 2), 1)
  assert_eq(effect_text(id, old_save), old_bytes)
  assert_eq(take_effect(id), 0)
  let other = fixture()
  assert_true(!ack(other, old_apply, 0, ""))
  assert_true(ack(id, old_apply, 0, ""))
  assert_eq(@project.media_plan_value(old_plan, 0), -1)
  assert_eq(value(id, 2), 0)
  assert_true(!playback(id, old_generation, 6000, true))
  let next_apply = take_effect(id)
  assert_eq(effect_kind(id, next_apply), 1)
  assert_eq(effect_revision(id, next_apply), 2)
  assert_eq(@project.media_plan_value(effect_plan(id, next_apply), 2), 2)
  assert_eq(@project.media_plan_number(effect_plan(id, next_apply), 0), 1260000)
  assert_true(ack(id, next_apply, 0, ""))
  assert_true(ack(id, old_save, 0, ""))
  assert_eq(number(id, 1), 0)
  assert_eq(value(id, 1), 1)
  assert_true(!ack(id, old_save, 0, ""))
  let save = take_effect(id)
  assert_eq(effect_kind(id, save), 2)
  assert_eq(effect_revision(id, save), 2)
  assert_true(effect_text(id, save) != old_bytes)
  assert_true(ack(id, save, 0, ""))
  assert_eq(value(id, 1), 0)
  dispose(other)
  dispose(id)
}

///|
test "save failure vetoes close and retry keeps edits until media cleanup barrier" {
  let id = fixture()
  let apply = take_effect(id)
  assert_true(ack(id, apply, 0, ""))
  let save = take_effect(id)
  assert_true(request_close(id, false))
  assert_eq(value(id, 0), 2)
  assert_eq(take_effect(id), 0)
  assert_true(ack(id, save, 1, "disk full"))
  assert_eq(value(id, 0), 1)
  assert_eq(value(id, 1), 1)
  assert_eq(text(id, 2), "disk full")
  assert_true(!release(id))
  let document = text(id, 1)
  assert_true(request_close(id, false))
  let retry_save = take_effect(id)
  assert_eq(effect_kind(id, retry_save), 2)
  assert_eq(effect_text(id, retry_save), document)
  assert_true(ack(id, retry_save, 0, ""))
  let close = take_effect(id)
  assert_eq(effect_kind(id, close), 9)
  assert_true(!release(id))
  assert_true(ack(id, close, 0, ""))
  assert_true(!ack(id, apply, 0, ""))
  assert_true(release(id))
}

///|
test "save warning survives transport chooser and gestures until the current revision is durable" {
  let id = fixture()
  finish_effects(id)
  assert_true(operation(id, Json::object({ "type": Json("mute"), "muted": Json(true) })))
  let apply = take_effect(id)
  assert_eq(effect_kind(id, apply), 1)
  assert_true(ack(id, apply, 0, ""))
  let save = take_effect(id)
  assert_eq(effect_kind(id, save), 2)
  finish_effects(id)
  assert_true(activate(id, "export"))
  let destination = take_effect(id)
  assert_eq(effect_kind(id, destination), 6)
  assert_true(ack(id, destination, 0, "/recordings/session/output.mp4"))
  assert_true(ack(id, save, 1, "draft disk full"))
  assert_eq(value(id, 3), 0)
  finish_effects(id)
  assert_true(activate(id, "preview-rate"))
  assert_true(activate(id, "rate-1"))
  let rate = take_effect(id)
  assert_eq(effect_kind(id, rate), 5)
  assert_true(ack(id, rate, 0, ""))
  assert_true(activate(id, "export"))
  let chooser = take_effect(id)
  assert_eq(effect_kind(id, chooser), 6)
  assert_true(ack(id, chooser, 2, ""))
  assert_eq(text(id, 2), "draft disk full")
  assert_true(frame(id, 1040, 700).contains("draft disk full"))
  let clip = node(id, "clip:v1")
  let x = numeric(clip, "x") + numeric(clip, "width") / 2
  let y = numeric(clip, "y") + numeric(clip, "height") / 2
  assert_true(pointer(id, "pointerDown", x, y))
  assert_true(pointer(id, "pointerMove", x + 20, y))
  assert_eq(value(id, 4), 1)
  assert_true(frame(id, 1040, 700).contains("draft disk full"))
  assert_true(event(id, "{\"type\":\"cancel\"}"))
  finish_effects(id)
  assert_true(retry(id))
  let old_save = take_effect(id)
  assert_eq(effect_kind(id, old_save), 2)
  assert_true(operation(id, Json::object({ "type": Json("mute"), "muted": Json(false) })))
  assert_true(ack(id, old_save, 0, ""))
  assert_eq(value(id, 1), 1)
  assert_eq(text(id, 2), "draft disk full")
  finish_effects(id)
  assert_eq(value(id, 1), 0)
  assert_eq(text(id, 2), "")
  assert_true(!frame(id, 1040, 700).contains("draft disk full"))
  dispose(id)
}

///|
test "successful save does not dismiss a distinct media failure with identical wording" {
  let id = fixture()
  finish_effects(id)
  assert_true(operation(id, Json::object({ "type": Json("mute"), "muted": Json(true) })))
  let apply = take_effect(id)
  assert_eq(effect_kind(id, apply), 1)
  assert_true(ack(id, apply, 1, "operation failed"))
  let save = take_effect(id)
  assert_eq(effect_kind(id, save), 2)
  assert_true(ack(id, save, 1, "operation failed"))
  assert_true(retry(id))
  let next_apply = take_effect(id)
  assert_eq(effect_kind(id, next_apply), 1)
  assert_true(ack(id, next_apply, 1, "operation failed"))
  let next_save = take_effect(id)
  assert_eq(effect_kind(id, next_save), 2)
  assert_true(ack(id, next_save, 0, ""))
  assert_eq(value(id, 1), 0)
  assert_eq(value(id, 2), 0)
  assert_eq(text(id, 2), "operation failed")
  assert_true(frame(id, 1040, 700).contains("operation failed"))
  assert_true(retry(id))
  finish_effects(id)
  assert_eq(text(id, 2), "")
  dispose(id)
}

///|
test "export chooser cancellation and export cancellation wait for terminal job not cancel request" {
  let id = fixture()
  finish_effects(id)
  assert_true(activate(id, "export"))
  let chooser = take_effect(id)
  assert_eq(effect_kind(id, chooser), 6)
  assert_true(!request_close(id, true))
  assert_true(!ack(id, chooser, 0, ""))
  assert_true(ack(id, chooser, 2, ""))
  assert_eq(value(id, 3), 0)
  assert_true(activate(id, "export"))
  let chooser = take_effect(id)
  assert_true(ack(id, chooser, 0, "/exports/final.webm"))
  let job = take_effect(id)
  assert_eq(effect_kind(id, job), 7)
  let plan = effect_plan(id, job)
  assert_true(plan > 0)
  assert_true(export_progress(id, job, 0.4))
  assert_eq(number(id, 5), 0.4)
  assert_true(!operation(id, Json::object({ "type": Json("undo") })))
  assert_true(!request_close(id, false))
  assert_true(request_close(id, true))
  let cancel = take_effect(id)
  assert_eq(effect_kind(id, cancel), 8)
  assert_eq(effect_number(id, cancel), job.to_double())
  assert_true(ack(id, cancel, 0, ""))
  assert_eq(take_effect(id), 0)
  assert_eq(value(id, 3), 1)
  assert_true(!release(id))
  assert_eq(@project.media_plan_value(plan, 2), 1)
  assert_true(ack(id, job, 2, ""))
  assert_eq(@project.media_plan_value(plan, 2), -1)
  let close = take_effect(id)
  assert_eq(effect_kind(id, close), 9)
  assert_true(ack(id, close, 0, ""))
  assert_true(!export_progress(id, job, 0.9))
  assert_true(release(id))
}

///|
test "failed media apply preserves durable edit and retries same revision while invalid input is inert" {
  let id = fixture()
  finish_effects(id)
  assert_true(
    operation(
      id,
      Json::object({
        "type": Json("split"),
        "clipId": Json("v1"),
        "atTicks": Json(360000),
      }),
    ),
  )
  let apply = take_effect(id)
  assert_eq(effect_kind(id, apply), 1)
  assert_true(ack(id, apply, 1, "unsupported media"))
  let save = take_effect(id)
  assert_true(ack(id, save, 0, ""))
  assert_eq(value(id, 1), 0)
  assert_eq(value(id, 2), 0)
  assert_eq(clips(id).length(), 4)
  assert_eq(take_effect(id), 0)
  assert_true(retry(id))
  finish_effects(id)
  assert_eq(value(id, 2), 1)
  let snapshot = state(id)
  assert_true(!event(id, "{\"type\":\"snapshot\",\"snapshot\":{}}"))
  assert_true(
    !event(id, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
  )
  assert_true(!playback(id, value(id, 6), 0.0 / 0.0, false))
  assert_eq(state(id), snapshot)
  assert_eq(open("", fixture_source, ""), 0)
  assert_eq(open("/broken.webm", fixture_source, "{}"), 0)
  dispose(id)
}

///|
test "seek coalesces behind in-flight preview and late cancel failure cannot reopen finished export close" {
  let id = fixture()
  finish_effects(id)
  assert_true(activate(id, "forward"))
  let seek = take_effect(id)
  assert_eq(effect_kind(id, seek), 3)
  assert_eq(effect_number(id, seek), 120)
  assert_true(activate(id, "forward"))
  assert_true(activate(id, "forward"))
  assert_eq(take_effect(id), 0)
  assert_true(!playback(id, value(id, 6), 10, false))
  assert_true(ack(id, seek, 0, ""))
  let latest = take_effect(id)
  assert_eq(effect_kind(id, latest), 3)
  assert_eq(effect_number(id, latest), 360)
  assert_true(ack(id, latest, 0, ""))
  assert_true(playback(id, value(id, 6), 360, false))
  assert_true(activate(id, "export"))
  let chooser = take_effect(id)
  assert_true(ack(id, chooser, 0, text(id, 0)))
  assert_eq(value(id, 3), 0)
  assert_eq(take_effect(id), 0)
  assert_true(activate(id, "export"))
  let chooser = take_effect(id)
  assert_true(ack(id, chooser, 0, "/exports/output.webm"))
  let job = take_effect(id)
  assert_eq(effect_kind(id, job), 7)
  assert_true(request_close(id, true))
  let cancel = take_effect(id)
  assert_eq(effect_kind(id, cancel), 8)
  // The export wins the race and is already fully drained. A late cancellation
  // error is not a new editor failure and must not undo the accepted close.
  assert_true(ack(id, job, 0, ""))
  assert_true(ack(id, cancel, 1, "job already finished"))
  assert_eq(value(id, 0), 2)
  let close = take_effect(id)
  assert_eq(effect_kind(id, close), 9)
  assert_true(ack(id, close, 0, ""))
  assert_true(release(id))
}

///|
test "deduplicated old command receipt does not rewind UI and resource barrier invalidates pending plan" {
  let id = fixture()
  finish_effects(id)
  let request = "{\"expectedRevision\":0,\"requestId\":\"agent-split\",\"op\":{\"type\":\"split\",\"clipId\":\"v1\",\"atTicks\":360000}}"
  assert_true(command(id, request))
  assert_true(
    operation(
      id,
      Json::object({
        "type": Json("move"),
        "clipId": Json("v2"),
        "startTicks": Json(540000),
        "linked": Json(true),
      }),
    ),
  )
  let snapshot = state(id)
  assert_true(command(id, request))
  assert_eq(state(id), snapshot)
  let apply = take_effect(id)
  let plan = effect_plan(id, apply)
  assert_true(plan > 0)
  let save = take_effect(id)
  assert_eq(effect_kind(id, save), 2)
  assert_true(ack(id, save, 0, ""))
  assert_true(request_close(id, false))
  let close = take_effect(id)
  assert_eq(effect_kind(id, close), 9)
  assert_eq(@project.media_plan_value(plan, 2), 2)
  assert_true(ack(id, close, 0, ""))
  assert_eq(@project.media_plan_value(plan, 2), -1)
  assert_true(!ack(id, apply, 1, "late callback"))
  assert_true(release(id))
}

///|
test "maximum legal project and source waveform exceed command size but remain valid session inputs" {
  let initial = fixture()
  let draft = snapshot_object(text(initial, 1)).unwrap()
  let clip_values : Array[Json] = []
  for i in 1..<=256 {
    for kind in ["video", "audio"] {
      clip_values.push(
        Json::object({
          "id": Json((if kind == "video" { "v" } else { "a" }) + i.to_string()),
          "kind": Json(kind),
          "sourceStartTicks": Json(0),
          "sourceEndTicks": Json(3000),
          "startTicks": Json((i - 1) * 6000),
          "durationTicks": Json(3000),
          "linkGroup": Json("g\{i}"),
        }),
      )
    }
  }
  draft["clips"] = Json::array(clip_values)
  draft["nextId"] = Json(257)
  let draft_json = Json::object(draft).stringify()
  assert_true(draft_json.length() > 65536)
  dispose(initial)
  let id = open("/recordings/max/source.webm", fixture_source, draft_json)
  assert_true(id > 0)
  assert_eq(value(id, 1), 0)
  finish_effects(id)
  assert_true(state(id).length() > 131072)
  assert_true(activate(id, "project-audio-toggle"))
  let wave = Json::object({
    "type": Json("waveform"),
    "durationMs": Json(12000),
    "peaks": Json::array(Array::make(16384, Json(0.123456789))),
  }).stringify()
  assert_true(wave.length() > 65536)
  assert_true(waveform(id, wave))
  assert_true(frame(id, 1040, 700).length() > 0)
  assert_true(
    operation(id, Json::object({ "type": Json("mute"), "muted": Json(true) })),
  )
  finish_effects(id)
  assert_eq(value(id, 1), 0)
  assert_eq(number(id, 0), 1)
  dispose(id)
}

///|
test "coalesced rapid edits retire unclaimed plans and cleanup barrier releases every owned plan" {
  let id = fixture()
  let applying = take_effect(id)
  assert_eq(effect_kind(id, applying), 1)
  for i in 0..<100 {
    assert_true(
      operation(
        id,
        Json::object({ "type": Json("mute"), "muted": Json(i % 2 == 0) }),
      ),
    )
  }
  // Exactly two plans remain: the in-flight old apply and the latest queued
  // apply. Replacing a queued effect must close every superseded plan.
  let spare : Array[Int32] = []
  for _ in 0..<64 {
    let plan = @project.media_plan_open(editors[id].project)
    if plan == 0 {
      break
    }
    spare.push(plan)
  }
  assert_eq(spare.length(), 62)
  for plan in spare {
    @project.media_plan_close(plan)
  }
  let save = take_effect(id)
  assert_eq(effect_kind(id, save), 2)
  assert_true(ack(id, save, 0, ""))
  assert_true(request_close(id, false))
  let close = take_effect(id)
  assert_eq(effect_kind(id, close), 9)
  assert_true(ack(id, close, 0, ""))
  assert_true(!ack(id, applying, 0, ""))
  let released : Array[Int32] = []
  for _ in 0..<64 {
    let plan = @project.media_plan_open(editors[id].project)
    assert_true(plan > 0)
    released.push(plan)
  }
  for plan in released {
    @project.media_plan_close(plan)
  }
  assert_true(release(id))
}

///|
test "old playback clocks cannot replace queued or in-flight play pause intent" {
  let id = fixture()
  finish_effects(id)
  assert_true(activate(id, "play"))
  assert_true(!playback(id, value(id, 6), 0, false))
  let play = take_effect(id)
  assert_eq(effect_kind(id, play), 4)
  assert_eq(effect_number(id, play), 1)
  assert_eq(value(id, 5), 1)
  assert_true(!playback(id, value(id, 6), 0, false))
  assert_true(activate(id, "play"))
  assert_true(ack(id, play, 0, ""))
  assert_true(!playback(id, value(id, 6), 10, true))
  let pause = take_effect(id)
  assert_eq(effect_kind(id, pause), 4)
  assert_eq(effect_number(id, pause), 0)
  assert_true(ack(id, pause, 0, ""))
  assert_true(playback(id, value(id, 6), 10, false))
  dispose(id)
}

///|
fn start_ruler_drag(id : Int32) -> Int32 raise {
  let ph = node(id, "playhead")
  let x = numeric(ph, "x") + numeric(ph, "width") * 0.5
  let y = numeric(ph, "y") + 4
  assert_true(pointer(id, "pointerDown", x, y))
  assert_true(pointer(id, "pointerMove", x + 80, y))
  assert_eq(value(id, 4), 1)
  let seek = take_effect(id)
  assert_eq(effect_kind(id, seek), 3)
  assert_true(effect_number(id, seek) > 0)
  seek
}

///|
test "save failure preserves cancelled ruler restore while close and invalid media suppress it" {
  let id = fixture()
  let apply = take_effect(id)
  assert_true(ack(id, apply, 0, ""))
  let save = take_effect(id)
  let seek = start_ruler_drag(id)
  assert_true(ack(id, save, 1, "disk full"))
  assert_eq(value(id, 4), 0)
  assert_eq(numeric(node(id, "playhead"), "value"), 0)
  assert_true(ack(id, seek, 0, ""))
  let restore = take_effect(id)
  assert_eq(effect_kind(id, restore), 3)
  assert_eq(effect_number(id, restore), 0)
  assert_eq(number(id, 3), 0)
  assert_true(ack(id, restore, 0, ""))
  // Cancel on close cannot enqueue a seek on a backend being torn down.
  let closing_seek = start_ruler_drag(id)
  assert_true(request_close(id, false))
  assert_true(ack(id, closing_seek, 0, ""))
  let retry_save = take_effect(id)
  assert_eq(effect_kind(id, retry_save), 2)
  assert_true(ack(id, retry_save, 0, ""))
  let close = take_effect(id)
  assert_eq(effect_kind(id, close), 9)
  assert_true(ack(id, close, 0, ""))
  assert_true(release(id))

  let invalid = fixture()
  finish_effects(invalid)
  let seeking = start_ruler_drag(invalid)
  // The editor accepts an authoritative agent edit during the gesture; the
  // resulting snapshot invalidates the old plan, not restores its saved seek.
  assert_true(
    operation(
      invalid,
      Json::object({ "type": Json("mute"), "muted": Json(true) }),
    ),
  )
  assert_true(ack(invalid, seeking, 0, ""))
  let failed_apply = take_effect(invalid)
  assert_eq(effect_kind(invalid, failed_apply), 1)
  assert_true(ack(invalid, failed_apply, 1, "preview unavailable"))
  let saved = take_effect(invalid)
  assert_eq(effect_kind(invalid, saved), 2)
  assert_true(ack(invalid, saved, 0, ""))
  assert_eq(take_effect(invalid), 0)
  dispose(invalid)
}
