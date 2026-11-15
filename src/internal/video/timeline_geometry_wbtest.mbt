///|
test "timeline pointer mapping clamps out of track without losing submillisecond precision" {
  for time in [0.0, 1.0, 1234.5, 9999.75, 10000.0] {
    let x = timeline_x_for_time(time, 10000, -40, 500)
    assert_true(
      (timeline_time_for_x(x, 10000, -40, 500) - time).abs() < 0.000001,
    )
  }
  assert_eq(timeline_time_for_x(-100, 10000, -40, 500), 0)
  assert_eq(timeline_time_for_x(999, 10000, -40, 500), 10000)
  assert_eq(timeline_x_for_time(-100, 10000, -40, 500), -40)
  assert_eq(timeline_x_for_time(20000, 10000, -40, 500), 460)
  assert_eq(timeline_time_for_x(0.125, 1, 0, 0.25), 0.5)
  assert_eq(timeline_x_for_time(0.5, 1, 0, 0.25), 0.125)
}

///|
test "timeline rejects nonfinite collapsed and overflowing tracks" {
  for invalid in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
    assert_true(!timeline_finite(timeline_x_for_time(invalid, 1000, 0, 100)))
    assert_true(!timeline_finite(timeline_time_for_x(invalid, 1000, 0, 100)))
    assert_true(!timeline_finite(timeline_x_for_time(100, invalid, 0, 100)))
    assert_true(!timeline_finite(timeline_time_for_x(100, 1000, invalid, 100)))
    assert_true(!timeline_finite(timeline_time_for_x(100, 1000, 0, invalid)))
  }
  assert_true(!timeline_finite(timeline_time_for_x(0, 0, 0, 100)))
  assert_true(!timeline_finite(timeline_x_for_time(100, 1000, 0, 0)))
  assert_true(!timeline_finite(timeline_time_for_x(0, 1000, 0, -1)))
  assert_true(
    !timeline_finite(timeline_x_for_time(100, 1000, 1.0e308, 1.0e308)),
  )
  assert_true(!timeline_finite(timeline_x_for_time(100, 1000, 1.0e308, 1)))
}

///|
test "ruler ticks avoid labels colliding at short and long durations" {
  assert_eq(timeline_tick_step(1, 800, 80), 1)
  assert_eq(timeline_tick_step(10000, 800, 80), 1000)
  assert_eq(timeline_tick_step(11000, 800, 80), 2000)
  assert_eq(timeline_tick_step(25000, 800, 80), 5000)
  assert_eq(timeline_tick_step(60000, 800, 80), 10000)
  assert_eq(timeline_tick_step(1, 0.25, 80), 500)
  for duration in [1.0, 800.0, 10000.0, 3600000.0, 604800000.0] {
    let step = timeline_tick_step(duration, 936, 80)
    assert_true(step >= 1 && step / duration * 936 >= 80)
  }
  assert_true(!timeline_finite(timeline_tick_step(1000, 0, 80)))
  assert_true(!timeline_finite(timeline_tick_step(1000, 800, 0)))
  assert_true(!timeline_finite(timeline_tick_step(1.0 / 0.0, 800, 80)))
}

///|
test "trim handles preserve the opposite edge minimum span and whole milliseconds" {
  assert_eq(timeline_trim_boundary(0, 9999, 1000, 9000, 10000, 100), 8900)
  assert_eq(timeline_trim_boundary(1, 0, 1000, 9000, 10000, 100), 1100)
  assert_eq(timeline_trim_boundary(0, -1.0e100, 1000, 9000, 10000, 100), 0)
  assert_eq(timeline_trim_boundary(1, 1.0e100, 1000, 9000, 10000, 100), 10000)
  assert_eq(timeline_trim_boundary(0, 1234.5, 1000, 9000, 10000, 1), 1235)
  assert_eq(timeline_trim_boundary(1, 0, 1000, 9000, 10000, 100.1), 1101)
  // A whole short clip remains legal, including the minimum reducer duration.
  assert_eq(timeline_trim_boundary(0, 1, 0, 1, 1, 100), 0)
  assert_eq(timeline_trim_boundary(1, 0, 0, 1, 1, 100), 1)
  assert_eq(timeline_trim_boundary(0, 25, 0, 40, 40, 100), 0)
  assert_eq(timeline_trim_boundary(1, 25, 0, 40, 40, 100), 40)
}

