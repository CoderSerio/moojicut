///|
fn project_scroll_event(
  ui : Int32,
  x : Double,
  y : Double,
  dx : Double,
  dy : Double,
  modifier : Bool,
  precise : Bool,
) -> String {
  event(
    ui,
    Json::object({
      "type": Json("scroll"),
      "x": Json(x),
      "y": Json(y),
      "deltaX": Json(dx),
      "deltaY": Json(dy),
      "mod": Json(modifier),
      "shift": Json(false),
      "precise": Json(precise),
    }).stringify(),
  )
}

///|
fn project_has_node(ui : Int32, id : String) -> Bool raise {
  @test_support.model_test_items(fields(frame(ui, 1040, 700))["semantics"]).any(item => {
      item is Object(m) && m.get("id") == Some(Json(id))
    },
  )
}

///|
fn project_three_clips(ui : Int32, core : Int32) -> Unit raise {
  project_clock(ui, 4000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  let second = project_clips(sessions[ui], "video")[1]
  ignore(activate_event(ui, "clip:\{second.id}"))
  project_clock(ui, 8000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
}

///|
test "viewport zoom pan clipping and minimum granularity do not edit the project" {
  let (ui, core) = project_fixture()
  project_three_clips(ui, core)
  let s = sessions[ui]
  project_clock(ui, 6000)
  let before = @project_core.snapshot(core)
  for _ in 0..<2 {
    assert_eq(effects(activate_event(ui, "project-zoom-in")).length(), 0)
  }
  let viewport = @protocol.object_field(
    fields(frame(ui, 1040, 700)),
    "viewport",
  )
  assert_eq(number(viewport, "spanMs"), 3000)
  assert_eq(number(viewport, "startMs"), 4500)
  let clips = project_clips(s, "video")
  assert_true(!project_has_node(ui, "clip:\{clips[0].id}"))
  assert_true(!project_has_node(ui, "clip:\{clips[2].id}"))
  assert_true(!project_has_node(ui, "project-trim-start"))
  assert_true(!project_has_node(ui, "project-trim-end"))
  let visible = node(ui, "clip:\{clips[1].id}", 1040, 700)
  let row = project_track(s, "video")
  assert_eq(number(visible, "x"), row.x)
  assert_eq(number(visible, "width"), row.width)
  assert_eq(project_hit(s, row.x + 1, row.y + 15), "clip:\{clips[1].id}")
  // A mouse wheel can pan too; precise trackpads preserve their point deltas.
  assert_eq(
    effects(project_scroll_event(ui, row.x + 200, row.y, 0, -10, false, false)).length(),
    0,
  )
  assert_true(s.viewport_start > 4500)
  let start = s.viewport_start
  ignore(project_scroll_event(ui, row.x + 200, row.y, 10, 0, false, true))
  assert_true(s.viewport_start < start)
  let anchor_x = row.x + row.width / 3
  let anchor = project_time(s, anchor_x)
  ignore(project_scroll_event(ui, anchor_x, row.y, 0, 1, true, true))
  assert_true((project_time(s, anchor_x) - anchor).abs() < 0.0001)
  // No fake playhead is drawn at a viewport edge when its time is outside.
  project_clock(ui, 0)
  let drawing = @test_support.model_test_items(
    fields(frame(ui, 1040, 700))["commands"],
  )
  let color = palette(s).playhead
  assert_true(
    !drawing.any(item => {
      item is Object(m) &&
      m.get("type") == Some(Json("line")) &&
      m.get("color") == Some(Json(color)) &&
      m.get("lineWidth") == Some(Json(1.5))
    }),
  )
  for _ in 0..<12 {
    ignore(activate_event(ui, "project-zoom-in"))
  }
  assert_eq(s.viewport_span, 100)
  assert_true(!enabled(s, "project-zoom-in"))
  for (width, height) in [(720.0, 480.0), (1040.0, 700.0), (360.0, 240.0)] {
    for appearance in ["light", "dark"] {
      ignore(
        event(
          ui,
          Json::object({ "type": Json("appearance"), "mode": Json(appearance) }).stringify(),
        ),
      )
      let result = fields(frame(ui, width, height))
      for item in @test_support.model_test_items(result["semantics"]) {
        match item {
          Object(m) => bounded_rect(m, width, height)
          _ => abort("semantic")
        }
      }
      let left = node(ui, "project-zoom-out", width, height)
      let middle = node(ui, "project-zoom-in", width, height)
      let right = node(ui, "project-zoom-fit", width, height)
      assert_true(
        number(left, "x") + number(left, "width") < number(middle, "x"),
      )
      assert_true(
        number(middle, "x") + number(middle, "width") < number(right, "x"),
      )
    }
  }
  // Explicit transport navigation follows a paused playhead as well.
  for id in ["end", "start", "forward", "backward"] {
    assert_eq(command_effects(activate_event(ui, id)).length(), 0)
    assert_true(project_visible(s, s.source_time))
  }
  for key in ["End", "Home"] {
    assert_eq(command_effects(key_event(ui, key)).length(), 0)
    assert_true(project_visible(s, s.source_time))
  }
  ignore(activate_event(ui, "project-zoom-fit"))
  assert_eq(s.viewport_start, 0)
  assert_eq(s.viewport_span, 12000)
  assert_eq(@project_core.snapshot(core), before)
  close(ui)
  @project_core.close(core)
}

///|
test "zoomed pointer seek trim cancel and frame keyboard use the same output mapping" {
  let (ui, core) = project_fixture()
  project_three_clips(ui, core)
  let s = sessions[ui]
  let second = project_clips(s, "video")[1]
  ignore(activate_event(ui, "clip:\{second.id}"))
  project_clock(ui, 4000)
  ignore(activate_event(ui, "project-zoom-in"))
  let row = project_track(s, "video")
  let ruler = control_rect(s, "playhead")
  let x = row.x + row.width / 2
  let ms = s.viewport_start + s.viewport_span / 2
  ignore(point_event(ui, "pointerDown", x, ruler.y + 10))
  let seeked = point_event(ui, "pointerUp", x, ruler.y + 10)
  assert_true(
    effects(seeked).any(e => {
      e
      is Object({ "type": String("seekOutput"), "outputMs": Number(t, ..), .. }) &&
      t == ms
    }),
  )
  let handle = control_rect(s, "project-trim-start")
  let hx = handle.x + handle.width / 2
  let hy = handle.y + 15
  let before = @project_core.snapshot(core)
  ignore(point_event(ui, "pointerDown", hx, hy))
  let viewport = (s.viewport_start, s.viewport_span)
  ignore(project_scroll_event(ui, hx, hy, 0, -40, false, true))
  ignore(project_scroll_event(ui, hx, hy, 0, 1, true, true))
  assert_eq((s.viewport_start, s.viewport_span), viewport)
  let moved = hx + row.width * 500 / s.viewport_span
  ignore(point_event(ui, "pointerMove", moved, hy))
  assert_eq(s.clip_trim_start, second.source_start + 45000)
  ignore(key_event(ui, "Escape"))
  assert_eq(
    command_effects(point_event(ui, "pointerUp", moved, hy)).length(),
    0,
  )
  assert_eq(@project_core.snapshot(core), before)
  ignore(point_event(ui, "pointerDown", hx, hy))
  ignore(point_event(ui, "pointerMove", moved, hy))
  let trimmed = point_event(ui, "pointerUp", moved, hy)
  assert_eq(
    number(project_op(trimmed), "sourceStartTicks"),
    second.source_start + 45000,
  )
  ignore(project_apply(ui, core, trimmed))
  assert_eq(
    command_effects(point_event(ui, "pointerUp", moved, hy)).length(),
    0,
  )
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  ignore(activate_event(ui, "clip:\{second.id}"))
  ignore(activate_event(ui, "project-trim-start"))
  let key_trim = key_event(ui, "ArrowRight")
  assert_eq(
    number(project_op(key_trim), "sourceStartTicks"),
    second.source_start + 3000,
  )
  ignore(project_apply(ui, core, key_trim))
  ignore(activate_event(ui, "playhead"))
  project_clock(ui, 4000)
  for _ in 0..<30 {
    ignore(key_event(ui, "ArrowRight"))
  }
  assert_eq(s.source_time, 5000)
  ignore(
    event(
      ui, "{\"type\":\"key\",\"key\":\"ArrowLeft\",\"mod\":false,\"shift\":true}",
    ),
  )
  assert_true((s.source_time - (5000 - 1000.0 / 3)).abs() < 0.00001)
  ignore(
    event(ui, "{\"type\":\"playback\",\"outputMs\":11000,\"playing\":true}"),
  )
  assert_true(project_visible(s, s.source_time))
  close(ui)
  @project_core.close(core)
}

///|
test "ordinary deletion leaves a selectable gap and deleting it is one undoable core edit" {
  let (ui, core) = project_fixture()
  project_three_clips(ui, core)
  let s = sessions[ui]
  let clips = project_clips(s, "video")
  let second = clips[1]
  ignore(activate_event(ui, "clip:\{second.id}"))
  let removed = activate_event(ui, "project-remove")
  assert_true(!boolean(project_op(removed), "ripple"))
  ignore(project_apply(ui, core, removed))
  assert_eq(project_clip(s, clips[2].id).unwrap().start, 720000)
  let gap_id = "gap:360000:720000"
  let gap = node(ui, gap_id, 1040, 700)
  let x = number(gap, "x") + number(gap, "width") / 2
  let y = number(gap, "y") + 15
  let before = @project_core.snapshot(core)
  assert_eq(effects(point_event(ui, "pointerDown", x, y)).length(), 0)
  assert_eq(effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  assert_eq(s.selected_gap, gap_id)
  assert_eq(@project_core.snapshot(core), before)
  for
    id in [
      "project-split", "project-speed", "project-unlink", "project-move-earlier",
      "project-trim-start", "project-trim-end",
    ] {
    assert_true(!enabled(s, id))
    assert_eq(effects(activate_event(ui, id)).length(), 0)
  }
  let collapsed = key_event(ui, "Delete")
  let op = project_op(collapsed)
  assert_eq(string(op, "type"), "removeGap")
  assert_eq(number(op, "startTicks"), 360000)
  assert_eq(number(op, "endTicks"), 720000)
  ignore(project_apply(ui, core, collapsed))
  assert_eq(project_clip(s, clips[2].id).unwrap().start, 360000)
  assert_eq(s.snapshot.duration, 8000)
  assert_true(project_gaps(s).is_empty())
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(project_gaps(s).length(), 1)
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(project_clips(s, "video").length(), 3)
  assert_eq(s.snapshot.duration, 12000)
  ignore(activate_event(ui, "clip:\{second.id}"))
  let ripple = event(
    ui, "{\"type\":\"key\",\"key\":\"Backspace\",\"mod\":false,\"shift\":true}",
  )
  assert_true(boolean(project_op(ripple), "ripple"))
  ignore(project_apply(ui, core, ripple))
  assert_eq(s.snapshot.duration, 8000)
  assert_true(project_gaps(s).is_empty())
  close(ui)
  @project_core.close(core)
}

///|
test "v1 safely ignores project scrolling and deletion keys" {
  let (ui, core, snapshot) = fixture()
  assert_eq(
    effects(project_scroll_event(ui, 300, 350, 2, -4, true, false)).length(),
    0,
  )
  for key in ["Delete", "Backspace"] {
    assert_eq(effects(key_event(ui, key)).length(), 0)
  }
  assert_eq(@video.video_snapshot(core), snapshot)
  close(ui)
  @video.video_dispose(core)
}
