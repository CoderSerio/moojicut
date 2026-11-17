///|
using @json {type Json}

///|
priv struct Segment {
  source_start : Double
  source_end : Double
  output_start : Double
  output_end : Double
}

///|
priv struct Snapshot {
  duration : Double
  source_width : Double
  source_height : Double
  start : Double
  end : Double
  cuts : Array[(Double, Double)]
  can_undo : Bool
  can_redo : Bool
  output_duration : Double
  retained_end : Double
  segments : Array[Segment]
  project : Project?
}

///|
priv struct UI {
  mut snapshot : Snapshot
  mut width : Double
  mut height : Double
  mut scale : Double
  mut framed : Bool
  mut preview_start : Double
  mut preview_end : Double
  mut source_time : Double
  mut playing : Bool
  mut media_ready : Bool
  mut focus : String
  mut hover : String
  mut gesture : String
  mut saved_time : Double
  mut message : String
  mut message_error : Bool
  mut export_busy : Bool
  mut appearance : String
  mut preview_rate : Double
  mut rate_menu : Bool
  mut viewport_start : Double
  mut viewport_extent : Double
  mut viewport_span : Double
  mut viewport_fit : Bool
  mut selected_gap : String
  mut selected_clip : String
  mut audio_expanded : Bool
  mut clip_speed_menu : Bool
  mut clip_trim_start : Double
  mut clip_trim_end : Double
  mut clip_drag_x : Double
  mut clip_drag_ticks_per_pixel : Double
  mut clip_drag_active : Bool
  mut clip_move_start : Double
  mut clip_move_valid : Bool
  mut crop_mode : Bool
  mut crop_candidate : Rect
  mut crop_saved : Rect
  mut crop_anchor_x : Double
  mut crop_anchor_y : Double
  mut waveform : Waveform?
}

///|
let sessions : Map[Int32, UI] = Map([])

///|
let next_id : Ref[Int32] = Ref(0)

///|
fn clamp(v : Double, lo : Double, hi : Double) -> Double {
  @protocol.larger(lo, @protocol.smaller(hi, v))
}

///|
fn boolean(
  m : Map[String, Json],
  k : String,
) -> Bool raise @protocol.InputError {
  match m.get(k) {
    Some(True) => true
    Some(False) => false
    _ => raise @protocol.InputError("invalid_input", "\{k} must be boolean")
  }
}

///|
fn string(
  m : Map[String, Json],
  k : String,
) -> String raise @protocol.InputError {
  match m.get(k) {
    Some(String(v)) => v
    _ => raise @protocol.InputError("invalid_input", "\{k} must be text")
  }
}

///|
fn number(
  m : Map[String, Json],
  k : String,
) -> Double raise @protocol.InputError {
  match m.get(k) {
    Some(Number(v, ..)) if v > -1.0 / 0.0 && v < 1.0 / 0.0 => v
    _ => raise @protocol.InputError("invalid_input", "\{k} must be finite")
  }
}

