///|
// One editor owns both authoritative project and shared UI. Native windows only
// execute these effects. Each effect retains its own revision and immutable
// media plan until acknowledged; no asynchronous job reads the mutable project.
using @json {type Json}

///|
priv struct Effect {
  id : Int32
  kind : Int32
  generation : Int32
  revision : Double
  plan : Int32
  text : String
  number : Double
}

///|
priv struct Editor {
  project : Int32
  ui : Int32
  source_path : String
  mut current : Map[String, Json]
  mut revision : Double
  mut saved_revision : Double
  mut media_revision : Double
  mut generation : Int32
  mut queued : Array[Effect]
  pending : Map[Int32, Effect]
  mut closing : Bool
  mut closed : Bool
  mut capture : Bool
  mut export_busy : Bool
  mut export_destination : String
  mut export_progress : Double
  mut output_ms : Double
  mut playing : Bool
  mut rate : Double
  mut error : String
  mut save_error : String
  mut request_serial : Int32
}

///|
let editors : Map[Int32, Editor] = Map([])

///|
let next_editor : Ref[Int32] = Ref(1)

///|
let next_effect : Ref[Int32] = Ref(1)

///|
// Effect kinds: APPLY_PLAN=1, SAVE_DRAFT=2, SEEK=3, PLAY=4,
// PREVIEW_RATE=5, CHOOSE_EXPORT=6, EXPORT=7, CANCEL_EXPORT=8, CLOSE_MEDIA=9.
// ACK: SUCCESS=0, FAILURE=1, CANCELLED=2. CLOSE_MEDIA success is a resource
// barrier: every backend callback/worker has finished, not merely been asked
// to cancel. This permits retirement of outstanding effect tickets below.
fn snapshot_object(value : String) -> Map[String, Json]? {
  // Matches video_ui's bounded snapshot envelope. A legal 512-clip project
  // contains document + plan, exceeding the small 64 KiB command limit.
  if value.length() > 1048576 {
    return None
  }
  let parsed = @json.parse(
    value,
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => return None
  }
  match parsed {
    Object(object) => Some(object)
    _ => None
  }
}

///|
fn fields(value : String) -> Map[String, Json]? {
  let object = match snapshot_object(value) {
    Some(value) => value
    None => return None
  }
  if object.get("ok") != Some(Json(true)) {
    return None
  }
  Some(object)
}

///|
fn numeric(object : Map[String, Json], key : String) -> Double {
  match object.get(key) {
    Some(Number(n, ..)) => n
    _ => -1
  }
}

