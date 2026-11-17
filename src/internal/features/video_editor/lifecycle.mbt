///|
fn fail_export(s : Editor, message : String, failed : Bool) -> Unit {
  s.export_destination = ""
  remove_queued(s, 7)
  export_status(s, false, message, failed)
  if failed {
    s.error = message
    s.closing = false
  }
}

///|
// Acknowledgements are terminal for their ticket. In particular cancelling an
// export has two tickets: CANCEL_EXPORT acknowledges the cancellation request,
// whereas EXPORT must still acknowledge actual cleanup before close can run.
pub fn ack(
  handle : Int32,
  effect : Int32,
  status : Int32,
  message : String,
) -> Bool {
  if status < 0 || status > 2 || message.length() > 32768 {
    return false
  }
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  let e = match s.pending.get(effect) {
    Some(e) => e
    None => return false
  }
  if e.kind == 6 && status == 0 && !valid_path(message) {
    return false
  }
  s.pending.remove(effect)
  let current = e.generation == s.generation && e.revision == s.revision
  let failed_message = if message == "" {
    "The editor operation failed"
  } else {
    message
  }
  match e.kind {
    1 =>
      if current && !s.closing && !s.closed {
        if status == 0 {
          s.media_revision = e.revision
          media_status(s, true, "")
        } else {
          s.media_revision = -1
          s.error = failed_message
          media_status(s, false, failed_message)
          if s.export_busy {
            fail_export(s, failed_message, true)
          }
        }
      }
    2 =>
      if status == 0 {
        // The save lane is serial: this can advance only to the bytes that the
        // host just durably committed, never to a newer in-memory document.
        s.saved_revision = e.revision
        if s.saved_revision == s.revision {
          persistence_status(s, "")
        }
      } else {
        persistence_status(s, failed_message)
        s.closing = false
        // End the current gesture, but keep persistence separate from an
        // unrelated transport error (which may have the exact same wording).
        ui_event(s, Json::object({ "type": Json("cancel") }))
        if s.export_busy {
          // Abort the waiting export, while the persistence channel retains
          // its cause until SAVE succeeds. Do not duplicate it as a new error.
          fail_export(s, "", false)
        }
      }
    3 | 4 =>
      if current && !s.closing && status != 0 && !has_queued(s, e.kind) {
        s.playing = false
        show_error(s, failed_message)
        ui_event(
          s,
          Json::object({
            "type": Json("playback"),
            "outputMs": Json(s.output_ms),
            "playing": Json(false),
          }),
        )
      }
    5 =>
      if current && !s.closing && !has_queued(s, 5) {
        if status == 0 {
          s.rate = e.number
        }
        ui_event(
          s,
          Json::object({
            "type": Json("previewRateStatus"),
            "rate": Json(s.rate),
            "message": Json(if status == 0 { "" } else { failed_message }),
            "error": Json(status != 0),
          }),
        )
      }
    6 =>
      if status == 0 {
        if message == s.source_path {
          fail_export(
            s, "Choose a destination different from the original recording", true,
          )
        } else {
          s.export_destination = message
          save(s)
          synchronize(s)
        }
      } else {
        fail_export(
          s,
          if status == 1 {
            failed_message
          } else {
            ""
          },
          status == 1,
        )
      }
    7 => {
      // Export completion is authoritative even after a cancellation request.
      // Success can win the race; either terminal result releases busy state.
      fail_export(s, if status == 1 { failed_message } else { "" }, status == 1)
      remove_queued(s, 8)
    }
    8 =>
      if status == 1 && has_pending(s, 7) {
        s.error = failed_message
        s.closing = false
        show_error(s, failed_message)
      }
    9 =>
      if status == 0 {
        s.closed = true
        s.closing = false
        s.playing = false
        s.capture = false
        for queued in s.queued {
          dispose_effect(queued)
        }
        s.queued = []
        for _, pending in s.pending {
          dispose_effect(pending)
        }
        s.pending.clear()
      } else {
        s.closing = false
        s.media_revision = -1
        media_status(s, false, failed_message)
        show_error(s, failed_message)
      }
    _ => ()
  }
  dispose_effect(e)
  advance(s)
  true
}

///|
// Called with the generation used for the backend's active plan. Position
// callbacks from the superseded plan, or during a pending seek, cannot move the
// shared playhead back. The host must also reject stale decoded frame buffers.
pub fn playback(
  handle : Int32,
  generation : Int32,
  output_ms : Double,
  playing : Bool,
) -> Bool {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  if s.closed ||
    s.closing ||
    generation != s.generation ||
    s.media_revision != s.revision ||
    has_pending(s, 1) ||
    has_pending(s, 3) ||
    has_queued(s, 3) ||
    has_pending(s, 4) ||
    has_queued(s, 4) ||
    !(output_ms >= 0 && output_ms <= 604800000) {
    return false
  }
  s.output_ms = output_ms
  s.playing = playing
  ui_event(
    s,
    Json::object({
      "type": Json("playback"),
      "outputMs": Json(output_ms),
      "playing": Json(playing),
    }),
  )
  true
}