///|
fn decode_snapshot(
  m : Map[String, Json],
) -> Snapshot raise @protocol.InputError {
  if !boolean(m, "ok") {
    raise @protocol.InputError(
      "invalid_snapshot", "Expected a successful core snapshot",
    )
  }
  let document = @protocol.object_field(m, "document")
  if document.get("schemaVersion") == Some(Json(2)) {
    return decode_project_snapshot(m, document)
  }
  let source = @protocol.object_field(document, "source")
  let duration = @protocol.integer_field(source, "durationMs", 1, 604800000)
  let source_width = @protocol.integer_field(source, "width", 2, 32768)
  let source_height = @protocol.integer_field(source, "height", 2, 32768)
  let trim = @protocol.object_field(document, "trim")
  let start = @protocol.integer_field(trim, "startMs", 0, duration)
  let end = @protocol.integer_field(trim, "endMs", 0, duration)
  // Reuse the document's actual plan validator, including merged/legacy cuts.
  let timeline = document.copy()
  timeline["durationMs"] = Json(duration)
  let plan = @protocol.request_object(
    @video.edit_plan(Json::object(timeline).stringify()),
  )
  if !boolean(plan, "ok") {
    raise @protocol.InputError("invalid_snapshot", "Invalid video editing plan")
  }
  let supplied_plan = @protocol.object_field(m, "plan")
  let output_duration = @protocol.integer_field(
    plan, "outputDurationMs", 1, duration,
  )
  if @protocol.integer_field(supplied_plan, "outputDurationMs", 1, duration) !=
    output_duration {
    raise @protocol.InputError(
      "invalid_snapshot", "Snapshot plan does not match document",
    )
  }
  let segments : Array[Segment] = []
  match plan.get("segments") {
    Some(Array(items)) if !items.is_empty() =>
      for item in items {
        match item {
          Object(segment) =>
            segments.push({
              source_start: @protocol.integer_field(
                segment, "sourceStartMs", start, end,
              ),
              source_end: @protocol.integer_field(
                segment,
                "sourceEndMs",
                start + 1,
                end,
              ),
              output_start: @protocol.integer_field(
                segment, "outputStartMs", 0, output_duration,
              ),
              output_end: @protocol.integer_field(
                segment, "outputEndMs", 1, output_duration,
              ),
            })
          _ =>
            raise @protocol.InputError(
              "invalid_snapshot", "Missing retained video segment",
            )
        }
      }
    _ =>
      raise @protocol.InputError(
        "invalid_snapshot", "Missing retained video segment",
      )
  }
  let retained_end = segments[segments.length() - 1].source_end
  // Cuts may lie outside the current trim. Ask the same reducer for the full
  // source plan so expanding a trim still shows those deleted regions.
  timeline["trim"] = Json::object({
    "startMs": Json(0),
    "endMs": Json(duration),
  })
  let full_plan = @protocol.request_object(
    @video.edit_plan(Json::object(timeline).stringify()),
  )
  let cuts : Array[(Double, Double)] = []
  let mut cursor = 0.0
  match full_plan.get("segments") {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(segment) => {
            let a = @protocol.integer_field(
              segment, "sourceStartMs", 0, duration,
            )
            let b = @protocol.integer_field(segment, "sourceEndMs", 0, duration)
            if a > cursor {
              cuts.push((cursor, a))
            }
            cursor = b
          }
          _ => ()
        }
      }
    _ => ()
  }
  if cursor < duration {
    cuts.push((cursor, duration))
  }
  {
    duration,
    source_width,
    source_height,
    start,
    end,
    cuts,
    can_undo: boolean(m, "canUndo"),
    can_redo: boolean(m, "canRedo"),
    output_duration,
    retained_end,
    segments,
    project: None,
  }
}

///|
fn session(id : Int32) -> UI raise @protocol.InputError {
  match sessions.get(id) {
    Some(s) => s
    None =>
      raise @protocol.InputError("unknown_session", "Shared editor has closed")
  }
}

///|
pub fn open(snapshot : String) -> Int32 {
  let s = decode_snapshot(ui_input_object(snapshot)) catch { _ => return -1 }
  let id = next_id.val
  next_id.val = id + 1
  sessions[id] = {
    snapshot: s,
    width: 720,
    height: 480,
    scale: 1,
    framed: false,
    preview_start: s.start,
    preview_end: s.end,
    source_time: s.start,
    playing: false,
    media_ready: true,
    focus: "play",
    hover: "",
    gesture: "",
    saved_time: s.start,
    message: "",
    message_error: false,
    export_busy: false,
    appearance: "dark",
    preview_rate: 1,
    rate_menu: false,
    viewport_start: 0,
    viewport_extent: 0,
    viewport_span: 0,
    viewport_fit: true,
    selected_gap: "",
    selected_clip: "",
    audio_expanded: false,
    clip_speed_menu: false,
    clip_trim_start: 0,
    clip_trim_end: 0,
    clip_drag_x: 0,
    clip_drag_ticks_per_pixel: 0,
    clip_drag_active: false,
    clip_move_start: 0,
    clip_move_valid: true,
    crop_mode: false,
    crop_candidate: { x: 0, y: 0, width: 0, height: 0, },
    crop_saved: { x: 0, y: 0, width: 0, height: 0, },
    crop_anchor_x: 0,
    crop_anchor_y: 0,
    waveform: None,
  }
  project_sync_selection(sessions[id])
  id
}

///|
pub fn close(id : Int32) -> Unit {
  sessions.remove(id)
}

///|
fn cursor(s : UI) -> String {
  let target = if s.gesture != "" { s.gesture } else { s.hover }
  if !enabled(s, target) {
    return "default"
  }
  match target {
    "project-crop-region" => "crosshair"
    "trim-start" | "trim-end" | "project-trim-start" | "project-trim-end" =>
      "resize-horizontal"
    "playhead" => "crosshair"
    "play"
    | "undo"
    | "redo"
    | "export"
    | "start"
    | "backward"
    | "forward"
    | "end"
    | "preview-rate" => "pointer"
    _ if rate_index(target) >= 0 => "pointer"
    _ if is_project(s) => "pointer"
    _ => "default"
  }
}