///|
test "invalid trim state cannot silently become a different selection" {
  assert_true(
    !timeline_finite(timeline_trim_boundary(2, 500, 0, 1000, 1000, 1)),
  )
  assert_true(
    !timeline_finite(timeline_trim_boundary(0, 500, 900, 100, 1000, 1)),
  )
  assert_true(
    !timeline_finite(timeline_trim_boundary(0, 500, -1, 1000, 1000, 1)),
  )
  assert_true(
    !timeline_finite(timeline_trim_boundary(1, 500, 0, 1001, 1000, 1)),
  )
  assert_true(
    !timeline_finite(timeline_trim_boundary(0, 500, 0.5, 1000, 1000, 1)),
  )
  assert_true(
    !timeline_finite(timeline_trim_boundary(0, 500, 0, 1000, 1000, 0)),
  )
  assert_true(!timeline_finite(timeline_trim_boundary(0, 10, 0, 20, 1000, 100)))
  assert_true(
    !timeline_finite(timeline_trim_boundary(1, 990, 980, 1000, 1000, 100)),
  )
  for invalid in [0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
    assert_true(
      !timeline_finite(timeline_trim_boundary(0, invalid, 0, 1000, 1000, 1)),
    )
    assert_true(
      !timeline_finite(timeline_trim_boundary(0, 500, 0, 1000, 1000, invalid)),
    )
    assert_true(
      !timeline_finite(timeline_trim_boundary(0, 500, 0, 1000, invalid, 1)),
    )
  }
}

///|
test "edited playhead uses current source segments including joins undo and endpoint" {
  let state = @test_support.model_test_result(
    video_open(video_test_source(), ""),
  )
  let id = @test_support.number_result(state.stringify(), "session").to_int()
  ignore(
    video_test_command(
      id, "{\"type\":\"trim\",\"trim\":{\"startMs\":1000,\"endMs\":9000}}",
    ),
  )
  ignore(
    video_test_command(
      id, "{\"type\":\"cut\",\"cut\":{\"startMs\":2000,\"endMs\":4000}}",
    ),
  )
  ignore(
    video_test_command(
      id, "{\"type\":\"cut\",\"cut\":{\"startMs\":3500,\"endMs\":5000}}",
    ),
  )
  let before = video_snapshot(id)
  for
    (output, source) in [
      (0.0, 1000.0),
      (999.5, 1999.5),
      (1000.0, 5000.0),
      (4999.25, 8999.25),
    ] {
    assert_eq(video_source_time(id, output), source)
    assert_eq(
      @test_support.number_result(video_seek(id, source), "outputMs"),
      output,
    )
  }
  assert_eq(video_source_time(id, 5000), 8999)
  for invalid in [-1.0, 5001.0, 0.0 / 0.0, 1.0 / 0.0] {
    assert_eq(video_source_time(id, invalid), -1)
  }
  @test_support.expect_json(video_snapshot(id), before)
  ignore(video_test_command(id, "{\"type\":\"undo\"}"))
  assert_eq(video_source_time(id, 1000), 4000)
  ignore(video_test_command(id, "{\"type\":\"undo\"}"))
  assert_eq(video_source_time(id, 1000), 2000)
  ignore(video_test_command(id, "{\"type\":\"redo\"}"))
  assert_eq(video_source_time(id, 1000), 4000)
  video_dispose(id)
  assert_eq(video_source_time(id, 0), -1)
}

///|
test "output end stays in last kept source interval even with deleted source tail" {
  let state = @test_support.model_test_result(
    video_open(video_test_source(), ""),
  )
  let id = @test_support.number_result(state.stringify(), "session").to_int()
  ignore(
    video_test_command(
      id, "{\"type\":\"cut\",\"cut\":{\"startMs\":0,\"endMs\":2000}}",
    ),
  )
  ignore(
    video_test_command(
      id, "{\"type\":\"cut\",\"cut\":{\"startMs\":8000,\"endMs\":10000}}",
    ),
  )
  assert_eq(video_source_time(id, 0), 2000)
  assert_eq(video_source_time(id, 6000), 7999)
  video_dispose(id)
  let tiny = @test_support.model_test_result(
    video_open(
      "{\"durationMs\":1,\"width\":2,\"height\":2,\"hasAudio\":false}", "",
    ),
  )
  let tiny_id = @test_support.number_result(tiny.stringify(), "session").to_int()
  assert_eq(video_source_time(tiny_id, 0), 0)
  assert_eq(video_source_time(tiny_id, 1), 0)
  video_dispose(tiny_id)
}
