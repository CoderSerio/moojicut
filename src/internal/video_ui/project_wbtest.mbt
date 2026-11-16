///|
let project_test_request : Ref[Int32] = Ref(0)

///|
fn project_fixture() -> (Int32, Int32) raise {
  let snapshot = @project_core.open(
    "{\"durationMs\":12000,\"width\":1920,\"height\":1080,\"hasAudio\":true}", "",
  )
  ignore(@test_support.model_test_result(snapshot))
  let core = @test_support.number_result(snapshot, "session").to_int()
  let ui = open(snapshot)
  assert_true(ui >= 0)
  ignore(@test_support.model_test_result(frame(ui, 1040, 700)))
  (ui, core)
}

///|
fn project_apply(ui : Int32, core : Int32, response : String) -> String raise {
  let commands = command_effects(response)
  assert_eq(commands.length(), 1)
  let op = @test_support.model_test_field(commands[0], "command")
  let revision = @test_support.number_result(
    @project_core.snapshot(core),
    "revision",
  )
  project_test_request.val = project_test_request.val + 1
  let next = @project_core.command(
    core,
    Json::object({
      "expectedRevision": Json(revision),
      "requestId": Json("ui-\{project_test_request.val}"),
      "op": op,
    }).stringify(),
  )
  ignore(@test_support.model_test_result(next))
  ignore(@test_support.model_test_result(sync(ui, next)))
  next
}

///|
fn project_clock(ui : Int32, output_ms : Double) -> Unit {
  ignore(
    event(
      ui,
      Json::object({
        "type": Json("playback"),
        "outputMs": Json(output_ms),
        "playing": Json(false),
      }).stringify(),
    ),
  )
}

///|
fn project_op(response : String) -> Map[String, Json] raise {
  let commands = command_effects(response)
  assert_eq(commands.length(), 1)
  match @test_support.model_test_field(commands[0], "command") {
    Object(m) => m
    _ => abort("command op")
  }
}

