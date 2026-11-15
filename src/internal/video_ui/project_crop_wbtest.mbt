///|
fn crop_drag_test(
  ui : Int32,
  x1 : Double,
  y1 : Double,
  x2 : Double,
  y2 : Double,
) -> Unit raise {
  let r = project_video_rect(sessions[ui])
  assert_eq(
    command_effects(
      point_event(ui, "pointerDown", r.x + r.width * x1, r.y + r.height * y1),
    ).length(),
    0,
  )
  assert_eq(
    command_effects(
      point_event(ui, "pointerMove", r.x + r.width * x2, r.y + r.height * y2),
    ).length(),
    0,
  )
  assert_eq(
    command_effects(
      point_event(ui, "pointerUp", r.x + r.width * x2, r.y + r.height * y2),
    ).length(),
    0,
  )
}

///|
test "global mute is undoable without altering clip links or preview speed" {
  let (ui, core) = project_fixture()
  let before = @project_core.snapshot(core)
  let clips = project(sessions[ui]).clips
  let muted = activate_event(ui, "project-mute")
  assert_eq(string(project_op(muted), "type"), "mute")
  assert_true(boolean(project_op(muted), "muted"))
  ignore(project_apply(ui, core, muted))
  assert_true(project(sessions[ui]).muted)
  assert_true(
    string(node(ui, "project-mute", 1040, 700), "label").contains("恢复"),
  )
  assert_eq(
    project(sessions[ui]).clips.map(c => (c.id, c.link_group, c.duration)),
    clips.map(c => (c.id, c.link_group, c.duration)),
  )
  assert_eq(sessions[ui].preview_rate, 1)
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(
    fields(@project_core.snapshot(core))["plan"],
    fields(before)["plan"],
  )
  assert_true(!project(sessions[ui]).muted)
  close(ui)
  @project_core.close(core)
  let raw = @project_core.open(
    "{\"durationMs\":4000,\"width\":1920,\"height\":1080,\"hasAudio\":false}", "",
  )
  let core = @test_support.number_result(raw, "session").to_int()
  let ui = open(raw)
  assert_true(!boolean(node(ui, "project-mute", 1040, 700), "enabled"))
  assert_true(
    string(node(ui, "project-mute", 1040, 700), "label").contains(
      "没有音频",
    ),
  )
  assert_eq(command_effects(activate_event(ui, "project-mute")).length(), 0)
  close(ui)
  @project_core.close(core)
}

///|
test "crop drag applies once with source offsets and output aspect while cancel never edits" {
  let (ui, core) = project_fixture()
  let s = sessions[ui]
  let original = @project_core.snapshot(core)
  ignore(
    event(ui, "{\"type\":\"playback\",\"outputMs\":1000,\"playing\":true}"),
  )
  let opened = activate_event(ui, "project-crop")
  assert_true(
    effects(opened).any(e => {
      e is Object({ "type": String("play"), "playing": False, .. })
    }),
  )
  assert_true(s.crop_mode && !s.playing)
  for
    id in [
      "play", "playhead", "project-trim-start", "project-mute", "export", "undo",
      "project-zoom-in",
    ] {
    assert_true(!enabled(s, id))
    assert_eq(command_effects(activate_event(ui, id)).length(), 0)
  }
  crop_drag_test(ui, 0.25, 0.25, 0.5, 0.75)
  assert_eq(@project_core.snapshot(core), original)
  let candidate = s.crop_candidate
  assert_eq(
    (candidate.x, candidate.y, candidate.width, candidate.height),
    (480, 270, 480, 540),
  )
  let overlay = @test_support.model_test_items(
    fields(frame(ui, 1040, 700))["overlayCommands"],
  )
  assert_true(overlay.length() >= 4)
  assert_eq(command_effects(key_event(ui, "Escape")).length(), 0)
  assert_true(!s.crop_mode)
  assert_eq(@project_core.snapshot(core), original)
  ignore(activate_event(ui, "project-crop"))
  crop_drag_test(ui, 0.25, 0.25, 0.5, 0.75)
  let applied = activate_event(ui, "project-crop-apply")
  assert_eq(
    project_op(applied)["crop"],
    @json.parse("{\"x\":480,\"y\":270,\"width\":480,\"height\":540}"),
  )
  ignore(project_apply(ui, core, applied))
  assert_true(!s.crop_mode)
  assert_eq(s.snapshot.source_width, 1920)
  let video = @protocol.object_field(fields(frame(ui, 1040, 700)), "videoRect")
  assert_true(
    (number(video, "width") / number(video, "height") - 480.0 / 540).abs() <
    0.00001,
  )
  // A second crop refers to the original source, not the cropped image origin.
  ignore(activate_event(ui, "project-crop"))
  crop_drag_test(ui, 0.25, 0, 0.75, 1)
  let nested = key_event(ui, "Enter")
  assert_eq(
    project_op(nested)["crop"],
    @json.parse("{\"x\":600,\"y\":270,\"width\":240,\"height\":540}"),
  )
  ignore(project_apply(ui, core, nested))
  ignore(activate_event(ui, "project-crop"))
  let reset = activate_event(ui, "project-crop-reset")
  assert_eq(project_op(reset)["crop"], Json::null())
  ignore(project_apply(ui, core, reset))
  assert_true(project(s).crop is None)
  assert_true(
    (project_video_rect(s).width / project_video_rect(s).height - 16.0 / 9).abs() <
    0.00001,
  )
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(project(s).crop.unwrap().x, 600)
  close(ui)
  @project_core.close(core)
}

