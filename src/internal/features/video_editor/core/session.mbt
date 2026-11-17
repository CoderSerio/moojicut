///|
priv struct Receipt {
  id : String
  request : Json
  response : Json
}

///|
priv struct Session {
  source : Map[String, Json]
  mut document : String
  mut revision : Double
  mut next_id : Int32
  undo : Array[String]
  redo : Array[String]
  receipts : Array[Receipt]
}

///|
let sessions : Map[Int32, Session] = Map([])

///|
let next_session : Ref[Int32] = Ref(0)

///|
fn session(id : Int32) -> Session raise @protocol.InputError {
  match sessions.get(id) {
    Some(s) => s
    None =>
      raise @protocol.InputError(
        "unknown_session", "Project session has closed",
      )
  }
}

///|
fn load(s : Session) -> Project raise @protocol.InputError {
  let (p, _, _) = read_project(s.source, document_object(s.document))
  p
}

///|
fn result(id : Int32, s : Session) -> Json raise @protocol.InputError {
  let p = load(s)
  Json::object({
    "ok": Json(true),
    "session": Json(id),
    "revision": Json(s.revision),
    "document": document_json(p, s.next_id, s.revision),
    "plan": plan_json(p),
    "canUndo": Json(!s.undo.is_empty()),
    "canRedo": Json(!s.redo.is_empty()),
  })
}

///|
fn make_initial(
  source : Map[String, Json],
  draft : Map[String, Json]?,
) -> (Project, Int32) raise @protocol.InputError {
  let has_audio = boolean(source, "hasAudio")
  let limit = source_limit(source)
  let ranges : Array[(Double, Double)] = []
  let (crop, muted, preset) = match draft {
    None => {
      ranges.push((0, @double.floor(limit / frame_ticks) * frame_ticks))
      (Json::null(), false, "share")
    }
    Some(old) => {
      ignore(integer(old, "schemaVersion", 1, 1))
      let timeline = old.copy()
      timeline["durationMs"] = source["durationMs"]
      let planned = @protocol.request_object(
        @video.edit_plan(Json::object(timeline).stringify()),
      )
      if !boolean(planned, "ok") {
        raise @protocol.InputError(
          "invalid_legacy", "The v1 editing plan cannot be migrated",
        )
      }
      let segments = match planned.get("segments") {
        Some(Array(values)) if values.length() <= 256 => values
        _ =>
          raise @protocol.InputError(
            "clip_limit", "Migration supports at most 256 segments",
          )
      }
      for value in segments {
        let segment = object(value)
        let start = integer(segment, "sourceStartMs", 0, 604800000) * 90
        let end = integer(segment, "sourceEndMs", 0, 604800000) * 90
        let a = @double.floor(start / frame_ticks + 0.5) * frame_ticks
        let b = @protocol.smaller(
          @double.floor(end / frame_ticks + 0.5) * frame_ticks,
          @double.floor(limit / frame_ticks) * frame_ticks,
        )
        if b - a < frame_ticks {
          raise @protocol.InputError(
            "too_short", "A v1 retained interval is shorter than one v2 frame",
          )
        }
        ranges.push((a, b))
      }
      let preset = text(old, "preset")
      if preset != "share" && preset != "quality" {
        raise @protocol.InputError("invalid_input", "Unknown preset")
      }
      (crop_value(old, source), boolean(old, "muted"), preset)
    }
  }
  let clips : Array[Clip] = []
  let mut position = 0.0
  let mut ordinal = 1
  for (a, b) in ranges {
    let link = if has_audio { Some("g\{ordinal}") } else { None }
    clips.push({
      id: "v\{ordinal}",
      kind: "video",
      source_start: a,
      source_end: b,
      start: position,
      duration: b - a,
      link,
    })
    if has_audio {
      clips.push({
        id: "a\{ordinal}",
        kind: "audio",
        source_start: a,
        source_end: b,
        start: position,
        duration: b - a,
        link,
      })
    }
    position = position + b - a
    ordinal = ordinal + 1
  }
  let p = { source, clips, crop, muted, preset, }
  validate(p)
  (p, ordinal)
}

///|
pub fn open(source_json : String, draft_json : String) -> String {
  @protocol.response(() => {
    let source = source_metadata(@protocol.request_object(source_json))
    let (p, next_id, revision) = if draft_json == "" {
      let (p, next) = make_initial(source, None)
      (p, next, 0.0)
    } else {
      let draft = document_object(draft_json)
      let version = integer(draft, "schemaVersion", 1, 2)
      if version == 2 {
        read_project(source, draft)
      } else {
        let (p, next) = make_initial(source, Some(draft))
        (p, next, 0.0)
      }
    }
    let id = next_session.val
    if id == 2147483647 {
      raise @protocol.InputError("session_limit", "Session space exhausted")
    }
    next_session.val = id + 1
    let s : Session = {
      source,
      document: document_json(p, next_id, revision).stringify(),
      revision,
      next_id,
      undo: [],
      redo: [],
      receipts: [],
    }
    sessions[id] = s
    result(id, s)
  })
}

