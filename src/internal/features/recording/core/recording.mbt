///|
using @json {type Json}

///|
/// Validate host-driven recording lifecycle events. Media resources stay in the host.
pub fn recording_transition(state : String, event : String) -> String {
  @protocol.response(() => {
    let next = match (state, event) {
      ("idle" | "ready" | "error", "start") => "requesting"
      ("requesting", "selected") => "countdown"
      ("countdown", "countdown_finished") => "starting"
      ("requesting" | "countdown", "cancel") => "idle"
      ("starting", "capture_started") => "recording"
      ("starting", "stop") => "stopping"
      ("requesting", "capture_started") => "recording"
      ("recording", "pause") => "paused"
      ("paused", "resume") => "recording"
      ("recording" | "paused", "stop") => "stopping"
      ("stopping", "complete") => "ready"
      (
        "requesting"
        | "countdown"
        | "starting"
        | "recording"
        | "paused"
        | "stopping",
        "fail",
      ) => "error"
      ("idle" | "ready" | "error", "reset") => "idle"
      _ =>
        raise @protocol.InputError(
          "invalid_transition",
          "Cannot apply \{event} while recording state is \{state}",
        )
    }
    Json::object({ "ok": Json(true), "state": Json(next) })
  })
}

///|
/// Host controls read the same state rules as transition validation.
pub fn recording_status(state : String) -> String {
  @protocol.response(() => {
    let active = match state {
      "requesting"
      | "countdown"
      | "starting"
      | "recording"
      | "paused"
      | "stopping" => true
      "idle" | "ready" | "error" => false
      _ =>
        raise @protocol.InputError("invalid_state", "Unknown recording state")
    }
    Json::object({
      "ok": Json(true),
      "captureInProgress": Json(active),
      "canStop": Json(active && state != "stopping"),
      "recording": Json(state == "recording"),
    })
  })
}
