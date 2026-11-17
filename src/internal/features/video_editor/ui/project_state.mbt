// V2 project metadata is an authoritative snapshot. Selection, track expansion,
// menus and trim candidates below are UI state only, never a second document.

///|
priv struct ProjectClip {
  id : String
  kind : String
  source_start : Double
  source_end : Double
  start : Double
  duration : Double
  link_group : String
}

///|
priv struct Project {
  revision : Double
  source_duration : Double
  clips : Array[ProjectClip]
  crop : Rect?
  muted : Bool
  has_audio : Bool
}

///|
fn is_project(s : UI) -> Bool {
  s.snapshot.project is Some(_)
}

///|
fn project(s : UI) -> Project {
  match s.snapshot.project {
    Some(p) => p
    None => abort("expected project UI")
  }
}

///|
fn project_clips(s : UI, kind : String) -> Array[ProjectClip] {
  let clips = project(s).clips.filter(c => c.kind == kind)
  clips.sort_by_key(c => c.start)
  clips
}

///|
fn project_clip(s : UI, id : String) -> ProjectClip? {
  for c in project(s).clips {
    if c.id == id {
      return Some(c)
    }
  }
  None
}

///|
fn project_selected(s : UI) -> ProjectClip? {
  if s.selected_gap != "" {
    None
  } else {
    project_clip(s, s.selected_clip)
  }
}

///|
fn project_select(s : UI, id : String) -> Unit {
  match project_clip(s, id) {
    Some(c) => {
      s.selected_gap = ""
      s.selected_clip = c.id
      s.clip_trim_start = c.source_start
      s.clip_trim_end = c.source_end
    }
    None => ()
  }
}

///|
fn project_sync_selection(s : UI) -> Unit {
  if !is_project(s) {
    return
  }
  project_viewport_sync(s)
  if project_gap_target(s, s.selected_gap) is Some(_) {
    return
  }
  s.selected_gap = ""
  if project_selected(s) is None {
    let clips = project_clips(s, "video")
    s.selected_clip = clips[0].id
  }
  project_select(s, s.selected_clip)
}

