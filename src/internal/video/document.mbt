///|
using @json {type Json}

///|
priv struct VideoSession {
  mut document : String
  undo : Array[String]
  redo : Array[String]
}

///|
let video_sessions : Map[Int, VideoSession] = Map([])

///|
let video_next_id : Ref[Int] = Ref(0)

///|
fn video_bool(fields : Map[String, Json], key : String) -> Bool raise @protocol.InputError {
  match fields.get(key) {
    Some(True) => true
    Some(False) => false
    _ => raise @protocol.InputError("invalid_input", "\{key} must be a boolean")
  }
}

///|
fn video_string(fields : Map[String, Json], key : String) -> String raise @protocol.InputError {
  match fields.get(key) {
    Some(String(value)) => value
    _ => raise @protocol.InputError("invalid_input", "\{key} must be text")
  }
}

///|
fn video_default(source : Map[String, Json]) -> Map[String, Json] raise @protocol.InputError {
  let duration = @protocol.integer_field(source, "durationMs", 1.0, 604800000.0)
  let width = @protocol.integer_field(source, "width", 2.0, 32768.0)
  let height = @protocol.integer_field(source, "height", 2.0, 32768.0)
  let audio = video_bool(source, "hasAudio")
  {
    "schemaVersion": Json(1),
    "source": Json::object({ "durationMs": Json(duration), "width": Json(width), "height": Json(height), "hasAudio": Json(audio) }),
    "trim": Json::object({ "startMs": Json(0), "endMs": Json(duration) }),
    "cuts": Json::array([]), "crop": Json::null(), "muted": Json(false), "preset": Json("share"),
  }
}

///|
fn video_plan_document(document : Map[String, Json]) -> Json raise @protocol.InputError {
  let source = @protocol.object_field(document, "source")
  let duration = @protocol.integer_field(source, "durationMs", 1.0, 604800000.0)
  let width = @protocol.integer_field(source, "width", 2.0, 32768.0)
  let height = @protocol.integer_field(source, "height", 2.0, 32768.0)
  let audio = video_bool(source, "hasAudio")
  let muted = video_bool(document, "muted")
  let preset = video_string(document, "preset")
  if preset != "share" && preset != "quality" { raise @protocol.InputError("invalid_input", "Unknown export preset") }
  let timeline = document.copy()
  timeline["durationMs"] = Json(duration)
  let plan = match timeline_plan(timeline) { Object(value) => value; _ => abort("timeline result") }
  let (crop, output_width, output_height) = match document.get("crop") {
    None | Some(Null) => (Json::null(), width, height)
    Some(Object(rect)) => {
      let x = @protocol.integer_field(rect, "x", 0.0, width - 2.0)
      let y = @protocol.integer_field(rect, "y", 0.0, height - 2.0)
      let w = @protocol.integer_field(rect, "width", 2.0, width - x)
      let h = @protocol.integer_field(rect, "height", 2.0, height - y)
      let even_w = @double.floor(w / 2.0) * 2.0
      let even_h = @double.floor(h / 2.0) * 2.0
      (Json::object({ "x": Json(x), "y": Json(y), "width": Json(even_w), "height": Json(even_h) }), even_w, even_h)
    }
    _ => raise @protocol.InputError("invalid_input", "Invalid crop")
  }
  let output_duration = @protocol.integer_field(plan, "outputDurationMs", 1.0, duration)
  let profile_text = export_profile(Json::object({
    "durationMs": Json(output_duration), "width": Json(output_width), "height": Json(output_height),
    "preset": Json(preset), "hasAudio": Json(audio && !muted),
  }).stringify())
  plan["crop"] = crop
  plan["muted"] = Json(muted)
  plan["profile"] = Json::object(@protocol.request_object(profile_text))
  Json::object(plan)
}

///|
fn video_session(id : Int) -> VideoSession raise @protocol.InputError {
  match video_sessions.get(id) {
    Some(session) => session
    None => raise @protocol.InputError("unknown_session", "视频编辑会话已关闭")
  }
}

///|
fn video_result(id : Int, session : VideoSession) -> Json raise @protocol.InputError {
  let document = @protocol.request_object(session.document)
  Json::object({
    "ok": Json(true), "session": Json(id), "document": Json::object(document),
    "plan": video_plan_document(document), "canUndo": Json(!session.undo.is_empty()), "canRedo": Json(!session.redo.is_empty()),
  })
}

