///|
fn frame_test_fields(text : String) -> Map[String, @json.Json] raise {
  match @json.parse(text) {
    Object(fields) => fields
    _ => abort("expected object")
  }
}

///|
fn frame_test_number(fields : Map[String, @json.Json], key : String) -> Double {
  match fields[key] {
    Number(n, ..) => n
    _ => abort("expected number")
  }
}

///|
test "typed frames decode actual v2 video UI including crop overlay semantics and input" {
  let opened = video_project_open(
    "{\"durationMs\":12000,\"width\":1920,\"height\":1080,\"hasAudio\":true}", "",
  )
  let core = frame_test_number(frame_test_fields(opened), "session").to_int()
  let ui = video_ui_open(opened)
  assert_true(ui >= 0)
  let raw = video_ui_frame(ui, 1040, 700)
  let frame = ui_frame_open(raw)
  assert_true(frame > 0)
  let description = frame_test_fields(raw)
  assert_true(description.contains("viewport")) // Real project UI, not legacy UI.
  let commands = match description["commands"] {
    Array(items) => items
    _ => abort("commands")
  }
  assert_eq(ui_frame_command_count(frame, 0), commands.length())
  assert_eq(ui_frame_command_count(frame, 1), 0)
  assert_eq(ui_frame_value(frame, 1), 1)
  let video = match description["videoRect"] {
    Object(fields) => fields
    _ => abort("video")
  }
  for (i, key) in [(0, "x"), (1, "y"), (2, "width"), (3, "height")] {
    assert_eq(ui_frame_video_rect(frame, i), frame_test_number(video, key))
  }
  let nodes = match description["semantics"] {
    Array(items) => items
    _ => abort("semantics")
  }
  assert_eq(ui_frame_semantic_count(frame), nodes.length())
  let mut playhead = -1
  for i, item in nodes {
    let fields = match item {
      Object(fields) => fields
      _ => abort("semantic")
    }
    let id = match fields["id"] {
      String(s) => s
      _ => abort("id")
    }
    let label = match fields["label"] {
      String(s) => s
      _ => abort("label")
    }
    assert_eq(ui_frame_semantic_text(frame, i, 0), id)
    assert_eq(ui_frame_semantic_text(frame, i, 1), label)
    assert_eq(ui_frame_semantic_text(frame, i, 2), label)
    assert_eq(
      ui_frame_semantic_value(frame, i, 1),
      if fields["enabled"] == @json.Json(true) {
        1
      } else {
        0
      },
    )
    assert_eq(
      ui_frame_semantic_value(frame, i, 2),
      if fields["focused"] == @json.Json(true) {
        1
      } else {
        0
      },
    )
    if id == "playhead" {
      playhead = i
    }
  }
  assert_true(playhead >= 0)
  assert_eq(ui_frame_semantic_value(frame, playhead, 0), 2)
  assert_eq(ui_frame_semantic_value(frame, playhead, 4), 1)
  assert_eq(ui_frame_semantic_value(frame, playhead, 5), 1)
  assert_eq(ui_frame_semantic_number(frame, playhead, 6), 11999)
  let old_commands = ui_frame_command_count(frame, 0)
  ignore(video_ui_event(ui, ui_input_event(7, 0, 0, 0, 0, 0, "project-crop")))
  let overlay = ui_frame_open(video_ui_frame(ui, 1040, 700))
  assert_true(overlay > frame)
  assert_true(ui_frame_command_count(overlay, 1) > 0)
  let mut focused = false
  for i in 0..<ui_frame_semantic_count(overlay) {
    if ui_frame_semantic_text(overlay, i, 0) == "project-crop-region" {
      assert_eq(ui_frame_semantic_value(overlay, i, 2), 1)
      focused = true
    }
  }
  assert_true(focused)
  assert_eq(ui_frame_command_count(frame, 0), old_commands)
  assert_eq(ui_frame_command_count(frame, 1), 0)
  ignore(video_ui_event(ui, ui_input_event(6, 0, 0, 0, 0, 0, "Escape")))
  ignore(video_ui_event(ui, ui_input_event(8, 0, 0, 0, 0, 0, "light")))
  let light = ui_frame_open(video_ui_frame(ui, 1280, 800))
  assert_true(light > overlay)
  assert_eq(ui_frame_command_count(light, 1), 0)
  assert_true(
    ui_frame_command_value(light, 0, 0, 1) !=
    ui_frame_command_value(frame, 0, 0, 1),
  )
  video_ui_close(ui)
  video_project_close(core)
  assert_true(ui_frame_semantic_count(frame) > 0)
  for handle in [frame, overlay, light] {
    assert_eq(ui_frame_close(handle), 1)
  }
}

