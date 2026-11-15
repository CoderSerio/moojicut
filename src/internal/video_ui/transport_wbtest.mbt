///|
fn activate_event(ui : Int32, id : String) -> String {
  event(
    ui,
    Json::object({ "type": Json("activate"), "id": Json(id) }).stringify(),
  )
}

///|
fn key_event(ui : Int32, key : String) -> String {
  event(
    ui,
    Json::object({
      "type": Json("key"),
      "key": Json(key),
      "mod": Json(false),
      "shift": Json(false),
    }).stringify(),
  )
}

///|
fn assert_seek(result : String, source : Double) -> Unit raise {
  let list = effects(result)
  assert_true(
    list.any(e => {
      e
      is Object(
        {
          "type": String("seek"),
          "sourceMs": Number(ms, ..),
          "preview": False,
          ..
        }
      ) &&
      ms == source
    }),
  )
  assert_eq(command_effects(result).length(), 0)
}

///|
test "transport uses edited duration for proportional jumps across cuts and preserves history" {
  let snapshot = @video.video_open(
    "{\"durationMs\":30000,\"width\":1920,\"height\":1080,\"hasAudio\":true}", "",
  )
  let core = @test_support.number_result(snapshot, "session").to_int()
  ignore(
    @video.video_command(
      core, "{\"type\":\"trim\",\"trim\":{\"startMs\":500,\"endMs\":28000}}",
    ),
  )
  for (a, b) in [(0, 2000), (7000, 11000), (18000, 21000), (26000, 30000)] {
    ignore(
      @video.video_command(
        core,
        Json::object({
          "type": Json("cut"),
          "cut": Json::object({ "startMs": Json(a), "endMs": Json(b) }),
        }).stringify(),
      ),
    )
  }
  let edited = @video.video_snapshot(core)
  let ui = open(edited)
  ignore(frame(ui, 720, 480))
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":6900,\"playing\":true}"),
  )
  let forward = activate_event(ui, "forward")
  assert_seek(forward, 11070)
  assert_true(
    effects(forward)[0]
    is Object({ "type": String("play"), "playing": False, .. }),
  )
  assert_eq(@video.video_source_time(core, 5070), 11070)
  assert_seek(activate_event(ui, "backward"), 6900)
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":17900,\"playing\":false}"),
  )
  assert_seek(activate_event(ui, "forward"), 21070)
  ignore(
    event(ui, "{\"type\":\"playback\",\"sourceMs\":6830,\"playing\":false}"),
  )
  assert_seek(activate_event(ui, "forward"), 11000)
  assert_seek(activate_event(ui, "end"), 25999)
  assert_seek(activate_event(ui, "forward"), 25999)
  assert_seek(activate_event(ui, "start"), 2000)
  assert_seek(activate_event(ui, "forward"), 2170)
  assert_seek(activate_event(ui, "backward"), 2000)
  assert_seek(activate_event(ui, "backward"), 2000)
  assert_seek(key_event(ui, "End"), 25999)
  assert_seek(key_event(ui, "Home"), 2000)
  assert_eq(effects(key_event(ui, "j")).length(), 0)
  assert_eq(@video.video_snapshot(core), edited)
  close(ui)
  @video.video_dispose(core)
}

