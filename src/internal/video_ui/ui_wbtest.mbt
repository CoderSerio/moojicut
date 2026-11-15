///|
fn fixture() -> (Int32, Int32, String) raise {
  let snapshot = @video.video_open(
    "{\"durationMs\":10000,\"width\":1920,\"height\":1080,\"hasAudio\":true}", "",
  )
  let core = @test_support.number_result(snapshot, "session").to_int()
  let ui = open(snapshot)
  assert_true(ui >= 0)
  ignore(@test_support.model_test_result(frame(ui, 1000, 700)))
  (ui, core, snapshot)
}

///|
fn fields(text : String) -> Map[String, Json] raise {
  match @json.parse(text) {
    Object(m) => m
    _ => abort("expected object")
  }
}

///|
fn effects(text : String) -> Array[Json] raise {
  let result = @test_support.model_test_result(text)
  @test_support.model_test_items(
    @test_support.model_test_field(result, "effects"),
  )
}

///|
fn effect_kind(effect : Json) -> String {
  match effect {
    Object({ "type": String(t), .. }) => t
    _ => ""
  }
}

///|
fn command_effects(text : String) -> Array[Json] raise {
  effects(text).filter(e => effect_kind(e) == "command")
}

///|
fn node(
  ui : Int32,
  id : String,
  width : Double,
  height : Double,
) -> Map[String, Json] raise {
  let result = @test_support.model_test_result(frame(ui, width, height))
  let items = @test_support.model_test_items(
    @test_support.model_test_field(result, "semantics"),
  )
  for item in items {
    match item {
      Object(m) if m.get("id") == Some(Json(id)) => return m
      _ => ()
    }
  }
  abort("missing semantics " + id)
}

///|
fn point_event(ui : Int32, kind : String, x : Double, y : Double) -> String {
  event(
    ui,
    Json::object({ "type": Json(kind), "x": Json(x), "y": Json(y) }).stringify(),
  )
}

///|
fn sync(ui : Int32, snapshot : String) -> String raise {
  event(
    ui,
    Json::object({ "type": Json("snapshot"), "snapshot": @json.parse(snapshot) }).stringify(),
  )
}

///|
fn apply_effect(core : Int32, effect : Json) -> String {
  match effect {
    Object({ "command": command, .. }) =>
      @video.video_command(core, command.stringify())
    _ => abort("missing command")
  }
}

///|
test "real trim gesture previews outside committed range and commits exactly once into core history" {
  let (ui, core, _) = fixture()
  let trimmed = @video.video_command(
    core, "{\"type\":\"trim\",\"trim\":{\"startMs\":2000,\"endMs\":8000}}",
  )
  ignore(sync(ui, trimmed))
  let start = node(ui, "trim-start", 1000, 700)
  let timeline = node(ui, "playhead", 1000, 700)
  let x = number(start, "x") + number(start, "width") / 2
  let y = number(start, "y") + 20
  let target = number(timeline, "x") + number(timeline, "width") * 0.1
  let down = point_event(ui, "pointerDown", x, y)
  assert_true(boolean(fields(down), "capture"))
  assert_eq(command_effects(down).length(), 0)
  let moved = point_event(ui, "pointerMove", target, y)
  assert_eq(command_effects(moved).length(), 0)
  assert_true(
    effects(moved).any(e => {
      e
      is Object(
        {
          "type": String("seek"),
          "sourceMs": Number(1000, ..),
          "preview": True,
          ..
        }
      )
    }),
  )
  assert_eq(@video.video_snapshot(core), trimmed)
  let up = point_event(ui, "pointerUp", target, y)
  assert_true(!boolean(fields(up), "capture"))
  let commits = command_effects(up)
  assert_eq(commits.length(), 1)
  let next = apply_effect(core, commits[0])
  ignore(sync(ui, next))
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 1000)
  assert_eq(
    command_effects(point_event(ui, "pointerUp", target, y)).length(),
    0,
  )
  // A single undo restores the exact previous trim, not one entry per move.
  let undone = @video.video_command(core, "{\"type\":\"undo\"}")
  ignore(sync(ui, undone))
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 2000)
  close(ui)
  @video.video_dispose(core)
}