///|
fn decode_project_snapshot(
  m : Map[String, Json],
  document : Map[String, Json],
) -> Snapshot raise @protocol.InputError {
  ignore(@protocol.integer_field(document, "timebase", 90000, 90000))
  let revision = @protocol.integer_field(m, "revision", 0, 9007199254740991)
  let source = @protocol.object_field(document, "source")
  let source_ms = @protocol.integer_field(source, "durationMs", 1, 604800000)
  let source_width = @protocol.integer_field(source, "width", 2, 32768)
  let source_height = @protocol.integer_field(source, "height", 2, 32768)
  let plan = @protocol.object_field(m, "plan")
  ignore(@protocol.integer_field(plan, "timebase", 90000, 90000))
  let duration_ticks = @protocol.integer_field(
    plan, "outputDurationTicks", 3000, 54432000000,
  )
  let clips : Array[ProjectClip] = []
  let ids : Map[String, Bool] = Map([])
  let mut video_count = 0
  match document.get("clips") {
    Some(Array(items)) if !items.is_empty() && items.length() <= 4096 =>
      for item in items {
        match item {
          Object(c) => {
            let id = string(c, "id")
            let kind = string(c, "kind")
            let source_start = @protocol.integer_field(
              c,
              "sourceStartTicks",
              0,
              source_ms * 90,
            )
            let source_end = @protocol.integer_field(
              c,
              "sourceEndTicks",
              source_start + 1,
              source_ms * 90,
            )
            let start = @protocol.integer_field(
              c, "startTicks", 0, duration_ticks,
            )
            let duration = @protocol.integer_field(
              c, "durationTicks", 3000, duration_ticks,
            )
            let link_group = match c.get("linkGroup") {
              Some(Null) => ""
              Some(String(group)) => group
              _ =>
                raise @protocol.InputError(
                  "invalid_snapshot", "Invalid clip link group",
                )
            }
            if id == "" ||
              ids.contains(id) ||
              (kind != "video" && kind != "audio") ||
              start + duration > duration_ticks {
              raise @protocol.InputError(
                "invalid_snapshot", "Invalid project clip",
              )
            }
            ids[id] = true
            if kind == "video" {
              video_count = video_count + 1
            }
            clips.push({
              id,
              kind,
              source_start,
              source_end,
              start,
              duration,
              link_group,
            })
          }
          _ =>
            raise @protocol.InputError(
              "invalid_snapshot", "Invalid project clip",
            )
        }
      }
    _ => raise @protocol.InputError("invalid_snapshot", "Missing project clips")
  }
  if video_count == 0 {
    raise @protocol.InputError("invalid_snapshot", "Project needs a video clip")
  }
  let duration = duration_ticks / 90
  let crop = match document.get("crop") {
    Some(Object(c)) =>
      Some({
        x: @protocol.integer_field(c, "x", 0, source_width - 2),
        y: @protocol.integer_field(c, "y", 0, source_height - 2),
        width: @protocol.integer_field(c, "width", 2, source_width),
        height: @protocol.integer_field(c, "height", 2, source_height),
      })
    Some(Null) => None
    _ => raise @protocol.InputError("invalid_snapshot", "Invalid crop")
  }
  if crop is Some(c) &&
    (c.x + c.width > source_width || c.y + c.height > source_height) {
    raise @protocol.InputError("invalid_snapshot", "Crop exceeds source bounds")
  }
  {
    duration,
    source_width,
    source_height,
    start: 0,
    end: duration,
    cuts: [],
    can_undo: boolean(m, "canUndo"),
    can_redo: boolean(m, "canRedo"),
    output_duration: duration,
    retained_end: duration,
    segments: [
      {
        source_start: 0,
        source_end: duration,
        output_start: 0,
        output_end: duration,
      },
    ],
    project: Some({
      revision,
      source_duration: source_ms * 90,
      clips,
      crop,
      muted: boolean(document, "muted"),
      has_audio: boolean(source, "hasAudio"),
    }),
  }
}

///|
fn clip_rate(c : ProjectClip) -> Double {
  (c.source_end - c.source_start) / c.duration
}

///|
fn clip_rate_label(c : ProjectClip) -> String {
  let rate = clip_rate(c)
  for preset in preview_rates {
    if (rate - preset).abs() < 0.01 {
      return rate_label(preset)
    }
  }
  let hundredths = (rate * 100 + 0.5).to_int()
  "\{hundredths / 100}.\{pad2(hundredths % 100)}×"
}

///|
let clip_rate_ids : Array[String] = [
  "clip-rate-0.5", "clip-rate-1", "clip-rate-1.5", "clip-rate-2", "clip-rate-3",
]

///|
fn clip_rate_index(id : String) -> Int32 {
  for i, candidate in clip_rate_ids {
    if id == candidate {
      return i
    }
  }
  -1
}

///|
fn project_clip_target(s : UI, target : String) -> ProjectClip? {
  for c in project(s).clips {
    if target == "clip:\{c.id}" {
      return Some(c)
    }
  }
  None
}

///|
fn project_clip_label(c : ProjectClip) -> String {
  if c.id.length() > 1 {
    "片段 \{c.id[1:]}"
  } else {
    "片段"
  }
}

///|
fn ui_input_object(
  text : String,
) -> Map[String, Json] raise @protocol.InputError {
  // A supported v2 snapshot includes both document and playback plan. The
  // protocol's 64KiB command limit is too small for the core's 512 clips.
  if text.length() > 1048576 {
    raise @protocol.InputError("invalid_input", "UI input is too large")
  }
  let parsed = @json.parse(
    text,
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise @protocol.InputError("invalid_json", "Expected valid UI JSON")
  }
  match parsed {
    Object(m) => m
    _ => raise @protocol.InputError("invalid_input", "Expected UI object")
  }
}