///|
test "shared preview menu supports keyboard selection escape and outside-click dismissal" {
  let (ui, core, snapshot) = fixture()
  assert_eq(effects(activate_event(ui, "preview-rate")).length(), 0)
  let background = node(ui, "preview-rate-menu", 1000, 700)
  assert_eq(string(background, "role"), "group")
  assert_true(!boolean(background, "enabled"))
  assert_eq(effects(activate_event(ui, "preview-rate-menu")).length(), 0)
  assert_true(sessions[ui].rate_menu)
  let first = node(ui, "rate-0.5", 1000, 700)
  assert_true(
    number(background, "x") < number(first, "x") &&
    number(background, "y") < number(first, "y"),
  )
  assert_true(boolean(node(ui, "rate-1", 1000, 700), "focused"))
  ignore(key_event(ui, "ArrowDown"))
  assert_true(boolean(node(ui, "rate-1.5", 1000, 700), "focused"))
  ignore(key_event(ui, "Escape"))
  assert_true(!sessions[ui].rate_menu)
  assert_eq(sessions[ui].preview_rate, 1)
  assert_true(boolean(node(ui, "preview-rate", 1000, 700), "focused"))
  // ArrowDown on the closed menu button opens it; Home/End select rows rather
  // than seeking media while the menu is open.
  assert_eq(effects(key_event(ui, "ArrowDown")).length(), 0)
  assert_eq(effects(key_event(ui, "End")).length(), 0)
  assert_true(boolean(node(ui, "rate-3", 1000, 700), "focused"))
  let chosen = key_event(ui, "Enter")
  assert_eq(effects(chosen).length(), 1)
  assert_true(
    effects(chosen)[0]
    is Object({ "type": String("previewRate"), "rate": Number(3, ..), .. }),
  )
  assert_eq(command_effects(chosen).length(), 0)
  assert_true(!sessions[ui].rate_menu)
  assert_eq(sessions[ui].preview_rate, 3)
  assert_eq(@video.video_snapshot(core), snapshot)
  ignore(activate_event(ui, "preview-rate"))
  let timeline = node(ui, "playhead", 1000, 700)
  let x = number(timeline, "x") + 100
  let y = number(timeline, "y") + 40
  assert_eq(effects(point_event(ui, "pointerDown", x, y)).length(), 0)
  assert_true(!sessions[ui].rate_menu)
  assert_eq(effects(point_event(ui, "pointerUp", x, y)).length(), 0)
  assert_eq(sessions[ui].preview_rate, 3)
  close(ui)
  @video.video_dispose(core)
}

///|
test "rate acknowledgement is atomic and media failure closes and disables every transport control" {
  let (ui, core, snapshot) = fixture()
  ignore(activate_event(ui, "preview-rate"))
  let row = node(ui, "rate-2", 1000, 700)
  let x = number(row, "x") + 40
  let y = number(row, "y") + number(row, "height") / 2
  ignore(point_event(ui, "pointerDown", x, y))
  let changed = point_event(ui, "pointerUp", x, y)
  assert_true(
    effects(changed)[0]
    is Object({ "type": String("previewRate"), "rate": Number(2, ..), .. }),
  )
  assert_eq(sessions[ui].preview_rate, 2)
  @test_support.expect_error(
    event(
      ui, "{\"type\":\"previewRateStatus\",\"rate\":1,\"message\":\"bad boolean\",\"error\":1}",
    ),
    "invalid_input",
  )
  assert_eq(sessions[ui].preview_rate, 2)
  assert_eq(sessions[ui].message, "")
  @test_support.expect_error(
    event(
      ui, "{\"type\":\"previewRateStatus\",\"rate\":4,\"message\":\"bad rate\",\"error\":false}",
    ),
    "invalid_rate",
  )
  assert_eq(sessions[ui].preview_rate, 2)
  ignore(
    event(
      ui, "{\"type\":\"previewRateStatus\",\"rate\":1,\"message\":\"当前媒体不支持 2 倍预览\",\"error\":true}",
    ),
  )
  assert_eq(sessions[ui].preview_rate, 1)
  assert_eq(sessions[ui].message, "当前媒体不支持 2 倍预览")
  assert_true(sessions[ui].message_error)
  ignore(activate_event(ui, "preview-rate"))
  assert_eq(
    effects(
      event(
        ui, "{\"type\":\"mediaStatus\",\"ready\":false,\"message\":\"媒体失效\"}",
      ),
    ).length(),
    0,
  )
  assert_true(!sessions[ui].rate_menu)
  for id in ["start", "backward", "play", "forward", "end", "preview-rate"] {
    assert_true(!boolean(node(ui, id, 1000, 700), "enabled"))
    assert_eq(effects(activate_event(ui, id)).length(), 0)
  }
  assert_eq(effects(activate_event(ui, "rate-3")).length(), 0)
  assert_eq(@video.video_snapshot(core), snapshot)
  close(ui)
  @video.video_dispose(core)
}