///|
fn string_value(object : Map[String, Json], key : String) -> String {
  match object.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn failure_message(response : String) -> String {
  let result = @protocol.request_object(response) catch {
    _ => return "Invalid editor response"
  }
  match result.get("error") {
    Some(Object(error)) => string_value(error, "message")
    _ => "The edit could not be applied"
  }
}

///|
fn valid_path(path : String) -> Bool {
  path != "" && path.length() <= 32768 && !path.contains("\u0000")
}

///|
fn ui_event(s : Editor, value : Json) -> Unit {
  let response = match fields(@ui.event(s.ui, value.stringify())) {
    Some(response) => response
    None => return
  }
  s.capture = response.get("capture") == Some(Json(true))
  // Snapshot/error/export status can cancel a ruler gesture. Its restoration
  // is a real media effect, even though the event originated inside the owner.
  // A new project revision, invalid media or closing session cannot restore
  // the previous plan's seek. These status events never issue document edits.
  if s.closed || s.closing || s.media_revision != s.revision {
    return
  }
  match response.get("effects") {
    Some(Array(effects)) =>
      for value in effects {
        match value {
          Object(effect) if string_value(effect, "type") == "seekOutput" => {
            s.output_ms = numeric(effect, "outputMs")
            ignore(enqueue(s, 3, "", s.output_ms))
          }
          _ => ()
        }
      }
    _ => ()
  }
}

///|
fn show_error(s : Editor, message : String) -> Unit {
  s.error = message
  ui_event(s, Json::object({ "type": Json("error"), "message": Json(message) }))
  s.capture = false
}

///|
fn current_error(s : Editor) -> String {
  if s.save_error != "" { s.save_error } else { s.error }
}

///|
fn persistence_status(s : Editor, message : String) -> Unit {
  s.save_error = message
  ui_event(s, Json::object({ "type": Json("persistenceStatus"), "message": Json(message) }))
}

///|
fn media_status(s : Editor, ready : Bool, message : String) -> Unit {
  ui_event(
    s,
    Json::object({
      "type": Json("mediaStatus"),
      "ready": Json(ready),
      "message": Json(message),
    }),
  )
  if !ready {
    s.playing = false
    s.capture = false
  }
}

///|
fn export_status(
  s : Editor,
  busy : Bool,
  message : String,
  failed : Bool,
) -> Unit {
  s.export_busy = busy
  ui_event(
    s,
    Json::object({
      "type": Json("exportStatus"),
      "busy": Json(busy),
      "message": Json(message),
      "error": Json(failed),
    }),
  )
  if busy {
    s.capture = false
  }
}

///|
fn has_pending(s : Editor, kind : Int32) -> Bool {
  for _, e in s.pending {
    if e.kind == kind {
      return true
    }
  }
  false
}

///|
fn has_queued(s : Editor, kind : Int32) -> Bool {
  s.queued.any(e => e.kind == kind)
}

///|
fn dispose_effect(e : Effect) -> Unit {
  if e.plan != 0 {
    @project.media_plan_close(e.plan)
  }
}

///|
fn remove_queued(s : Editor, kind : Int32) -> Unit {
  s.queued = s.queued.filter(e => {
    if e.kind == kind {
      dispose_effect(e)
      false
    } else {
      true
    }
  })
}

///|
fn enqueue(s : Editor, kind : Int32, text : String, number : Double) -> Bool {
  // At most one queued and one in-flight effect per kind. The save and plan
  // lanes are serial, so older writes/applies cannot finish after newer ones.
  remove_queued(s, kind)
  if next_effect.val == 2147483647 {
    show_error(s, "Editor effect space exhausted")
    return false
  }
  let plan = if kind == 1 || kind == 7 {
    let handle = @project.media_plan_open(s.project)
    if handle == 0 {
      show_error(s, "Cannot retain the current media plan")
      return false
    }
    handle
  } else {
    0
  }
  let id = next_effect.val
  next_effect.val += 1
  s.queued.push({
    id,
    kind,
    generation: s.generation,
    revision: s.revision,
    plan,
    text,
    number,
  })
  true
}

///|
fn document(s : Editor) -> String {
  match s.current.get("document") {
    Some(value) => value.stringify()
    None => ""
  }
}

///|
fn save(s : Editor) -> Unit {
  if s.saved_revision != s.revision {
    // An identical in-flight revision already owns its immutable bytes.
    for _, e in s.pending {
      if e.kind == 2 && e.revision == s.revision {
        return
      }
    }
    ignore(enqueue(s, 2, document(s), 0))
  }
}

///|
fn synchronize(s : Editor) -> Unit {
  if s.media_revision != s.revision {
    for _, e in s.pending {
      if e.kind == 1 && e.revision == s.revision && e.generation == s.generation {
        return
      }
    }
    media_status(s, false, "")
    ignore(enqueue(s, 1, s.source_path, 0))
  }
}

///|
fn advance(s : Editor) -> Unit {
  if s.closed {
    return
  }
  if s.closing {
    if !s.export_busy &&
      s.saved_revision == s.revision &&
      !has_pending(s, 2) &&
      !has_queued(s, 2) &&
      !has_pending(s, 9) &&
      !has_queued(s, 9) {
      // close() owns cancellation of any in-flight preview operation; its ACK
      // is the barrier, and their late ACKs cannot revive a closed editor.
      for kind in [1, 3, 4, 5] {
        remove_queued(s, kind)
      }
      if !enqueue(s, 9, "", 0) {
        s.closing = false
      }
    }
    return
  }
  if s.export_busy &&
    s.export_destination != "" &&
    s.saved_revision == s.revision &&
    s.media_revision == s.revision &&
    !has_pending(s, 2) &&
    !has_pending(s, 1) &&
    !has_pending(s, 7) &&
    !has_queued(s, 7) {
    if !enqueue(s, 7, s.export_destination, 0) {
      fail_export(s, s.error, true)
    }
  }
}

///|
// sourcePath is supplied by the host (e.g. source.webm on Linux), never inferred
// from a platform-specific extension. Empty draft means genuinely missing;
// unreadable/malformed drafts must not be silently replaced by the host.
pub fn open(
  source_path : String,
  source_json : String,
  draft_json : String,
) -> Int32 {
  if !valid_path(source_path) ||
    editors.length() >= 16 ||
    next_editor.val == 2147483647 {
    return 0
  }
  let current = match fields(@project.open(source_json, draft_json)) {
    Some(value) => value
    None => return 0
  }
  let project = numeric(current, "session").to_int()
  let ui = @ui.open(Json::object(current).stringify())
  if ui < 0 {
    @project.close(project)
    return 0
  }
  let revision = numeric(current, "revision")
  let existing_v2 = if draft_json == "" {
    false
  } else {
    let draft = match snapshot_object(draft_json) {
      Some(value) => value
      None => Map([])
    }
    numeric(draft, "schemaVersion") == 2
  }
  let s : Editor = {
    project,
    ui,
    source_path,
    current,
    revision,
    saved_revision: if existing_v2 {
      revision
    } else {
      -1
    },
    media_revision: -1,
    generation: 1,
    queued: [],
    pending: Map([]),
    closing: false,
    closed: false,
    capture: false,
    export_busy: false,
    export_destination: "",
    export_progress: 0,
    output_ms: 0,
    playing: false,
    rate: 1,
    error: "",
    save_error: "",
    request_serial: 0,
  }
  let id = next_editor.val
  next_editor.val += 1
  editors[id] = s
  synchronize(s)
  save(s)
  id
}

///|
// A restored/imported document has not yet been committed at its new storage
// location, even if its schema is already v2. Storage chooses the source; the
// shared owner decides which exact revision must be saved before export/close.
pub fn open_unsaved(source_path : String, source_json : String, draft_json : String) -> Int32 {
  let id = open(source_path, source_json, draft_json)
  match editors.get(id) {
    Some(s) => {
      s.saved_revision = -1
      save(s)
    }
    None => ()
  }
  id
}

///|
fn commit(s : Editor, request : String) -> Bool {
  if s.closed || s.closing || s.export_busy {
    return false
  }
  if s.generation == 2147483647 {
    show_error(s, "Editor generation space exhausted")
    return false
  }
  let result = @project.command(s.project, request)
  let next = match fields(result) {
    Some(value) => value
    None => {
      ui_event(
        s,
        Json::object({
          "type": Json("snapshot"),
          "snapshot": Json::object(s.current),
        }),
      )
      show_error(s, failure_message(result))
      return false
    }
  }
  let revision = numeric(next, "revision")
  // Core deduplication can return a receipt from an older revision. It is a
  // successful retry, never an instruction to roll the current UI backward.
  if revision <= s.revision {
    return true
  }
  s.current = next
  s.revision = revision
  s.generation += 1
  s.error = ""
  s.playing = false
  for kind in [1, 3, 4, 5] {
    remove_queued(s, kind)
  }
  ui_event(
    s,
    Json::object({ "type": Json("snapshot"), "snapshot": Json::object(next) }),
  )
  s.capture = false
  synchronize(s)
  save(s)
  // The user's output position survives the document transaction. The media
  // adapter clamps it to the new immutable plan, after applying that plan.
  ignore(enqueue(s, 3, "", s.output_ms))
  true
}

///|
pub fn command(handle : Int32, request : String) -> Bool {
  match editors.get(handle) {
    Some(s) => commit(s, request)
    None => false
  }
}

///|
fn begin_export(s : Editor) -> Bool {
  if s.closed || s.closing || s.export_busy {
    return false
  }
  s.export_destination = ""
  s.export_progress = 0
  export_status(s, true, "", false)
  if !enqueue(s, 6, "", 0) {
    export_status(s, false, s.error, true)
    return false
  }
  true
}

///|
pub fn event(handle : Int32, input_json : String) -> Bool {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  if s.closed || s.closing {
    return false
  }
  let input = @protocol.request_object(input_json) catch { _ => return false }
  let kind = string_value(input, "type")
  // Backend status and project snapshots only enter through the methods below.
  if ![
      "appearance", "pointerDown", "pointerMove", "pointerUp", "cancel", "scroll",
      "key", "activate",
    ].contains(kind) {
    return false
  }
  let response = match fields(@ui.event(s.ui, input_json)) {
    Some(value) => value
    None => return false
  }
  s.capture = response.get("capture") == Some(Json(true))
  let effects = match response.get("effects") {
    Some(Array(values)) => values
    _ => return false
  }
  let mut ok = true
  for value in effects {
    let effect = match value {
      Object(value) => value
      _ => continue
    }
    match string_value(effect, "type") {
      "command" => {
        if s.request_serial == 2147483647 {
          show_error(s, "Editor request space exhausted")
          ok = false
          continue
        }
        s.request_serial += 1
        let request = Json::object({
          "expectedRevision": Json(s.revision),
          "requestId": Json("editor-ui-\{s.request_serial}"),
          "op": effect["command"],
        }).stringify()
        if !commit(s, request) {
          ok = false
        }
      }
      "seekOutput" => {
        s.output_ms = numeric(effect, "outputMs")
        ignore(enqueue(s, 3, "", s.output_ms))
      }
      "play" => {
        s.playing = effect.get("playing") == Some(Json(true))
        ignore(enqueue(s, 4, "", if s.playing { 1 } else { 0 }))
      }
      "previewRate" => {
        let rate = numeric(effect, "rate")
        ignore(enqueue(s, 5, "", rate))
      }
      "export" => if !begin_export(s) { ok = false }
      _ => {
        show_error(s, "Unsupported editor UI effect")
        ok = false
      }
    }
  }
  ok
}

///|
pub fn frame(handle : Int32, width : Double, height : Double) -> String {
  match editors.get(handle) {
    Some(s) if !s.closed => @ui.frame(s.ui, width, height)
    _ => ""
  }
}

///|
fn eligible(s : Editor, e : Effect) -> Bool {
  if has_pending(s, e.kind) {
    return false
  }
  match e.kind {
    1 => !s.closing && !has_pending(s, 3) && !has_pending(s, 4) && !has_pending(s, 5)
    3 | 4 | 5 => {
      if s.closing ||
        s.media_revision != s.revision ||
        has_pending(s, 1) ||
        has_pending(s, 3) ||
        has_pending(s, 4) ||
        has_pending(s, 5) {
        return false
      }
      if e.kind == 4 && (has_pending(s, 3) || has_queued(s, 3)) {
        return false
      }
      true
    }
    _ => true
  }
}

///|
pub fn take_effect(handle : Int32) -> Int32 {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return 0
  }
  if s.closed {
    return 0
  }
  advance(s)
  for index, e in s.queued {
    if eligible(s, e) {
      ignore(s.queued.remove(index))
      s.pending[e.id] = e
      return e.id
    }
  }
  0
}

///|
fn pending_effect(handle : Int32, effect : Int32) -> Effect? {
  match editors.get(handle) {
    Some(s) => s.pending.get(effect)
    None => None
  }
}

///|
pub fn effect_kind(handle : Int32, effect : Int32) -> Int32 {
  match pending_effect(handle, effect) {
    Some(e) => e.kind
    None => 0
  }
}

///|
pub fn effect_plan(handle : Int32, effect : Int32) -> Int32 {
  match pending_effect(handle, effect) {
    Some(e) => e.plan
    None => 0
  }
}

///|
pub fn effect_generation(handle : Int32, effect : Int32) -> Int32 {
  match pending_effect(handle, effect) {
    Some(e) => e.generation
    None => 0
  }
}

///|
pub fn effect_revision(handle : Int32, effect : Int32) -> Double {
  match pending_effect(handle, effect) {
    Some(e) => e.revision
    None => -1
  }
}

///|
pub fn effect_number(handle : Int32, effect : Int32) -> Double {
  match pending_effect(handle, effect) {
    Some(e) => e.number
    None => -1
  }
}

///|
pub fn effect_text(handle : Int32, effect : Int32) -> String {
  match pending_effect(handle, effect) {
    Some(e) => e.text
    None => ""
  }
}
