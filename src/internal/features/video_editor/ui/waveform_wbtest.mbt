///|
test "waveform validates source envelope without editing the project and keeps transients" {
  let (ui, core) = project_fixture()
  let before = @project_core.snapshot(core)
  let result = event(
    ui, "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[0,0.2,0,0.9,0,0]}",
  )
  assert_eq(effects(result).length(), 0)
  assert_eq(@project_core.snapshot(core), before)
  let wave = sessions[ui].waveform.unwrap()
  assert_eq(waveform_peak(wave, 0, 2000), 0)
  assert_eq(waveform_peak(wave, 0, 12000), 0.9)
  assert_eq(waveform_peak(wave, 8000, 12000), 0)
  assert_eq(waveform_peak(wave, -100, 3000), 0.2)
  assert_eq(waveform_peak(wave, 12000, 13000), 0)
  for
    bad in [
      "{\"type\":\"waveform\",\"durationMs\":1000,\"peaks\":[0.5]}", "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[-0.1]}",
      "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[1.1]}",
    ] {
    assert_false(boolean(fields(event(ui, bad)), "ok"))
    assert_eq(waveform_peak(sessions[ui].waveform.unwrap(), 0, 12000), 0.9)
  }
  ignore(event(ui, "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[]}"))
  let s = sessions[ui]
  let audio = project_clips(s, "audio")[0]
  let commands : Array[Json] = []
  let r = project_clip_rect(s, audio)
  project_draw_visible_waveform(commands, s, audio, r, [(r.x, r.x + r.width)])
  assert_eq(commands.length(), 0) // Unavailable audio must not look like silence.
  assert_true(control_label(s, "clip:\{audio.id}").contains("波形不可用"))
  close(ui)
  @project_core.close(core)
}

///|
test "waveform follows split speed offset and zoom using source time" {
  let (ui, core) = project_fixture()
  ignore(
    event(
      ui, "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[0,0,0.8,0,0.2,0]}",
    ),
  )
  project_clock(ui, 4000)
  ignore(project_apply(ui, core, activate_event(ui, "project-split")))
  let s = sessions[ui]
  let second = project_clips(s, "audio")[1]
  assert_eq(
    project_waveform_peak(
      s,
      second,
      project_x(s, 4000 * 90),
      project_x(s, 5000 * 90),
    ),
    0.8,
  )
  // The same source excerpt played at 2x, moved later on the timeline.
  let edited : ProjectClip = {
    ..second,
    start: 6000 * 90,
    duration: second.duration / 2,
  }
  assert_eq(
    project_waveform_peak(
      s,
      edited,
      project_x(s, 6000 * 90),
      project_x(s, 6500 * 90),
    ),
    0.8,
  )
  assert_eq(
    project_waveform_peak(
      s,
      edited,
      project_x(s, 8000 * 90),
      project_x(s, 8500 * 90),
    ),
    0.2,
  )
  s.viewport_fit = false
  s.viewport_start = 7500
  s.viewport_span = 2000
  assert_eq(
    project_waveform_peak(
      s,
      edited,
      project_x(s, 8000 * 90),
      project_x(s, 8500 * 90),
    ),
    0.2,
  )
  assert_eq(
    project_waveform_peak(
      s,
      edited,
      project_x(s, 9000 * 90),
      project_x(s, 9400 * 90),
    ),
    0,
  )
  close(ui)
  @project_core.close(core)
}

///|
test "later opaque audio clips suppress only hidden waveform columns without shifting visible peaks" {
  let (ui, core) = project_fixture()
  ignore(
    event(
      ui, "{\"type\":\"waveform\",\"durationMs\":12000,\"peaks\":[0.1,0.8,0.3,1,0.2,0.6]}",
    ),
  )
  let s = sessions[ui]
  let original = project_clips(s, "audio")[0]
  let later : ProjectClip = {
    ..original,
    id: "a2",
    start: 360000,
    duration: 360000,
  }
  let r = project_clip_rect(s, original)
  let occluder = project_clip_rect(s, later)
  let spans = project_waveform_spans(s, [original, later])
  assert_eq(spans[original.id].length(), 2)
  let full : Array[Json] = []
  let culled : Array[Json] = []
  project_draw_visible_waveform(full, s, original, r, [(r.x, r.x + r.width)])
  project_draw_visible_waveform(culled, s, original, r, spans[original.id])
  assert_true(culled.length() > 0 && culled.length() < full.length())
  let expected = full.filter(command => {
    let x = match command {
      Object(fields) => number(fields, "x1") catch { _ => -1 }
      _ => -1
    }
    x < (occluder.x + 4) * s.scale ||
    x >= (occluder.x + occluder.width - 4) * s.scale
  })
  assert_eq(culled, expected)
  let later_full : Array[Json] = []
  let later_visible : Array[Json] = []
  project_draw_visible_waveform(later_full, s, later, occluder, [
    (occluder.x, occluder.x + occluder.width),
  ])
  project_draw_visible_waveform(
    later_visible,
    s,
    later,
    occluder,
    spans[later.id],
  )
  assert_eq(later_visible, later_full)
  close(ui)
  @project_core.close(core)
}