///|
test "frame bounds accept maximum core clips with gaps and the widest waveform viewport" {
  let source = "{\"durationMs\":60000,\"width\":1920,\"height\":1080,\"hasAudio\":true}"
  let initial = frame_test_fields(video_project_open(source, ""))
  let initial_id = frame_test_number(initial, "session").to_int()
  let doc = match initial["document"] {
    Object(fields) => fields
    _ => abort("document")
  }
  let clips : Array[@json.Json] = []
  for i in 1..<=256 {
    for kind in ["video", "audio"] {
      clips.push(
        @json.Json::object({
          "id": @json.Json(
            (if kind == "video" { "v" } else { "a" }) + i.to_string(),
          ),
          "kind": @json.Json(kind),
          "sourceStartTicks": @json.Json(0),
          "sourceEndTicks": @json.Json(9000),
          "startTicks": @json.Json((i - 1) * 18000),
          "durationTicks": @json.Json(9000),
          "linkGroup": @json.Json("g\{i}"),
        }),
      )
    }
  }
  doc["clips"] = @json.Json::array(clips)
  doc["nextId"] = @json.Json(257)
  let snapshot = video_project_open(source, @json.Json::object(doc).stringify())
  let core = frame_test_number(frame_test_fields(snapshot), "session").to_int()
  let ui = video_ui_open(snapshot)
  assert_true(ui >= 0)
  ignore(video_ui_frame(ui, 32768, 32768))
  ignore(
    video_ui_event(ui, ui_input_event(7, 0, 0, 0, 0, 0, "project-audio-toggle")),
  )
  let peaks = Array::make(16384, @json.Json(1))
  let wave = video_ui_event(
    ui,
    @json.Json::object({
      "type": @json.Json("waveform"),
      "durationMs": @json.Json(60000),
      "peaks": @json.Json::array(peaks),
    }).stringify(),
  )
  assert_eq(frame_test_fields(wave)["ok"], @json.Json(true))
  let raw = video_ui_frame(ui, 32768, 32768)
  let f = ui_frame_open(raw)
  assert_true(f > 0)
  assert_true(ui_frame_semantic_count(f) >= 512 + 255)
  assert_true(ui_frame_command_count(f, 0) > 7000)
  println(
    "Maximum project frame: \{ui_frame_command_count(f,0)} commands, \{ui_frame_semantic_count(f)} semantics, \{raw.length()} UTF-16 units",
  )
  assert_eq(ui_frame_close(f), 1)
  video_ui_close(ui)
  video_project_close(core)
  video_project_close(initial_id)

  // All 256 audio clips may legally overlap. Only columns visible after the
  // later opaque rectangles matter, so this cannot multiply waveform work by
  // 256. Keep all 512 clip semantics and the video gaps in the same real frame.
  let overlap_clips : Array[@json.Json] = []
  for i in 1..<=256 {
    for kind in ["video", "audio"] {
      overlap_clips.push(
        @json.Json::object({
          "id": @json.Json(
            (if kind == "video" { "v" } else { "a" }) + i.to_string(),
          ),
          "kind": @json.Json(kind),
          "sourceStartTicks": @json.Json(0),
          "sourceEndTicks": @json.Json(
            if kind == "audio" {
              5400000
            } else {
              9000
            },
          ),
          "startTicks": @json.Json(
            if kind == "audio" {
              0
            } else {
              (i - 1) * 18000
            },
          ),
          "durationTicks": @json.Json(
            if kind == "audio" {
              5400000
            } else {
              9000
            },
          ),
          "linkGroup": @json.Json::null(),
        }),
      )
    }
  }
  doc["clips"] = @json.Json::array(overlap_clips)
  let snapshot = video_project_open(source, @json.Json::object(doc).stringify())
  let core = frame_test_number(frame_test_fields(snapshot), "session").to_int()
  let ui = video_ui_open(snapshot)
  assert_true(ui >= 0)
  ignore(video_ui_frame(ui, 32768, 1))
  ignore(
    video_ui_event(ui, ui_input_event(7, 0, 0, 0, 0, 0, "project-audio-toggle")),
  )
  ignore(
    video_ui_event(
      ui,
      @json.Json::object({
        "type": @json.Json("waveform"),
        "durationMs": @json.Json(60000),
        "peaks": @json.Json::array(peaks),
      }).stringify(),
    ),
  )
  let raw = video_ui_frame(ui, 32768, 1)
  let f = ui_frame_open(raw)
  assert_true(f > 0)
  assert_true(ui_frame_command_count(f, 0) < 22000)
  assert_true(ui_frame_semantic_count(f) >= 512 + 255)
  println(
    "Maximum overlapping audio frame: \{ui_frame_command_count(f,0)} commands, \{ui_frame_semantic_count(f)} semantics, \{raw.length()} UTF-16 units",
  )
  assert_eq(ui_frame_close(f), 1)
  video_ui_close(ui)
  video_project_close(core)

  // One long audio clip maximizes waveform bars because no per-clip padding
  // consumes horizontal pixels. Both are real core snapshots and UI frames.
  let snapshot = video_project_open(source, "")
  let core = frame_test_number(frame_test_fields(snapshot), "session").to_int()
  let ui = video_ui_open(snapshot)
  ignore(video_ui_frame(ui, 32768, 32768))
  ignore(
    video_ui_event(ui, ui_input_event(7, 0, 0, 0, 0, 0, "project-audio-toggle")),
  )
  ignore(
    video_ui_event(
      ui,
      @json.Json::object({
        "type": @json.Json("waveform"),
        "durationMs": @json.Json(60000),
        "peaks": @json.Json::array(peaks),
      }).stringify(),
    ),
  )
  let raw = video_ui_frame(ui, 32768, 32768)
  let f = ui_frame_open(raw)
  assert_true(f > 0)
  assert_true(ui_frame_command_count(f, 0) > 16000)
  println(
    "Maximum continuous waveform frame: \{ui_frame_command_count(f,0)} commands, \{ui_frame_semantic_count(f)} semantics, \{raw.length()} UTF-16 units",
  )
  assert_eq(ui_frame_close(f), 1)
  for (width, height) in [(32768.0, 1.0), (1.0, 32768.0)] {
    let raw = video_ui_frame(ui, width, height)
    let f = ui_frame_open(raw)
    assert_true(f > 0)
    assert_true(ui_frame_command_count(f, 0) < 20000)
    println(
      "Extreme-aspect frame \{width}x\{height}: \{ui_frame_command_count(f,0)} commands, \{raw.length()} UTF-16 units",
    )
    assert_eq(ui_frame_close(f), 1)
  }
  video_ui_close(ui)
  video_project_close(core)
}
