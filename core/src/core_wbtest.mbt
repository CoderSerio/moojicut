///|
fn expect_json(actual : String, expected : String) -> Unit raise {
  assert_true(@json.parse(actual) == @json.parse(expected))
}

///|
fn expect_error(actual : String, expected_code : String) -> Unit raise {
  match @json.parse(actual) {
    Object({ "ok": False, "error": Object({ "code": String(code), .. }), .. }) =>
      assert_eq(code, expected_code)
    _ => abort("Expected a structured error: " + actual)
  }
}

///|
fn number_result(actual : String, key : String) -> Double raise {
  match @json.parse(actual) {
    Object(fields) =>
      match fields.get(key) {
        Some(Number(value, ..)) => value
        _ => abort("Missing numeric result: " + key)
      }
    _ => abort("Expected an object result")
  }
}

///|
test "trim exports an exclusive source interval starting at output zero" {
  expect_json(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":1000,"endMs":9000}}
      ),
    ),
    (
      #|{"ok":true,"segments":[{"sourceStartMs":1000,"sourceEndMs":9000,"outputStartMs":0,"outputEndMs":8000}],"outputDurationMs":8000}
    ),
  )
}

///|
test "removing the middle joins both retained intervals without a timeline gap" {
  expect_json(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":1000,"endMs":9000},"cut":{"startMs":3000,"endMs":5000}}
      ),
    ),
    (
      #|{"ok":true,"segments":[{"sourceStartMs":1000,"sourceEndMs":3000,"outputStartMs":0,"outputEndMs":2000},{"sourceStartMs":5000,"sourceEndMs":9000,"outputStartMs":2000,"outputEndMs":6000}],"outputDurationMs":6000}
    ),
  )
}

///|
test "a cut is intersected with the trim instead of extending its bounds" {
  expect_json(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":2000,"endMs":8000},"cut":{"startMs":0,"endMs":3000}}
      ),
    ),
    (
      #|{"ok":true,"segments":[{"sourceStartMs":3000,"sourceEndMs":8000,"outputStartMs":0,"outputEndMs":5000}],"outputDurationMs":5000}
    ),
  )
  assert_eq(
    number_result(
      edit_plan(
        (
          #|{"durationMs":10000,"trim":{"startMs":2000,"endMs":8000},"cut":{"startMs":8000,"endMs":9000}}
        ),
      ),
      "outputDurationMs",
    ),
    6000.0,
  )
}

///|
test "invalid and empty edits never produce an exportable timeline" {
  expect_error(
    edit_plan(
      (
        #|{"durationMs":1000,"trim":{"startMs":0,"endMs":1000},"cut":{"startMs":0,"endMs":1000}}
      ),
    ),
    "empty_output",
  )
  expect_error(
    edit_plan(
      (
        #|{"durationMs":1000,"trim":{"startMs":900,"endMs":100}}
      ),
    ),
    "invalid_range",
  )
  expect_error(
    edit_plan(
      (
        #|{"durationMs":1000,"trim":{"startMs":0,"endMs":1001}}
      ),
    ),
    "invalid_input",
  )
}

///|
test "fractional and enormous numbers are rejected before numeric conversion" {
  for value in ["1.5", "1e100", "-1", "9007199254740992", "null", "\"1000\""] {
    expect_error(
      edit_plan(
        "{\"durationMs\":\{value},\"trim\":{\"startMs\":0,\"endMs\":1}}",
      ),
      "invalid_input",
    )
  }
  expect_error(edit_plan("{\"durationMs\":NaN}"), "invalid_json")
  expect_error(edit_plan("{\"durationMs\":Infinity}"), "invalid_json")
  // Overflowed JSON exponents must also return an error, regardless of whether
  // the parser rejects them or produces a non-finite number.
  let overflowed = @json.parse(edit_plan("{\"durationMs\":1e999}"))
  assert_true(overflowed is Object({ "ok": False, .. }))
}

///|
test "requests reject malformed JSON duplicate keys and wrong root types" {
  expect_error(edit_plan("{"), "invalid_json")
  expect_error(edit_plan("[]"), "invalid_input")
  expect_error(
    edit_plan("{\"durationMs\":1000,\"durationMs\":2000}"),
    "invalid_json",
  )
  expect_error(edit_plan("{}"), "invalid_input")
}