///|
pub fn export_progress(
  handle : Int32,
  effect : Int32,
  progress : Double,
) -> Bool {
  if !(progress >= 0 && progress <= 1) {
    return false
  }
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  match s.pending.get(effect) {
    Some(e) if e.kind == 7 && !s.closed => {
      s.export_progress = progress
      true
    }
    _ => false
  }
}

///|
// Optional analysis belongs to the source, not a particular editing revision.
// The existing UI decoder validates bounded peak arrays. No second waveform or
// timeline model is introduced in the platform adapter.
pub fn waveform(handle : Int32, waveform_json : String) -> Bool {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  if s.closed || s.closing {
    return false
  }
  let input = match snapshot_object(waveform_json) {
    Some(value) => value
    None => return false
  }
  if string_value(input, "type") != "waveform" {
    return false
  }
  fields(@ui.event(s.ui, waveform_json)) is Some(_)
}

///|
pub fn retry(handle : Int32) -> Bool {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  if s.closed || s.closing || s.export_busy {
    return false
  }
  s.error = ""
  synchronize(s)
  save(s)
  true
}

///|
pub fn request_close(handle : Int32, cancel_export : Bool) -> Bool {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  if s.closed || s.closing {
    return true
  }
  // A system save chooser is still owned by the host. It must be dismissed and
  // its CHOOSE_EXPORT ticket acknowledged before a close can be accepted.
  if has_pending(s, 6) || has_queued(s, 6) {
    return false
  }
  if s.export_busy && !cancel_export {
    return false
  }
  s.closing = true
  s.playing = false
  s.capture = false
  ui_event(s, Json::object({ "type": Json("cancel") }))
  if s.export_busy {
    remove_queued(s, 7)
    let mut export_id = 0
    for _, e in s.pending {
      if e.kind == 7 {
        export_id = e.id
      }
    }
    if export_id > 0 {
      ignore(enqueue(s, 8, "", export_id.to_double()))
    } else {
      fail_export(s, "", false)
    }
  }
  save(s)
  advance(s)
  true
}

///|
// Explicit release is legal only after CLOSE_MEDIA success. It never invents
// cleanup completion, so a native callback cannot outlive a freed session.
pub fn release(handle : Int32) -> Bool {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return false
  }
  if !s.closed {
    return false
  }
  @ui.close(s.ui)
  @project.close(s.project)
  editors.remove(handle)
  true
}

///|
// Value keys: PHASE=0 (1 open, 2 closing, 3 closed), DIRTY=1, MEDIA_READY=2,
// EXPORT_BUSY=3, CAPTURE=4, PLAYING=5, GENERATION=6. Invalid => -1.
pub fn value(handle : Int32, key : Int32) -> Int32 {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return -1
  }
  match key {
    0 => if s.closed { 3 } else if s.closing { 2 } else { 1 }
    1 => if s.saved_revision != s.revision { 1 } else { 0 }
    2 =>
      if !s.closed && !s.closing && s.media_revision == s.revision {
        1
      } else {
        0
      }
    3 => if s.export_busy { 1 } else { 0 }
    4 => if s.capture { 1 } else { 0 }
    5 => if s.playing { 1 } else { 0 }
    6 => s.generation
    _ => -1
  }
}

///|
// Number keys: REVISION=0, SAVED_REVISION=1, MEDIA_REVISION=2, OUTPUT_MS=3,
// PREVIEW_RATE=4, EXPORT_PROGRESS=5. Invalid => -1.
pub fn number(handle : Int32, key : Int32) -> Double {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return -1
  }
  match key {
    0 => s.revision
    1 => s.saved_revision
    2 => s.media_revision
    3 => s.output_ms
    4 => s.rate
    5 => s.export_progress
    _ => -1
  }
}

///|
// Text keys: SOURCE_PATH=0, DOCUMENT=1, ERROR=2. Returned strings are immutable
// values; the foreign-library wrapper returns an owned MoonBit string.
pub fn text(handle : Int32, key : Int32) -> String {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return ""
  }
  match key {
    0 => s.source_path
    1 => document(s)
    2 => current_error(s)
    _ => ""
  }
}

///|
// The project session number is intentionally omitted: native clients must use
// this orchestrator, not mutate its child project/UI sessions behind its back.
pub fn state(handle : Int32) -> String {
  let s = match editors.get(handle) {
    Some(s) => s
    None => return ""
  }
  let result = s.current.copy()
  result.remove("session")
  result["editor"] = Json(handle)
  result["phase"] = Json(value(handle, 0))
  result["dirty"] = Json(s.saved_revision != s.revision)
  result["mediaReady"] = Json(value(handle, 2) == 1)
  result["generation"] = Json(s.generation)
  result["savedRevision"] = Json(s.saved_revision)
  result["mediaRevision"] = Json(s.media_revision)
  result["error"] = Json(current_error(s))
  Json::object(result).stringify()
}