///|
test "cancel restores source preview and late pointerUp cannot edit" {
  let (ui, core, original) = fixture()
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":3500,\"playing\":true}"),
  )
  let end = node(ui, "trim-end", 1000, 700)
  let x = number(end, "x") + 10
  let y = number(end, "y") + 20
  let down = point_event(ui, "pointerDown", x, y)
  assert_true(
    effects(down).any(e => {
      e is Object({ "type": String("play"), "playing": False, .. })
    }),
  )
  ignore(point_event(ui, "pointerMove", x - 240, y))
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":9000,\"playing\":true}"),
  )
  let canceled = event(ui, "{\"type\":\"cancel\"}")
  assert_true(
    effects(canceled).any(e => {
      e
      is Object(
        { "type": String("restorePreview"), "sourceMs": Number(3500, ..), .. }
      )
    }),
  )
  assert_eq(command_effects(canceled).length(), 0)
  assert_eq(number(node(ui, "trim-end", 1000, 700), "value"), 10000)
  assert_eq(number(node(ui, "playhead", 1000, 700), "value"), 3500)
  assert_eq(
    command_effects(point_event(ui, "pointerUp", x - 240, y)).length(),
    0,
  )
  assert_eq(@video.video_snapshot(core), original)
  close(ui)
  @video.video_dispose(core)
}

///|
test "authoritative snapshot interrupts gesture while malformed input leaves it intact" {
  let (ui, core, _) = fixture()
  let start = node(ui, "trim-start", 1000, 700)
  let x = number(start, "x") + 10
  let y = number(start, "y") + 20
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", x + 100, y))
  @test_support.expect_error(
    event(ui, "{\"type\":\"snapshot\",\"snapshot\":{\"ok\":true}}"),
    "invalid_input",
  )
  assert_eq(sessions[ui].gesture, "trim-start")
  let next = @video.video_command(
    core, "{\"type\":\"trim\",\"trim\":{\"startMs\":2000,\"endMs\":8000}}",
  )
  let updated = sync(ui, next)
  assert_true(!boolean(fields(updated), "capture"))
  assert_true(effects(updated).any(e => effect_kind(e) == "restorePreview"))
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 2000)
  assert_eq(
    command_effects(point_event(ui, "pointerUp", x + 100, y)).length(),
    0,
  )
  close(ui)
  @video.video_dispose(core)
}

///|
test "keyboard and semantic activation use shared focus and real undo reducer" {
  let (ui, core, _) = fixture()
  assert_eq(
    effects(event(ui, "{\"type\":\"activate\",\"id\":\"undo\"}")).length(),
    0,
  )
  ignore(event(ui, "{\"type\":\"activate\",\"id\":\"trim-start\"}"))
  let changed = event(
    ui, "{\"type\":\"key\",\"key\":\"ArrowRight\",\"mod\":false,\"shift\":false}",
  )
  let commands = command_effects(changed)
  assert_eq(commands.length(), 1)
  ignore(sync(ui, apply_effect(core, commands[0])))
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 33)
  assert_true(boolean(node(ui, "trim-start", 1000, 700), "focused"))
  ignore(
    event(
      ui, "{\"type\":\"key\",\"key\":\"Tab\",\"mod\":false,\"shift\":false}",
    ),
  )
  assert_true(boolean(node(ui, "trim-end", 1000, 700), "focused"))
  let undo = command_effects(
    event(ui, "{\"type\":\"key\",\"key\":\"z\",\"mod\":true,\"shift\":false}"),
  )
  assert_eq(undo.length(), 1)
  ignore(sync(ui, apply_effect(core, undo[0])))
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 0)
  let redo = command_effects(
    event(ui, "{\"type\":\"key\",\"key\":\"z\",\"mod\":true,\"shift\":true}"),
  )
  ignore(sync(ui, apply_effect(core, redo[0])))
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 33)
  let play = event(
    ui, "{\"type\":\"key\",\"key\":\"Space\",\"mod\":false,\"shift\":false}",
  )
  assert_true(
    effects(play).any(e => {
      e is Object({ "type": String("play"), "playing": True, .. })
    }),
  )
  close(ui)
  @video.video_dispose(core)
}