///|
pub fn video_open(source_text : String, draft_text : String) -> String {
  @protocol.response(() => {
    let source = @protocol.request_object(source_text)
    let defaults = video_default(source)
    let document = if draft_text == "" { defaults } else {
      let draft = @protocol.request_object(draft_text)
      let version = @protocol.integer_field(draft, "schemaVersion", 1.0, 1.0)
      ignore(version)
      // A draft may edit this source, never replace the host's source metadata.
      draft["source"] = defaults["source"]
      draft
    }
    let plan = match video_plan_document(document) { Object(value) => value; _ => abort("video plan") }
    document["crop"] = plan["crop"]
    let id = video_next_id.val
    video_next_id.val = id + 1
    let session = { document: Json::object(document).stringify(), undo: [], redo: [] }
    video_sessions[id] = session
    video_result(id, session)
  })
}

///|
pub fn video_command(id : Int, command_text : String) -> String {
  @protocol.response(() => {
    let session = video_session(id)
    let command = @protocol.request_object(command_text)
    let action = video_string(command, "type")
    if action == "undo" || action == "redo" {
      let from = if action == "undo" { session.undo } else { session.redo }
      let to = if action == "undo" { session.redo } else { session.undo }
      match from.pop() { Some(previous) => { to.push(session.document); session.document = previous }; None => () }
      return video_result(id, session)
    }
    let document = @protocol.request_object(session.document)
    match action {
      "trim" => document["trim"] = Json::object(@protocol.object_field(command, "trim"))
      "cut" => {
        let cuts = match document.get("cuts") { Some(Array(items)) => items.copy(); _ => [] }
        cuts.push(Json::object(@protocol.object_field(command, "cut")))
        document["cuts"] = Json::array(cuts)
      }
      "clearCuts" => {
        document["cuts"] = Json::array([])
        document.remove("cut")
      }
      "crop" => document["crop"] = match command.get("crop") { Some(value) => value; None => Json::null() }
      "mute" => document["muted"] = Json(video_bool(command, "muted"))
      "preset" => document["preset"] = Json(video_string(command, "preset"))
      "reset" => {
        document.remove("cut")
        let initial = video_default(@protocol.object_field(document, "source"))
        for key in ["trim", "cuts", "crop", "muted", "preset"] { document[key] = initial[key] }
      }
      _ => raise @protocol.InputError("invalid_command", "Unknown video edit command")
    }
    let plan = match video_plan_document(document) { Object(value) => value; _ => abort("video plan") }
    document["crop"] = plan["crop"]
    let next = Json::object(document).stringify()
    if next != session.document {
      session.undo.push(session.document)
      if session.undo.length() > 100 { ignore(session.undo.remove(0)) }
      session.redo.clear()
      session.document = next
    }
    video_result(id, session)
  })
}

///|
pub fn video_snapshot(id : Int) -> String {
  @protocol.response(() => video_result(id, video_session(id)))
}

///|
/// Resolve a source time onto the next kept frame and its output-time position.
pub fn video_seek(id : Int, milliseconds : Double) -> String {
  @protocol.response(() => {
    let session = video_session(id)
    let document = @protocol.request_object(session.document)
    let source = @protocol.object_field(document, "source")
    let duration = @protocol.integer_field(source, "durationMs", 1.0, 604800000.0)
    if !(milliseconds >= 0.0 && milliseconds <= duration) { raise @protocol.InputError("invalid_input", "Invalid seek time") }
    let plan = match video_plan_document(document) { Object(value) => value; _ => abort("video plan") }
    let segments = match plan["segments"] { Array(items) => items; _ => abort("segments") }
    let mut source_time = 0.0
    let mut output_time = 0.0
    let mut at_end = true
    for segment in segments {
      let fields = match segment { Object(fields) => fields; _ => abort("segment") }
      let start = @protocol.integer_field(fields, "sourceStartMs", 0.0, duration)
      let end = @protocol.integer_field(fields, "sourceEndMs", 0.0, duration)
      let output = @protocol.integer_field(fields, "outputStartMs", 0.0, duration)
      if milliseconds < end {
        source_time = @protocol.larger(start, milliseconds)
        output_time = output + source_time - start
        at_end = false
        break
      }
      source_time = @protocol.larger(start, end - 1.0)
      output_time = @protocol.integer_field(fields, "outputEndMs", 0.0, duration)
    }
    Json::object({ "ok": Json(true), "sourceMs": Json(source_time), "outputMs": Json(output_time), "atEnd": Json(at_end) })
  })
}

///|
pub fn video_dispose(id : Int) -> Unit { video_sessions.remove(id) }