///|
test "v2 split select reorder actual speed unlink audio offset remove and undo use real core" {
  let (ui, core) = project_fixture()
  project_clock(ui, 4000)
  let split = activate_event(ui, "project-split")
  assert_eq(number(project_op(split), "atTicks"), 360000)
  ignore(project_apply(ui, core, split))
  let second = project_clips(sessions[ui], "video")[1]
  ignore(activate_event(ui, "clip:\{second.id}"))
  project_clock(ui, 8000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  let third = project_clips(sessions[ui], "video")[2]
  ignore(activate_event(ui, "clip:\{third.id}"))
  let moved = activate_event(ui, "project-move-earlier")
  assert_eq(string(project_op(moved), "beforeClipId"), second.id)
  ignore(project_apply(ui, core, moved))
  assert_eq(project_clips(sessions[ui], "video")[1].id, third.id)
  let original = @project_core.snapshot(core)
  ignore(activate_event(ui, "preview-rate"))
  assert_eq(command_effects(activate_event(ui, "rate-3")).length(), 0)
  assert_eq(@project_core.snapshot(core), original)
  ignore(activate_event(ui, "project-speed"))
  let accelerated = activate_event(ui, "clip-rate-3")
  let op = project_op(accelerated)
  assert_eq(string(op, "type"), "setSpeed")
  assert_true(boolean(op, "linked") && boolean(op, "ripple"))
  ignore(project_apply(ui, core, accelerated))
  let selected = project_selected(sessions[ui]).unwrap()
  assert_eq(selected.duration, 120000)
  let linked_audio = project_clips(sessions[ui], "audio").filter(c => {
      c.link_group == selected.link_group
    })[0]
  assert_eq(linked_audio.duration, selected.duration)
  assert_eq(effects(activate_event(ui, "project-audio-toggle")).length(), 0)
  assert_true(
    boolean(node(ui, "clip:\{linked_audio.id}", 1040, 700), "enabled"),
  )
  ignore(project_apply(ui, core, activate_event(ui, "project-unlink")))
  ignore(activate_event(ui, "clip:\{linked_audio.id}"))
  assert_true(!enabled(sessions[ui], "project-move-later"))
  let before = project_selected(sessions[ui]).unwrap()
  let offset = activate_event(ui, "project-offset-later")
  let offset_op = project_op(offset)
  assert_eq(string(offset_op, "type"), "offset")
  assert_true(number(offset_op, "deltaTicks") > 0)
  ignore(project_apply(ui, core, offset))
  let shifted = project_selected(sessions[ui]).unwrap()
  assert_eq(shifted.start, before.start + number(offset_op, "deltaTicks"))
  let video_before = project_clips(sessions[ui], "video").map(c => {
    (c.id, c.start, c.duration)
  })
  let removed = activate_event(ui, "project-remove")
  assert_true(!boolean(project_op(removed), "ripple"))
  ignore(project_apply(ui, core, removed))
  assert_true(project_clip(sessions[ui], linked_audio.id) is None)
  assert_eq(
    project_clips(sessions[ui], "video").map(c => (c.id, c.start, c.duration)),
    video_before,
  )
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_eq(
    project_clip(sessions[ui], linked_audio.id).unwrap().start,
    shifted.start,
  )
  close(ui)
  @project_core.close(core)
}

///|
test "v2 independent audio speed and trim preserve video and emit one transaction after cancel-safe gesture" {
  let (ui, core) = project_fixture()
  ignore(project_apply(ui, core, activate_event(ui, "project-unlink")))
  ignore(activate_event(ui, "project-audio-toggle"))
  let audio = project_clips(sessions[ui], "audio")[0]
  ignore(activate_event(ui, "clip:\{audio.id}"))
  let video_before = project_clips(sessions[ui], "video").map(c => {
    (c.id, c.start, c.duration)
  })
  ignore(activate_event(ui, "project-speed"))
  let accelerated = activate_event(ui, "clip-rate-2")
  assert_true(!boolean(project_op(accelerated), "ripple"))
  ignore(project_apply(ui, core, accelerated))
  assert_eq(
    project_clips(sessions[ui], "video").map(c => (c.id, c.start, c.duration)),
    video_before,
  )
  let before = @project_core.snapshot(core)
  let end = node(ui, "project-trim-end", 1040, 700)
  let x = number(end, "x") + number(end, "width") / 2
  let y = number(end, "y") + 15
  assert_eq(effects(point_event(ui, "pointerDown", x, y)).length(), 0)
  assert_eq(effects(point_event(ui, "pointerMove", x - 80, y)).length(), 0)
  assert_eq(@project_core.snapshot(core), before)
  assert_eq(effects(key_event(ui, "Escape")).length(), 0)
  assert_eq(
    command_effects(point_event(ui, "pointerUp", x - 80, y)).length(),
    0,
  )
  assert_eq(@project_core.snapshot(core), before)
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", x - 80, y))
  let trimmed = point_event(ui, "pointerUp", x - 80, y)
  assert_true(!boolean(project_op(trimmed), "ripple"))
  assert_true(
    effects(trimmed).any(e => {
      e
      is Object({ "type": String("seekOutput"), "outputMs": Number(0, ..), .. })
    }),
  )
  assert_eq(command_effects(trimmed).length(), 1)
  ignore(project_apply(ui, core, trimmed))
  assert_true(
    project_clip(sessions[ui], audio.id).unwrap().source_end < audio.source_end,
  )
  assert_eq(
    project_clips(sessions[ui], "video").map(c => (c.id, c.start, c.duration)),
    video_before,
  )
  assert_eq(
    command_effects(point_event(ui, "pointerUp", x - 80, y)).length(),
    0,
  )
  close(ui)
  @project_core.close(core)
}

///|
test "v2 output transport source-rate trim and small-window menus share geometry and themes" {
  let (ui, core) = project_fixture()
  project_clock(ui, 6000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  let second = project_clips(sessions[ui], "video")[1]
  ignore(activate_event(ui, "clip:\{second.id}"))
  ignore(activate_event(ui, "project-speed"))
  ignore(project_apply(ui, core, activate_event(ui, "clip-rate-3")))
  project_clock(ui, 7000)
  let forward = effects(activate_event(ui, "forward"))
  assert_true(
    forward.any(e => {
      e
      is Object(
        { "type": String("seekOutput"), "outputMs": Number(7080, ..), .. }
      )
    }),
  )
  assert_true(!forward.any(e => effect_kind(e) == "seek"))
  let end = node(ui, "project-trim-end", 1040, 700)
  let x = number(end, "x") + 6
  let y = number(end, "y") + 15
  ignore(point_event(ui, "pointerDown", x, y))
  // 500ms off a 3x output edge removes 1500ms of source, not 500ms.
  let delta = project_track(sessions[ui], "video").width *
    500 /
    sessions[ui].viewport_span
  ignore(point_event(ui, "pointerMove", x - delta, y))
  let trimmed = point_event(ui, "pointerUp", x - delta, y)
  assert_eq(number(project_op(trimmed), "sourceEndTicks"), 10500 * 90)
  ignore(project_apply(ui, core, trimmed))
  ignore(activate_event(ui, "project-audio-toggle"))
  for (width, height) in [(720.0, 480.0), (1040.0, 700.0), (360.0, 240.0)] {
    for mode in ["dark", "light"] {
      ignore(
        event(
          ui,
          Json::object({ "type": Json("appearance"), "mode": Json(mode) }).stringify(),
        ),
      )
      for menu in ["", "project-speed", "preview-rate"] {
        if menu != "" {
          ignore(activate_event(ui, menu))
        }
        let result = fields(frame(ui, width, height))
        ignore(neutral_drawing_colors(result))
        bounded_rect(@protocol.object_field(result, "videoRect"), width, height)
        for item in @test_support.model_test_items(result["semantics"]) {
          match item {
            Object(m) => {
              bounded_rect(m, width, height)
              assert_true(string(m, "label") != "")
            }
            _ => abort("semantic object")
          }
        }
        for item in @test_support.model_test_items(result["commands"]) {
          match item {
            Object(m) if m.get("type") != Some(Json("line")) =>
              bounded_rect(m, width, height)
            _ => ()
          }
        }
        ignore(key_event(ui, "Escape"))
      }
    }
  }
  close(ui)
  @project_core.close(core)
}

///|
test "v2 split non-frame source edge survives idle handle click and opposite-edge trim" {
  let (ui, core) = project_fixture()
  ignore(activate_event(ui, "project-speed"))
  ignore(project_apply(ui, core, activate_event(ui, "clip-rate-1.5")))
  project_clock(ui, 3000.0 / 90)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  let clips = project_clips(sessions[ui], "video")
  assert_eq(clips[0].source_end, 4500)
  assert_eq(clips[1].source_start, 4500)
  let first_end = node(ui, "project-trim-end", 1040, 700)
  let x = number(first_end, "x") + 6
  let y = number(first_end, "y") + 15
  ignore(point_event(ui, "pointerDown", x, y))
  assert_eq(command_effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  ignore(activate_event(ui, "clip:\{clips[1].id}"))
  let end = node(ui, "project-trim-end", 1040, 700)
  let x = number(end, "x") + 6
  let y = number(end, "y") + 15
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", x - 60, y))
  let trimmed = point_event(ui, "pointerUp", x - 60, y)
  assert_eq(number(project_op(trimmed), "sourceStartTicks"), 4500)
  ignore(project_apply(ui, core, trimmed))
  assert_eq(project_clip(sessions[ui], clips[1].id).unwrap().source_start, 4500)
  close(ui)
  @project_core.close(core)
}

///|
test "v2 media invalidation closes actual speed menu and cancels trim without edits" {
  let (ui, core) = project_fixture()
  project_clock(ui, 6000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  ignore(activate_event(ui, "project-speed"))
  assert_true(sessions[ui].clip_speed_menu)
  let failed = event(
    ui, "{\"type\":\"mediaStatus\",\"ready\":false,\"message\":\"无法播放此计划\"}",
  )
  assert_eq(effects(failed).length(), 0)
  assert_true(!sessions[ui].clip_speed_menu)
  let before = @project_core.snapshot(core)
  for
    id in [
      "project-split", "project-remove", "project-speed", "project-unlink", "project-move-later",
      "play", "forward", "export",
    ] {
    assert_true(!enabled(sessions[ui], id))
    assert_eq(effects(activate_event(ui, id)).length(), 0)
  }
  assert_eq(@project_core.snapshot(core), before)
  assert_true(enabled(sessions[ui], "undo"))
  ignore(project_apply(ui, core, activate_event(ui, "undo")))
  assert_true(!enabled(sessions[ui], "play"))
  ignore(
    event(ui, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
  )
  let handle = node(ui, "project-trim-end", 1040, 700)
  let x = number(handle, "x") + 6
  let y = number(handle, "y") + 15
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", x - 40, y))
  assert_eq(
    effects(
      event(
        ui, "{\"type\":\"mediaStatus\",\"ready\":false,\"message\":\"失效\"}",
      ),
    ).length(),
    0,
  )
  assert_eq(
    command_effects(point_event(ui, "pointerUp", x - 40, y)).length(),
    0,
  )
  close(ui)
  @project_core.close(core)
}

///|
fn assert_audio_slow_rejected(core : Int32, clip_id : String) -> Unit raise {
  let before = @project_core.snapshot(core)
  let revision = @test_support.number_result(before, "revision")
  let result = fields(
    @project_core.command(
      core,
      Json::object({
        "expectedRevision": Json(revision),
        "type": Json("setSpeed"),
        "clipId": Json(clip_id),
        "rate": Json::object({ "num": Json(1), "den": Json(2) }),
        "ripple": Json(false),
      }).stringify(),
    ),
  )
  assert_true(!boolean(result, "ok"))
  assert_eq(
    string(@protocol.object_field(result, "error"), "code"),
    "unsupported_audio_slowdown",
  )
  assert_eq(@project_core.snapshot(core), before)
}

///|
test "actual audio slowdown is rejected atomically and shared menu skips it without an operation" {
  let (ui, core) = project_fixture()
  let video = project_clips(sessions[ui], "video")[0]
  let audio = project_clips(sessions[ui], "audio")[0]
  assert_audio_slow_rejected(core, video.id)
  let before = @project_core.snapshot(core)
  ignore(activate_event(ui, "project-speed"))
  let menu = node(ui, "project-speed-menu", 1040, 700)
  assert_eq(string(menu, "role"), "group")
  assert_true(!boolean(menu, "enabled"))
  assert_eq(effects(activate_event(ui, "project-speed-menu")).length(), 0)
  assert_true(sessions[ui].clip_speed_menu)
  let disabled = node(ui, "clip-rate-0.5", 1040, 700)
  assert_true(
    number(menu, "x") < number(disabled, "x") &&
    number(menu, "y") < number(disabled, "y"),
  )
  assert_true(!boolean(disabled, "enabled"))
  assert_eq(effects(activate_event(ui, "clip-rate-0.5")).length(), 0)
  let x = number(disabled, "x") + 40
  let y = number(disabled, "y") + 13
  assert_eq(effects(point_event(ui, "pointerDown", x, y)).length(), 0)
  assert_eq(effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  ignore(key_event(ui, "Home"))
  assert_true(boolean(node(ui, "clip-rate-1", 1040, 700), "focused"))
  ignore(key_event(ui, "ArrowUp"))
  assert_true(boolean(node(ui, "clip-rate-3", 1040, 700), "focused"))
  ignore(key_event(ui, "ArrowDown"))
  assert_true(boolean(node(ui, "clip-rate-1", 1040, 700), "focused"))
  ignore(key_event(ui, "End"))
  assert_true(boolean(node(ui, "clip-rate-3", 1040, 700), "focused"))
  ignore(key_event(ui, "Home"))
  let chosen = key_event(ui, "Enter")
  assert_eq(
    number(@protocol.object_field(project_op(chosen), "rate"), "num"),
    1,
  )
  assert_eq(
    number(@protocol.object_field(project_op(chosen), "rate"), "den"),
    1,
  )
  ignore(project_apply(ui, core, chosen))
  assert_eq(@project_core.snapshot(core), before)
  ignore(activate_event(ui, "preview-rate"))
  assert_true(boolean(node(ui, "rate-0.5", 1040, 700), "enabled"))
  let preview = activate_event(ui, "rate-0.5")
  assert_eq(command_effects(preview).length(), 0)
  assert_true(
    effects(preview)[0]
    is Object({ "type": String("previewRate"), "rate": Number(0.5, ..), .. }),
  )
  ignore(project_apply(ui, core, activate_event(ui, "project-unlink")))
  ignore(activate_event(ui, "project-speed"))
  assert_true(boolean(node(ui, "clip-rate-0.5", 1040, 700), "enabled"))
  ignore(key_event(ui, "Escape"))
  ignore(activate_event(ui, "project-audio-toggle"))
  ignore(activate_event(ui, "clip:\{audio.id}"))
  ignore(activate_event(ui, "project-speed"))
  assert_true(!boolean(node(ui, "clip-rate-0.5", 1040, 700), "enabled"))
  assert_eq(effects(activate_event(ui, "clip-rate-0.5")).length(), 0)
  assert_audio_slow_rejected(core, audio.id)
  close(ui)
  @project_core.close(core)
}

///|
test "video without an audio track keeps actual half-speed and an enabled keyboard menu row" {
  let snapshot = @project_core.open(
    "{\"durationMs\":12000,\"width\":1920,\"height\":1080,\"hasAudio\":false}", "",
  )
  let core = @test_support.number_result(snapshot, "session").to_int()
  let ui = open(snapshot)
  ignore(frame(ui, 1040, 700))
  ignore(activate_event(ui, "project-speed"))
  ignore(key_event(ui, "Home"))
  let row = node(ui, "clip-rate-0.5", 1040, 700)
  assert_true(boolean(row, "enabled") && boolean(row, "focused"))
  ignore(project_apply(ui, core, key_event(ui, "Enter")))
  assert_eq(sessions[ui].snapshot.output_duration, 24000)
  assert_eq(project_clips(sessions[ui], "video")[0].duration, 2160000)
  close(ui)
  @project_core.close(core)
}