///|
test "crop keyboard small windows and late input invalidation remain shared and non destructive" {
  let (ui, core) = project_fixture()
  let s = sessions[ui]
  let original = @project_core.snapshot(core)
  for
    invalidation in [
      "{\"type\":\"cancel\"}", "{\"type\":\"error\",\"message\":\"failed\"}", "{\"type\":\"mediaStatus\",\"ready\":false,\"message\":\"failed\"}",
    ] {
    ignore(
      event(ui, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
    )
    ignore(activate_event(ui, "project-crop"))
    let r = project_video_rect(s)
    ignore(point_event(ui, "pointerDown", r.x + 10, r.y + 10))
    ignore(point_event(ui, "pointerMove", r.x + 100, r.y + 100))
    assert_eq(command_effects(event(ui, invalidation)).length(), 0)
    assert_true(!s.crop_mode)
    assert_eq(
      command_effects(point_event(ui, "pointerUp", r.x + 100, r.y + 100)).length(),
      0,
    )
    assert_eq(@project_core.snapshot(core), original)
  }
  ignore(
    event(ui, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
  )
  ignore(activate_event(ui, "project-crop"))
  assert_eq(command_effects(sync(ui, original)).length(), 0)
  assert_true(!s.crop_mode)
  ignore(activate_event(ui, "project-crop"))
  ignore(
    event(
      ui, "{\"type\":\"key\",\"key\":\"ArrowLeft\",\"mod\":false,\"shift\":true}",
    ),
  )
  ignore(key_event(ui, "ArrowRight"))
  assert_eq((s.crop_candidate.x, s.crop_candidate.width), (1, 1918))
  assert_eq(@project_core.snapshot(core), original)
  for (width, height) in [(1040.0, 700.0), (360.0, 240.0)] {
    let result = fields(frame(ui, width, height))
    for item in @test_support.model_test_items(result["semantics"]) {
      match item {
        Object(m) => {
          bounded_rect(m, width, height)
          assert_true(string(m, "label") != "")
        }
        _ => abort("semantic")
      }
    }
    assert_true(
      @test_support.model_test_items(result["overlayCommands"]).length() > 0,
    )
  }
  let apply = key_event(ui, "Enter")
  assert_eq(
    number(@protocol.object_field(project_op(apply), "crop"), "width"),
    1918,
  )
  ignore(project_apply(ui, core, apply))
  ignore(frame(ui, 1040, 700))
  ignore(activate_event(ui, "project-crop"))
  crop_drag_test(ui, 0.5, 0.5, 0.5, 0.5)
  assert_true(!enabled(s, "project-crop-apply"))
  assert_eq(command_effects(key_event(ui, "Enter")).length(), 0)
  ignore(activate_event(ui, "project-crop-cancel"))
  close(ui)
  @project_core.close(core)
}