///|
test "export is gated until completion and pointer buttons activate only on release inside" {
  let (ui, core, _) = fixture()
  let button = node(ui, "export", 1000, 700)
  let x = number(button, "x") + 30
  let y = number(button, "y") + 18
  assert_eq(effects(point_event(ui, "pointerDown", x, y)).length(), 0)
  assert_eq(effects(point_event(ui, "pointerUp", 10, 10)).length(), 0)
  ignore(point_event(ui, "pointerDown", x, y))
  assert_true(
    effects(point_event(ui, "pointerUp", x, y)).any(e => {
      effect_kind(e) == "export"
    }),
  )
  assert_true(!boolean(node(ui, "export", 1000, 700), "enabled"))
  assert_eq(
    effects(event(ui, "{\"type\":\"activate\",\"id\":\"export\"}")).length(),
    0,
  )
  ignore(
    event(
      ui, "{\"type\":\"exportStatus\",\"busy\":false,\"message\":\"保存失败\",\"error\":true}",
    ),
  )
  assert_true(boolean(node(ui, "export", 1000, 700), "enabled"))
  assert_eq(sessions[ui].message, "保存失败")
  close(ui)
  @video.video_dispose(core)
}

///|
fn bounded_rect(
  m : Map[String, Json],
  width : Double,
  height : Double,
) -> Unit raise {
  let x = number(m, "x")
  let y = number(m, "y")
  let w = number(m, "width")
  let h = number(m, "height")
  assert_true(x >= -0.000001 && y >= -0.000001 && w >= 0 && h >= 0)
  assert_true(x + w <= width + 0.000001 && y + h <= height + 0.000001)
}

///|
test "render commands semantics video and scaled hit remain within viewport" {
  let (ui, core, _) = fixture()
  for
    (width, height) in [
      (720.0, 480.0),
      (1000.0, 700.0),
      (360.0, 240.0),
      (100.0, 80.0),
      (64.0, 1.0),
      (1.0, 64.0),
      (1.0, 1.0),
    ] {
    let result = fields(frame(ui, width, height))
    bounded_rect(@protocol.object_field(result, "videoRect"), width, height)
    for key in ["commands", "semantics"] {
      let items = @test_support.model_test_items(result[key])
      for item in items {
        match item {
          Object(m) if m.get("type") == Some(Json("line")) =>
            for (xkey, ykey) in [("x1", "y1"), ("x2", "y2")] {
              assert_true(number(m, xkey) >= 0 && number(m, xkey) <= width)
              assert_true(number(m, ykey) >= 0 && number(m, ykey) <= height)
            }
          Object(m) => bounded_rect(m, width, height)
          _ => abort("unexpected draw command")
        }
      }
    }
  }
  let play = node(ui, "play", 360, 240)
  let x = number(play, "x") + number(play, "width") / 2
  let y = number(play, "y") + number(play, "height") / 2
  ignore(point_event(ui, "pointerDown", x, y))
  assert_true(
    effects(point_event(ui, "pointerUp", x, y)).any(e => {
      effect_kind(e) == "play"
    }),
  )
  close(ui)
  @video.video_dispose(core)
}

///|
test "invalid snapshot closed handles and one millisecond sources are safe" {
  assert_eq(open("{\"ok\":false}"), -1)
  assert_eq(open("{}"), -1)
  let snapshot = @video.video_open(
    "{\"durationMs\":1,\"width\":2,\"height\":2,\"hasAudio\":false}", "",
  )
  let core = @test_support.number_result(snapshot, "session").to_int()
  let ui = open(snapshot)
  @test_support.expect_error(
    point_event(ui, "pointerDown", 5, 5),
    "missing_viewport",
  )
  ignore(@test_support.model_test_result(frame(ui, 720, 480)))
  ignore(event(ui, "{\"type\":\"activate\",\"id\":\"trim-end\"}"))
  assert_eq(
    command_effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"ArrowLeft\",\"mod\":false,\"shift\":true}",
      ),
    ).length(),
    0,
  )
  @test_support.expect_error(frame(ui, 0.0 / 0.0, 480), "invalid_viewport")
  close(ui)
  @test_support.expect_error(frame(ui, 720, 480), "unknown_session")
  @test_support.expect_error(
    event(ui, "{\"type\":\"cancel\"}"),
    "unknown_session",
  )
  @video.video_dispose(core)
}

