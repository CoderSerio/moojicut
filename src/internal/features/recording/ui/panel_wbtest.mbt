///|
test "countdown panel adapts and visible button shares exact hit boundaries" {
  let id = @recording.recording_flow_open()
  let _ = @recording.recording_flow_event(id, 1, 0)
  let _ = @recording.recording_flow_event(id, 2, 100)
  assert_eq(recording_ui_text(id), "3")
  for (width, height) in [(640.0, 480.0), (96.0, 96.0), (1920.0, 1080.0)] {
    let f = recording_ui_frame(id, width, height)
    assert_true(
      f[0] >= 0 && f[1] >= 0 && f[0] + f[2] <= width && f[1] + f[3] <= height,
    )
    assert_true(f[6] > 0 && f[7] > 0)
    assert_true(f[8] >= f[0] && f[8] + f[10] <= f[0] + f[2])
    assert_true(f[9] >= f[1] && f[9] + f[11] <= f[1] + f[3])
    assert_eq(recording_ui_hit(id, f[8], f[9], width, height), 8)
    assert_eq(recording_ui_hit(id, f[8] + f[10], f[9], width, height), 0)
    assert_eq(recording_ui_hit(id, f[8], f[9] + f[11], width, height), 0)
    assert_eq(recording_ui_hit(id, 0.0 / 0.0, f[9], width, height), 0)
  }
  let _ = @recording.recording_flow_event(id, 8, 200)
  assert_eq(recording_ui_frame(id, 640, 480)[13], 0)
  let _ = @recording.recording_flow_event(id, 6, 200)
  assert_eq(recording_ui_text(id), "")
  assert_eq(recording_ui_frame(id, 640, 480)[2], 0)
  assert_eq(@recording.recording_flow_close(id), 1)
}

///|
test "timer and stop action share the live recording clock" {
  let id = @recording.recording_flow_open()
  let _ = @recording.recording_flow_event(id, 1, 0)
  let _ = @recording.recording_flow_event(id, 2, 0)
  let _ = @recording.recording_flow_event(id, 3, 3000)
  assert_eq(recording_ui_text(id), "…")
  let _ = @recording.recording_flow_event(id, 4, 3100)
  let _ = @recording.recording_flow_event(id, 3, 68100)
  assert_eq(recording_ui_text(id), "01:05")
  let f = recording_ui_frame(id, 240, 160)
  assert_eq(recording_ui_hit(id, f[8] + 1, f[9] + 1, 240, 160), 5)
  let _ = @recording.recording_flow_event(id, 3, 3664100)
  assert_eq(recording_ui_text(id), "01:01:01")
  assert_true(recording_ui_frame(id, 96, 96)[12] <= 11)
  let _ = @recording.recording_flow_event(id, 5, 3664100)
  assert_eq(recording_ui_text(id), "…")
  assert_eq(recording_ui_hit(id, f[8] + 1, f[9] + 1, 240, 160), 0)
  let _ = @recording.recording_flow_event(id, 6, 3664200)
  assert_eq(@recording.recording_flow_close(id), 1)
}