///|
fn operations(
  request : Map[String, Json],
) -> Array[Map[String, Json]] raise @protocol.InputError {
  let shape_count = (if request.contains("operations") { 1 } else { 0 }) +
    (if request.contains("op") { 1 } else { 0 }) +
    (if request.contains("type") { 1 } else { 0 })
  if shape_count != 1 {
    raise @protocol.InputError(
      "invalid_input", "Provide one operation or one operations array",
    )
  }
  match request.get("operations") {
    Some(Array(values)) if !values.is_empty() && values.length() <= 64 => {
      let result : Array[Map[String, Json]] = []
      for value in values {
        result.push(object(value))
      }
      result
    }
    Some(_) =>
      raise @protocol.InputError(
        "invalid_input", "Batch must contain 1 to 64 operations",
      )
    None =>
      match request.get("op") {
        Some(value) => [object(value)]
        None => [request]
      }
  }
}

///|
pub fn command(id : Int32, command_json : String) -> String {
  @protocol.response(() => {
    let s = session(id)
    let request = @protocol.request_object(command_json)
    let request_value = Json::object(request)
    let request_id = match request.get("requestId") {
      None => None
      Some(String(value)) if value.length() > 0 && value.length() <= 128 =>
        Some(value)
      _ =>
        raise @protocol.InputError(
          "invalid_input", "requestId must contain 1 to 128 characters",
        )
    }
    // Deduplication precedes revision comparison: a successful retry still
    // contains the original expectedRevision. A different payload never reuses it.
    match request_id {
      Some(key) =>
        for receipt in s.receipts {
          if receipt.id == key {
            if receipt.request != request_value {
              raise @protocol.InputError(
                "request_id_conflict", "requestId was already used with a different payload",
              )
            }
            return receipt.response
          }
        }
      None => ()
    }
    let expected = integer(request, "expectedRevision", 0, 9007199254740990)
    if expected != s.revision {
      raise @protocol.InputError(
        "revision_conflict", "项目已更新，请读取最新版本后重试。",
      )
    }
    let ops = operations(request)
    let action = text(ops[0], "type")
    if s.revision >= 9007199254740990 {
      raise @protocol.InputError("revision_limit", "Revision space exhausted")
    }
    if action == "undo" || action == "redo" {
      if ops.length() != 1 {
        raise @protocol.InputError(
          "invalid_batch", "Undo and redo must be standalone transactions",
        )
      }
      let from = if action == "undo" { s.undo } else { s.redo }
      let to = if action == "undo" { s.redo } else { s.undo }
      if from.is_empty() {
        raise @protocol.InputError(
          "empty_history", "No history in this direction",
        )
      }
      let previous = from[from.length() - 1]
      // Validate the candidate before mutating history or revision.
      let (p, _, _) = read_project(s.source, document_object(previous))
      ignore(from.pop())
      to.push(s.document)
      if to.length() > 100 {
        ignore(to.remove(0))
      }
      s.revision = s.revision + 1
      s.document = document_json(p, s.next_id, s.revision).stringify()
    } else {
      let p = load(s)
      let old_state = document_json(p, s.next_id, 0)
      let next = Ref(s.next_id)
      for op in ops {
        let kind = text(op, "type")
        if kind == "undo" || kind == "redo" {
          raise @protocol.InputError(
            "invalid_batch", "History cannot be mixed with edits",
          )
        }
        apply_operation(p, op, next)
      }
      let next_state = document_json(p, next.val, 0)
      if next_state != old_state {
        s.undo.push(s.document)
        if s.undo.length() > 100 {
          ignore(s.undo.remove(0))
        }
        s.redo.clear()
        s.next_id = next.val
        s.revision = s.revision + 1
        s.document = document_json(p, s.next_id, s.revision).stringify()
      }
    }
    let response = result(id, s)
    match request_id {
      Some(key) => {
        s.receipts.push({ id: key, request: request_value, response, })
        if s.receipts.length() > 64 {
          ignore(s.receipts.remove(0))
        }
      }
      None => ()
    }
    response
  })
}

///|
pub fn snapshot(id : Int32) -> String {
  @protocol.response(() => result(id, session(id)))
}

///|
pub fn close(id : Int32) -> Unit {
  sessions.remove(id)
}
