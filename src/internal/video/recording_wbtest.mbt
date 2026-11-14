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