///|
fn rectangles_overlap(
  a : Map[String, Json],
  b : Map[String, Json],
) -> Bool raise {
  number(a, "x") < number(b, "x") + number(b, "width") &&
  number(a, "x") + number(a, "width") > number(b, "x") &&
  number(a, "y") < number(b, "y") + number(b, "height") &&
  number(a, "y") + number(a, "height") > number(b, "y")
}

///|
test "compact and wide transport controls menu and time labels fit both neutral themes" {
  let (ui, core, _) = fixture()
  for width in [720.0, 1040.0] {
    for mode in ["dark", "light"] {
      ignore(
        event(
          ui,
          Json::object({ "type": Json("appearance"), "mode": Json(mode) }).stringify(),
        ),
      )
      let controls : Array[Map[String, Json]] = []
      for
        id in [
          "undo", "redo", "export", "start", "backward", "play", "forward", "end",
          "preview-rate",
        ] {
        controls.push(node(ui, id, width, 480))
      }
      for i in 0..<controls.length() {
        bounded_rect(controls[i], width, 480)
        for j in (i + 1)..<controls.length() {
          assert_true(!rectangles_overlap(controls[i], controls[j]))
        }
      }
      let rendered = fields(frame(ui, width, 480))
      ignore(neutral_drawing_colors(rendered))
      let captions : Array[String] = []
      for value in @test_support.model_test_items(rendered["commands"]) {
        match value {
          Object(m) if m.get("type") == Some(Json("text")) => {
            let label = string(m, "text")
            if label.has_prefix("原片位置") ||
              label.has_prefix("成片时长") {
              captions.push(label)
              for control in controls {
                assert_true(!rectangles_overlap(m, control))
              }
            }
          }
          _ => ()
        }
      }
      assert_eq(captions.length(), 2)
      ignore(activate_event(ui, "preview-rate"))
      let menu_frame = fields(frame(ui, width, 480))
      ignore(neutral_drawing_colors(menu_frame))
      let video = @protocol.object_field(menu_frame, "videoRect")
      for id in rate_ids {
        let row = node(ui, id, width, 480)
        bounded_rect(row, width, 480)
        assert_true(!rectangles_overlap(row, video))
      }
      ignore(key_event(ui, "Escape"))
    }
  }
  close(ui)
  @video.video_dispose(core)
}

///|
test "proportional navigation covers short long and capped durations with endpoint clamps" {
  for
    (duration, step) in [(4000.0, 40.0), (180000.0, 1800.0), (600000.0, 5000.0)] {
    let snapshot = @video.video_open(
      Json::object({
        "durationMs": Json(duration),
        "width": Json(1920),
        "height": Json(1080),
        "hasAudio": Json(false),
      }).stringify(),
      "",
    )
    let core = @test_support.number_result(snapshot, "session").to_int()
    let ui = open(snapshot)
    let middle = duration / 2
    ignore(
      event(
        ui,
        Json::object({
          "type": Json("playback"),
          "sourceMs": Json(middle),
          "playing": Json(false),
        }).stringify(),
      ),
    )
    assert_seek(activate_event(ui, "forward"), middle + step)
    assert_seek(activate_event(ui, "backward"), middle)
    assert_seek(activate_event(ui, "start"), 0)
    assert_seek(activate_event(ui, "backward"), 0)
    assert_seek(activate_event(ui, "forward"), step)
    assert_seek(activate_event(ui, "end"), duration - 1)
    assert_seek(activate_event(ui, "forward"), duration - 1)
    assert_seek(activate_event(ui, "backward"), duration - 1 - step)
    assert_eq(@video.video_snapshot(core), snapshot)
    close(ui)
    @video.video_dispose(core)
  }
}
