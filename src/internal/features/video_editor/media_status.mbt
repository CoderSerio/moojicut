///|
// Playback can fail after its start request was acknowledged. This is a new
// backend observation, not a second acknowledgement of that finished ticket.
pub fn media_failed(handle : Int, generation : Int, message : String) -> Bool {
  let s = match editors.get(handle) { Some(s) => s; None => return false }
  if s.closed || s.closing || generation != s.generation ||
    s.generation == 2147483647 || message.length() > 32768 {
    return false
  }
  // Invalidate queued/late transport observations before reporting the error;
  // UI cancellation must not restore a seek into the failed media instance.
  s.generation += 1
  s.media_revision = -1
  s.playing = false
  for kind in [1, 3, 4, 5] { remove_queued(s, kind) }
  let reason = if message == "" { "Media playback failed" } else { message }
  media_status(s, false, reason)
  show_error(s, reason)
  // An already running export owns its separate immutable plan and must report
  // its own terminal result. A native destination chooser must also be closed
  // and acknowledged by its owner; neither becomes idle from this observation.
  if s.export_busy && !has_pending(s, 7) && !has_pending(s, 6) {
    remove_queued(s, 6)
    fail_export(s, reason, true)
  }
  true
}