///|
test "export busy freezes document edits but still allows transport" {
  let (ui, core, _) = fixture()
  ignore(
    sync(
      ui,
      @video.video_command(
        core, "{\"type\":\"trim\",\"trim\":{\"startMs\":1000,\"endMs\":9000}}",
      ),
    ),
  )
  ignore(event(ui, "{\"type\":\"activate\",\"id\":\"trim-start\"}"))
  ignore(
    event(
      ui, "{\"type\":\"exportStatus\",\"busy\":true,\"message\":\"保存中\",\"error\":false}",
    ),
  )
  for target in ["undo", "redo", "trim-start", "trim-end", "export"] {
    assert_true(!boolean(node(ui, target, 1000, 700), "enabled"))
  }
  assert_eq(
    command_effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"ArrowRight\",\"mod\":false,\"shift\":false}",
      ),
    ).length(),
    0,
  )
  assert_eq(
    command_effects(
      event(ui, "{\"type\":\"key\",\"key\":\"z\",\"mod\":true,\"shift\":false}"),
    ).length(),
    0,
  )
  assert_eq(
    command_effects(event(ui, "{\"type\":\"activate\",\"id\":\"undo\"}")).length(),
    0,
  )
  let start = node(ui, "trim-start", 1000, 700)
  let x = number(start, "x") + 10
  let y = number(start, "y") + 20
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", x + 80, y))
  assert_eq(
    command_effects(point_event(ui, "pointerUp", x + 80, y)).length(),
    0,
  )
  assert_true(
    effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"Space\",\"mod\":false,\"shift\":false}",
      ),
    ).any(e => effect_kind(e) == "play"),
  )
  close(ui)
  @video.video_dispose(core)
}

///|
test "short duration rendered ruler keeps unique subsecond labels" {
  let snapshot = @video.video_open(
    "{\"durationMs\":4000,\"width\":1920,\"height\":1080,\"hasAudio\":false}", "",
  )
  let core = @test_support.number_result(snapshot, "session").to_int()
  let ui = open(snapshot)
  let rendered = fields(frame(ui, 720, 480))
  let labels : Array[String] = []
  for value in @test_support.model_test_items(rendered["commands"]) {
    match value {
      Object(
        {
          "type": String("text"),
          "size": Number(10, ..),
          "text": String(label),
          ..
        }
      ) => {
        assert_true(!labels.contains(label))
        labels.push(label)
      }
      _ => ()
    }
  }
  assert_true(labels.contains("0.5s") && labels.contains("4.0s"))
  close(ui)
  @video.video_dispose(core)
}

///|
test "core rejection of a trim fully covered by cuts restores authoritative UI and history" {
  let (ui, core, _) = fixture()
  let original = @video.video_command(
    core, "{\"type\":\"cut\",\"cut\":{\"startMs\":0,\"endMs\":5000}}",
  )
  ignore(sync(ui, original))
  let end = node(ui, "trim-end", 1000, 700)
  let timeline = node(ui, "playhead", 1000, 700)
  let x = number(end, "x") + 10
  let y = number(end, "y") + 20
  let target = number(timeline, "x") + number(timeline, "width") * 0.3
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", target, y))
  let commits = command_effects(point_event(ui, "pointerUp", target, y))
  assert_eq(commits.length(), 1)
  @test_support.expect_error(apply_effect(core, commits[0]), "empty_output")
  ignore(
    event(ui, "{\"type\":\"error\",\"message\":\"至少保留一段内容\"}"),
  )
  ignore(sync(ui, @video.video_snapshot(core)))
  assert_eq(number(node(ui, "trim-end", 1000, 700), "value"), 10000)
  assert_eq(@video.video_snapshot(core), original)
  assert_eq(sessions[ui].message, "至少保留一段内容")
  close(ui)
  @video.video_dispose(core)
}

