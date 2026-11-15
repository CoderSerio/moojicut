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
    @test_support.expect_json(
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
    @test_support.expect_error(recording_transition(state, event), "invalid_transition")
  }
}

///|
test "selection countdown and early cancellation never claim active recording" {
  for transition in [
    ("requesting", "selected", "countdown"),
    ("countdown", "countdown_finished", "starting"),
    ("starting", "capture_started", "recording"),
    ("requesting", "cancel", "idle"),
    ("countdown", "cancel", "idle"),
    ("starting", "stop", "stopping"),
    ("countdown", "fail", "error"),
    ("starting", "fail", "error"),
  ] {
    let (state, event, expected) = transition
    @test_support.expect_json(recording_transition(state, event), "{\"ok\":true,\"state\":\"\{expected}\"}")
  }
  for transition in [
    ("countdown", "capture_started"), ("countdown", "start"),
    ("starting", "selected"), ("stopping", "capture_started"),
    ("idle", "countdown_finished"), ("ready", "complete"),
  ] {
    let (state, event) = transition
    @test_support.expect_error(recording_transition(state, event), "invalid_transition")
  }
}

///|
test "recording parameters preserve aspect and even encoder bounds" {
  @test_support.expect_json(recording_plan("{\"width\":5120,\"height\":2880,\"systemAudio\":true}"),
    "{\"ok\":true,\"width\":3840,\"height\":2160,\"framesPerSecond\":30,\"systemAudio\":true,\"microphone\":false,\"countdownSeconds\":3}")
  @test_support.expect_json(recording_plan("{\"width\":901,\"height\":1601,\"systemAudio\":false}"),
    "{\"ok\":true,\"width\":900,\"height\":1600,\"framesPerSecond\":30,\"systemAudio\":false,\"microphone\":false,\"countdownSeconds\":3}")
  @test_support.expect_json(recording_plan("{\"width\":2880,\"height\":5120,\"systemAudio\":true}"),
    "{\"ok\":true,\"width\":2160,\"height\":3840,\"framesPerSecond\":30,\"systemAudio\":true,\"microphone\":false,\"countdownSeconds\":3}")
  for input in ["{}", "{\"width\":1,\"height\":100,\"systemAudio\":true}",
    "{\"width\":50000,\"height\":100,\"systemAudio\":true}",
    "{\"width\":300.5,\"height\":100,\"systemAudio\":true}",
    "{\"width\":300,\"height\":100,\"systemAudio\":1}"] {
    @test_support.expect_error(recording_plan(input), "invalid_input")
  }
}

///|
test "recording controls match lifecycle including finalization" {
  for state in ["requesting", "countdown", "starting", "paused"] {
    @test_support.expect_json(recording_status(state), "{\"ok\":true,\"captureInProgress\":true,\"canStop\":true,\"recording\":false}")
  }
  @test_support.expect_json(recording_status("recording"), "{\"ok\":true,\"captureInProgress\":true,\"canStop\":true,\"recording\":true}")
  @test_support.expect_json(recording_status("stopping"), "{\"ok\":true,\"captureInProgress\":true,\"canStop\":false,\"recording\":false}")
  for state in ["idle", "ready", "error"] {
    @test_support.expect_json(recording_status(state), "{\"ok\":true,\"captureInProgress\":false,\"canStop\":false,\"recording\":false}")
  }
  @test_support.expect_error(recording_status("unknown"), "invalid_state")
}

///|
test "platform recording policies preserve Windows limits without changing macOS defaults" {
  @test_support.expect_json(recording_plan("{\"platform\":\"windows\",\"width\":5120,\"height\":2880,\"systemAudio\":true}"),
    "{\"ok\":true,\"width\":1920,\"height\":1080,\"framesPerSecond\":15,\"systemAudio\":false,\"microphone\":false,\"countdownSeconds\":0}")
  @test_support.expect_json(recording_plan("{\"platform\":\"windows\",\"width\":1080,\"height\":1920,\"systemAudio\":false}"),
    "{\"ok\":true,\"width\":606,\"height\":1080,\"framesPerSecond\":15,\"systemAudio\":false,\"microphone\":false,\"countdownSeconds\":0}")
  @test_support.expect_json(recording_plan("{\"platform\":\"macOS\",\"width\":5120,\"height\":2880,\"systemAudio\":true}"),
    recording_plan("{\"width\":5120,\"height\":2880,\"systemAudio\":true}"))
  for platform in ["\"linux\"", "\"Windows\"", "1", "null"] {
    @test_support.expect_error(recording_plan("{\"platform\":\{platform},\"width\":320,\"height\":240,\"systemAudio\":false}"), "invalid_input")
  }
}

///|
test "native recording policy rejects malformed dimensions and option values" {
  for input in [
    (-1, 320, 240, 0), (2, 320, 240, 0), (1, 0, 240, 0),
    (1, 320, -1, 0), (1, 1, 240, 0), (1, 320, 32769, 0),
    (0, 32769, 240, 0), (0, 320, 240, 2), (1, 320, 240, -1),
  ] {
    let (platform, width, height, audio) = input
    let values = native_recording_plan(platform, width, height, audio)
    assert_eq(values.length(), 6)
    for value in values { assert_eq(value, 0) }
  }
  for platform in [0, 1] {
    let values = native_recording_plan(platform, 321, 241, 1)
    assert_eq(values[0], 320)
    assert_eq(values[1], 240)
    assert_eq(values[2], if platform == 1 { 15 } else { 30 })
    assert_eq(values[3], if platform == 1 { 0 } else { 1 })
    assert_eq(values[4], 0)
    assert_eq(values[5], if platform == 1 { 0 } else { 3 })
  }
}

///|
test "recording bounds remain even capped and proportional across portrait and extreme aspect ratios" {
  let edges = [2, 3, 319, 320, 1080, 1081, 1920, 1921, 2880, 3840, 5120, 32768]
  for platform in [0, 1] {
    for width in edges {
      for height in edges {
        let plan = native_recording_plan(platform, width, height, 0)
        let w = plan[0]
        let h = plan[1]
        assert_true(w >= 2 && h >= 2 && w % 2 == 0 && h % 2 == 0)
        assert_true(w <= width && h <= height)
        assert_true(w <= (if platform == 1 { 1920 } else { 3840 }))
        assert_true(h <= (if platform == 1 { 1080 } else { 3840 }))
        // Each encoder edge may move by less than two pixels for even alignment.
        let aspect_error = w * height - h * width
        assert_true(aspect_error.abs() < 2 * (width + height))
      }
    }
  }
}
