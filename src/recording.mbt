///|
/// Validate host-driven recording lifecycle events. Media resources stay in the host.
#export_name("recording_transition")
pub fn recording_transition(state : String, event : String) -> String {
  response(() => {
    let next = match (state, event) {
      ("idle" | "ready" | "error", "start") => "requesting"
      ("requesting", "capture_started") => "recording"
      ("recording", "pause") => "paused"
      ("paused", "resume") => "recording"
      ("recording" | "paused", "stop") => "stopping"
      ("stopping", "complete") => "ready"
      ("requesting" | "recording" | "paused" | "stopping", "fail") => "error"
      ("idle" | "ready" | "error", "reset") => "idle"
      _ =>
        raise InputError(
          "invalid_transition",
          "Cannot apply \{event} while recording state is \{state}",
        )
    }
    Json::object({ "ok": Json(true), "state": Json(next) })
  })
}