///|
test "media failure clears capture without restore recursion and gates media until host recovery" {
  let (ui, core, _) = fixture()
  let snapshot = @video.video_command(
    core, "{\"type\":\"trim\",\"trim\":{\"startMs\":1000,\"endMs\":9000}}",
  )
  ignore(sync(ui, snapshot))
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":4000,\"playing\":true}"),
  )
  let start = node(ui, "trim-start", 1000, 700)
  let x = number(start, "x") + 10
  let y = number(start, "y") + 20
  ignore(point_event(ui, "pointerDown", x, y))
  ignore(point_event(ui, "pointerMove", x + 100, y))
  let failed = event(
    ui, "{\"type\":\"mediaStatus\",\"ready\":false,\"message\":\"媒体计划无法加载\"}",
  )
  assert_true(!boolean(fields(failed), "capture"))
  assert_eq(effects(failed).length(), 0)
  assert_true(!sessions[ui].playing)
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 1000)
  for target in ["play", "playhead", "trim-start", "trim-end", "export"] {
    assert_true(!boolean(node(ui, target, 1000, 700), "enabled"))
    assert_eq(
      effects(
        event(
          ui,
          Json::object({ "type": Json("activate"), "id": Json(target) }).stringify(),
        ),
      ).length(),
      0,
    )
  }
  // Trim was focused when failure arrived; neither its keys nor stale mouseUp
  // may commit a document change or request media from the invalid plan.
  assert_eq(
    effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"ArrowRight\",\"mod\":false,\"shift\":false}",
      ),
    ).length(),
    0,
  )
  assert_eq(effects(point_event(ui, "pointerUp", x + 100, y)).length(), 0)
  assert_eq(
    effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"Space\",\"mod\":false,\"shift\":false}",
      ),
    ).length(),
    0,
  )
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":8000,\"playing\":true}"),
  )
  assert_true(!sessions[ui].playing)
  assert_true(boolean(node(ui, "undo", 1000, 700), "enabled"))
  let undo = command_effects(
    event(ui, "{\"type\":\"activate\",\"id\":\"undo\"}"),
  )
  assert_eq(undo.length(), 1)
  ignore(sync(ui, apply_effect(core, undo[0])))
  assert_true(!boolean(node(ui, "play", 1000, 700), "enabled"))
  // Focus is now on undo: ordinary keyboard seek must also be blocked.
  assert_eq(
    effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"ArrowRight\",\"mod\":false,\"shift\":false}",
      ),
    ).length(),
    0,
  )
  ignore(
    event(ui, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
  )
  for target in ["play", "playhead", "trim-start", "trim-end", "export", "redo"] {
    assert_true(boolean(node(ui, target, 1000, 700), "enabled"))
  }
  assert_true(
    effects(
      event(
        ui, "{\"type\":\"key\",\"key\":\"ArrowRight\",\"mod\":false,\"shift\":false}",
      ),
    ).any(e => effect_kind(e) == "seek"),
  )
  ignore(
    event(
      ui, "{\"type\":\"exportStatus\",\"busy\":true,\"message\":\"保存中\",\"error\":false}",
    ),
  )
  ignore(
    event(ui, "{\"type\":\"mediaStatus\",\"ready\":true,\"message\":\"\"}"),
  )
  assert_true(!boolean(node(ui, "export", 1000, 700), "enabled"))
  assert_true(!boolean(node(ui, "trim-start", 1000, 700), "enabled"))
  close(ui)
  @video.video_dispose(core)
}

///|
test "replay seeks before play at retained end with leading and trailing cuts" {
  let (ui, core, _) = fixture()
  ignore(
    @video.video_command(
      core, "{\"type\":\"trim\",\"trim\":{\"startMs\":500,\"endMs\":9500}}",
    ),
  )
  ignore(
    @video.video_command(
      core, "{\"type\":\"cut\",\"cut\":{\"startMs\":0,\"endMs\":1000}}",
    ),
  )
  let snapshot = @video.video_command(
    core, "{\"type\":\"cut\",\"cut\":{\"startMs\":8000,\"endMs\":10000}}",
  )
  ignore(sync(ui, snapshot))
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":7999,\"playing\":false}"),
  )
  let replay = effects(event(ui, "{\"type\":\"activate\",\"id\":\"play\"}"))
  assert_eq(replay.length(), 2)
  assert_true(
    replay[0]
    is Object(
      {
        "type": String("seek"),
        "sourceMs": Number(500, ..),
        "preview": False,
        ..
      }
    ),
  )
  assert_true(
    replay[1] is Object({ "type": String("play"), "playing": True, .. }),
  )
  // The media host uses the existing core seek rule to skip the leading cut.
  assert_eq(
    @test_support.number_result(@video.video_seek(core, 500), "sourceMs"),
    1000,
  )
  assert_eq(number(node(ui, "trim-start", 1000, 700), "value"), 500)
  assert_eq(number(node(ui, "trim-end", 1000, 700), "value"), 9500)
  assert_eq(@video.video_snapshot(core), snapshot)
  // Pausing at the end does not rewind, and resuming before it does not either.
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":7999,\"playing\":true}"),
  )
  let paused = effects(event(ui, "{\"type\":\"activate\",\"id\":\"play\"}"))
  assert_eq(paused.length(), 1)
  assert_true(
    paused[0] is Object({ "type": String("play"), "playing": False, .. }),
  )
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":7000,\"playing\":false}"),
  )
  let resumed = effects(
    event(
      ui, "{\"type\":\"key\",\"key\":\"Space\",\"mod\":false,\"shift\":false}",
    ),
  )
  assert_eq(resumed.length(), 1)
  assert_true(
    resumed[0] is Object({ "type": String("play"), "playing": True, .. }),
  )
  close(ui)
  @video.video_dispose(core)
}

