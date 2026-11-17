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
/// Encoding policy only; capture, timing, audio and media I/O stay in the host.
/// Values are width, height, fps, system audio, microphone, countdown seconds.
/// Platform 0 is macOS; 1 is Windows. All zeros means invalid input.
pub fn native_recording_plan(
  platform : Int32,
  width : Int32,
  height : Int32,
  system_audio : Int32,
) -> FixedArray[Int32] {
  if (platform != 0 && platform != 1) ||
    width < 2 ||
    height < 2 ||
    width > 32768 ||
    height > 32768 ||
    (system_audio != 0 && system_audio != 1) {
    return [0, 0, 0, 0, 0, 0]
  }
  let w = width.to_double()
  let h = height.to_double()
  let scale = if platform == 1 {
    @protocol.smaller(1.0, @protocol.smaller(1920.0 / w, 1080.0 / h))
  } else {
    @protocol.smaller(1.0, 3840.0 / @protocol.larger(w, h))
  }
  [
    @protocol.larger(2.0, @double.floor(w * scale / 2.0) * 2.0).to_int(),
    @protocol.larger(2.0, @double.floor(h * scale / 2.0) * 2.0).to_int(),
    if platform == 1 {
      15
    } else {
      30
    },
    if platform == 1 {
      0
    } else {
      system_audio
    },
    0,
    if platform == 1 {
      0
    } else {
      3
    },
  ]
}

///|
/// Keep existing macOS callers compatible when platform is omitted. Windows
/// fits within 1920x1080, while macOS caps the longest edge at 3840 pixels.
pub fn recording_plan(request : String) -> String {
  @protocol.response(() => {
    let fields = @protocol.request_object(request)
    let width = @protocol.integer_field(fields, "width", 2.0, 32768.0)
    let height = @protocol.integer_field(fields, "height", 2.0, 32768.0)
    let audio = match fields.get("systemAudio") {
      Some(True) => true
      Some(False) => false
      _ =>
        raise @protocol.InputError(
          "invalid_input", "systemAudio must be a boolean",
        )
    }
    let platform = match fields.get("platform") {
      None | Some(String("macOS")) => 0
      Some(String("windows")) => 1
      _ =>
        raise @protocol.InputError(
          "invalid_input", "Unsupported recording platform",
        )
    }
    let values = native_recording_plan(
      platform,
      width.to_int(),
      height.to_int(),
      if audio {
        1
      } else {
        0
      },
    )
    Json::object({
      "ok": Json(true),
      "width": Json(values[0]),
      "height": Json(values[1]),
      "framesPerSecond": Json(values[2]),
      "systemAudio": Json(values[3] == 1),
      "microphone": Json(values[4] == 1),
      "countdownSeconds": Json(values[5]),
    })
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
