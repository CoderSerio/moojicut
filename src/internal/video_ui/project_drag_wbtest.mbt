///|
fn split_drag_fixture() -> (Int32, Int32) raise {
  let (ui, core) = project_fixture()
  project_clock(ui, 4000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  (ui, core)
}

///|
fn drag_clip(
  ui : Int32,
  id : String,
  delta_ms : Double,
) -> (Double, Double, Double) raise {
  let s = sessions[ui]
  let c = project_clip(s, id).unwrap()
  let r = project_clip_rect(s, c)
  let x = r.x + r.width / 2
  let y = r.y + r.height / 2
  ignore(point_event(ui, "pointerDown", x, y))
  let target = x + delta_ms / s.viewport_span * project_track(s, c.kind).width
  assert_eq(
    command_effects(point_event(ui, "pointerMove", target, y)).length(),
    0,
  )
  (x, target, y)
}

///|
test "clip body drag previews linked AV then commits one absolute move with selectable gap" {
  let (ui, core) = split_drag_fixture()
  let s = sessions[ui]
  let original = @project_core.snapshot(core)
  let (_, x, y) = drag_clip(ui, "v2", 2000)
  assert_eq(@project_core.snapshot(core), original)
  assert_true(s.clip_drag_active && s.clip_move_valid)
  assert_eq(s.clip_move_start, 540000)
  assert_eq(project_display_start(s, project_clip(s, "a2").unwrap()), 540000)
  let response = point_event(ui, "pointerUp", x, y)
  let op = project_op(response)
  assert_eq(string(op, "type"), "move")
  assert_eq(number(op, "startTicks"), 540000)
  assert_true(boolean(op, "linked") && !op.contains("beforeClipId"))
  ignore(project_apply(ui, core, response))
  assert_eq(s.snapshot.duration, 14000)
  assert_eq(project_clip(s, "v1").unwrap().start, 0)
  assert_eq(project_clip(s, "v2").unwrap().start, 540000)
  assert_eq(project_clip(s, "a2").unwrap().start, 540000)
  assert_eq(command_effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  let gap = node(ui, "gap:360000:540000", 1040, 700)
  let gx = number(gap, "x") + number(gap, "width") / 2
  let gy = number(gap, "y") + 15
  ignore(point_event(ui, "pointerDown", gx, gy))
  ignore(point_event(ui, "pointerUp", gx, gy))
  ignore(project_apply(ui, core, key_event(ui, "Delete")))
  assert_eq(project_clip(s, "v2").unwrap().start, 360000)
  assert_eq(project_clip(s, "a2").unwrap().start, 360000)
  assert_true(project_gaps(s).is_empty())
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(project_gaps(s).length(), 1)
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(project_clip(s, "v2").unwrap().start, 360000)
  assert_eq(s.snapshot.duration, 12000)
  close(ui)
  @project_core.close(core)
}

///|
test "body drag rejects collision and snaps only near legal edges in viewport pixels" {
  let (ui, core) = split_drag_fixture()
  let s = sessions[ui]
  let before = @project_core.snapshot(core)
  let (_, x, y) = drag_clip(ui, "v2", -1000)
  assert_true(!s.clip_move_valid)
  assert_eq(command_effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  assert_eq(@project_core.snapshot(core), before)
  // 4px movement exceeds the click threshold but stays within 6px edge snap.
  let pixels = s.viewport_span / project_track(s, "video").width
  let (_, x, y) = drag_clip(ui, "v2", 4 * pixels)
  assert_eq(s.clip_move_start, 360000)
  assert_eq(command_effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  let (_, x, y) = drag_clip(ui, "v2", 10 * pixels)
  assert_true(s.clip_move_start > 360000)
  let candidate = s.clip_move_start
  assert_eq(
    number(project_op(point_event(ui, "pointerUp", x, y)), "startTicks"),
    candidate,
  )
  ignore(activate_event(ui, "project-zoom-in"))
  let pixels = s.viewport_span / project_track(s, "video").width
  let (_, x, y) = drag_clip(ui, "v2", 4 * pixels)
  assert_eq(s.clip_move_start, 360000)
  assert_eq(command_effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  close(ui)
  @project_core.close(core)
}

///|
test "drag beyond current end extends output while resize escape and media loss revoke candidates" {
  let (ui, core) = split_drag_fixture()
  let s = sessions[ui]
  let span = s.viewport_span
  let (_, x, y) = drag_clip(ui, "v2", 10000)
  assert_true(x > s.width && s.clip_move_start == 1260000)
  assert_eq(s.viewport_span, span)
  ignore(project_apply(ui, core, point_event(ui, "pointerUp", x, y)))
  assert_eq(s.snapshot.duration, 22000)
  assert_eq(s.viewport_span, 22000)
  assert_true(s.viewport_extent > s.snapshot.duration)
  let before = @project_core.snapshot(core)
  for stop in ["escape", "cancel", "resize", "media"] {
    let (_, x, y) = drag_clip(ui, "v2", 1000)
    assert_true(s.clip_drag_active)
    match stop {
      "escape" => ignore(key_event(ui, "Escape"))
      "cancel" => ignore(event(ui, "{\"type\":\"cancel\"}"))
      "resize" => ignore(frame(ui, 800, 600))
      _ =>
        ignore(
          event(
            ui, "{\"type\":\"mediaStatus\",\"ready\":false,\"message\":\"test\"}",
          ),
        )
    }
    assert_true(!s.clip_drag_active)
    assert_eq(command_effects(point_event(ui, "pointerUp", x, y)).length(), 0)
    assert_eq(@project_core.snapshot(core), before)
    ignore(frame(ui, 1040, 700))
    ignore(
      event(ui, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
    )
  }
  close(ui)
  @project_core.close(core)
}

///|
test "linked audio drag moves video but detached audio drag stays independent" {
  let (ui, core) = split_drag_fixture()
  let s = sessions[ui]
  s.audio_expanded = true
  let (_, x, y) = drag_clip(ui, "a2", 1000)
  ignore(project_apply(ui, core, point_event(ui, "pointerUp", x, y)))
  assert_eq(project_clip(s, "v2").unwrap().start, 450000)
  assert_eq(project_clip(s, "a2").unwrap().start, 450000)
  ignore(project_apply(ui, core, activate_event(ui, "project-unlink")))
  let (_, x, y) = drag_clip(ui, "a2", -20000)
  assert_eq(s.clip_move_start, 0)
  ignore(project_apply(ui, core, point_event(ui, "pointerUp", x, y)))
  assert_eq(project_clip(s, "a2").unwrap().start, 0)
  assert_eq(project_clip(s, "v2").unwrap().start, 450000)
  close(ui)
  @project_core.close(core)
}

///|
test "dragged linked audio waveform retains the same source envelope" {
  let (ui, core) = split_drag_fixture()
  let s = sessions[ui]
  ignore(
    event(
      ui, "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[0,0,0.8,0,0.2,0]}",
    ),
  )
  let audio = project_clip(s, "a2").unwrap()
  let first = project_waveform_peak(
    s,
    audio,
    project_x(s, 360000),
    project_x(s, 450000),
  )
  let later = project_waveform_peak(
    s,
    audio,
    project_x(s, 720000),
    project_x(s, 810000),
  )
  assert_eq(first, 0.8)
  assert_eq(later, 0.2)
  ignore(drag_clip(ui, "v2", 2000))
  assert_eq(
    project_waveform_peak(s, audio, project_x(s, 540000), project_x(s, 630000)),
    first,
  )
  assert_eq(
    project_waveform_peak(s, audio, project_x(s, 900000), project_x(s, 990000)),
    later,
  )
  ignore(key_event(ui, "Escape"))
  close(ui)
  @project_core.close(core)
}