///|
test "crop intersects negative and overflowing selections with source pixels" {
  expect_json(
    crop_rect(
      (
        #|{"sourceWidth":1920,"sourceHeight":1080,"x":-10,"y":1060,"width":100,"height":50}
      ),
    ),
    (
      #|{"ok":true,"rect":{"x":0,"y":1060,"width":90,"height":20}}
    ),
  )
  expect_json(
    crop_rect(
      (
        #|{"sourceWidth":1920,"sourceHeight":1080,"x":0,"y":0,"width":1920,"height":1080}
      ),
    ),
    (
      #|{"ok":true,"rect":{"x":0,"y":0,"width":1920,"height":1080}}
    ),
  )
}

///|
test "empty fractional and oversized crops return structured errors" {
  expect_error(
    crop_rect(
      (
        #|{"sourceWidth":100,"sourceHeight":100,"x":100,"y":0,"width":10,"height":10}
      ),
    ),
    "empty_crop",
  )
  for width in ["0", "-1", "0.5", "1e100"] {
    expect_error(
      crop_rect(
        "{\"sourceWidth\":100,\"sourceHeight\":100,\"x\":0,\"y\":0,\"width\":\{width},\"height\":10}",
      ),
      "invalid_input",
    )
  }
}

///|
test "recording lifecycle supports pause resume finalize and retake" {
  let transitions = [
    ("idle", "start", "requesting"),
    ("requesting", "capture_started", "recording"),
    ("recording", "pause", "paused"),
    ("paused", "resume", "recording"),
    ("paused", "stop", "stopping"),
    ("recording", "stop", "stopping"),
    ("stopping", "complete", "ready"),
    ("ready", "start", "requesting"),
    ("requesting", "fail", "error"),
    ("error", "start", "requesting"),
    ("ready", "reset", "idle"),
  ]
  for transition in transitions {
    let (state, event, next) = transition
    expect_json(
      recording_transition(state, event),
      "{\"ok\":true,\"state\":\"\{next}\"}",
    )
  }
}

///|
test "late and invalid recording events cannot skip required states" {
  for
    transition in [
      ("idle", "complete"),
      ("requesting", "stop"),
      ("ready", "capture_started"),
      ("recording", "start"),
      ("recording", "reset"),
      ("unknown", "start"),
      ("idle", "unknown"),
    ] {
    let (state, event) = transition
    expect_error(recording_transition(state, event), "invalid_transition")
  }
}

///|
test "share budget lowers bitrate and reserves audio plus mux overhead" {
  let profile = export_profile(
    (
      #|{"durationMs":120000,"width":1920,"height":1080,"preset":"share","hasAudio":true}
    ),
  )
  assert_eq(number_result(profile, "maxWidth"), 1280.0)
  assert_eq(number_result(profile, "audioBitrateKbps"), 96.0)
  assert_true(number_result(profile, "videoBitrateKbps") >= 250.0)
  assert_true(number_result(profile, "estimatedBytes") <= 26214400.0)
  assert_true(@json.parse(profile) is Object({ "fitsTarget": True, .. }))
}

///|
test "impossible file budget retains a minimum bitrate and reports failure to fit" {
  let profile = export_profile(
    (
      #|{"durationMs":60000,"width":1920,"height":1080,"preset":"share","hasAudio":true,"targetBytes":1024}
    ),
  )
  assert_eq(number_result(profile, "videoBitrateKbps"), 250.0)
  assert_eq(number_result(profile, "audioBitrateKbps"), 96.0)
  assert_true(number_result(profile, "estimatedBytes") > 1024.0)
  assert_true(@json.parse(profile) is Object({ "fitsTarget": False, .. }))
}

///|
test "quality prioritizes pixels and a silent video reserves no audio budget" {
  let profile = export_profile(
    (
      #|{"durationMs":60000,"width":3840,"height":2160,"preset":"quality","hasAudio":false,"targetBytes":1024}
    ),
  )
  assert_eq(number_result(profile, "maxWidth"), 1920.0)
  assert_eq(number_result(profile, "audioBitrateKbps"), 0.0)
  assert_eq(number_result(profile, "videoBitrateKbps"), 6221.0)
  assert_true(@json.parse(profile) is Object({ "fitsTarget": False, .. }))
}

///|
test "encoder requests require bounded integer dimensions and a known preset" {
  expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1e100,"height":1080,"preset":"share","hasAudio":false}
      ),
    ),
    "invalid_input",
  )
  expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1920,"height":1080,"preset":"share","hasAudio":false,"targetBytes":0}
      ),
    ),
    "invalid_input",
  )
  expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1920,"height":1080,"preset":"fast","hasAudio":false}
      ),
    ),
    "invalid_input",
  )
  expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1920,"height":1080,"preset":"share","hasAudio":"false"}
      ),
    ),
    "invalid_input",
  )
}