///|
fn commands_without_colors(rendered : Map[String, Json]) -> Json {
  let commands : Array[Json] = []
  for value in @test_support.model_test_items(rendered["commands"]) {
    match value {
      Object(m) => {
        let copy = m.copy()
        for key in ["fill", "stroke", "color"] {
          copy.remove(key)
        }
        commands.push(Json::object(copy))
      }
      _ => abort("expected draw command")
    }
  }
  Json::array(commands)
}

///|
fn neutral_drawing_colors(rendered : Map[String, Json]) -> Array[String] raise {
  let colors : Array[String] = []
  for value in @test_support.model_test_items(rendered["commands"]) {
    match value {
      Object(m) =>
        for key in ["fill", "stroke", "color"] {
          match m.get(key) {
            Some(String(color)) => {
              assert_eq(color.length(), 7)
              assert_true(
                color[0] == '#' &&
                color[1] == color[3] &&
                color[3] == color[5] &&
                color[2] == color[4] &&
                color[4] == color[6],
              )
              colors.push(color)
            }
            None => ()
            _ => abort("invalid draw color")
          }
        }
      _ => abort("expected draw command")
    }
  }
  colors
}

///|
test "appearance changes neutral drawing colors without changing active gesture or edit effects" {
  let (ui, core, snapshot) = fixture()
  let control_ui = open(snapshot)
  let start = node(ui, "trim-start", 1000, 700)
  ignore(frame(control_ui, 1000, 700))
  let x = number(start, "x") + 10
  let y = number(start, "y") + 20
  for id in [ui, control_ui] {
    ignore(point_event(id, "pointerDown", x, y))
    ignore(point_event(id, "pointerMove", x + 120, y))
  }
  let dark = fields(frame(ui, 1000, 700))
  let themed = event(ui, "{\"type\":\"appearance\",\"mode\":\"light\"}")
  assert_eq(effects(themed).length(), 0)
  assert_true(boolean(fields(themed), "capture"))
  let light = fields(frame(ui, 1000, 700))
  assert_true(neutral_drawing_colors(dark) != neutral_drawing_colors(light))
  assert_true(commands_without_colors(dark) == commands_without_colors(light))
  assert_true(dark["videoRect"] == light["videoRect"])
  assert_true(dark["semantics"] == light["semantics"])
  assert_eq(@video.video_snapshot(core), snapshot)
  @test_support.expect_error(
    event(ui, "{\"type\":\"appearance\",\"mode\":\"blue\"}"),
    "invalid_appearance",
  )
  assert_true(fields(frame(ui, 1000, 700))["commands"] == light["commands"])
  let committed = point_event(ui, "pointerUp", x + 120, y)
  let unchanged = point_event(control_ui, "pointerUp", x + 120, y)
  @test_support.expect_json(committed, unchanged)
  assert_eq(command_effects(committed).length(), 1)
  ignore(
    @test_support.model_test_result(
      apply_effect(core, command_effects(committed)[0]),
    ),
  )
  assert_true(
    effects(event(ui, "{\"type\":\"appearance\",\"mode\":\"dark\"}")).is_empty(),
  )
  close(ui)
  close(control_ui)
  @video.video_dispose(core)
}
