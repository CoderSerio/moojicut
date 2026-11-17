///|
// Static implementation facts, not a probe of permissions, devices or runtime
// dependencies. All current backends lack microphone capture and pause support.
priv struct RecordingBackend {
  name : String
  sources : Array[String]
  system_audio : Bool
  max_width : Int32
  max_height : Int32
  max_long_edge : Int32
  fps : Int32
  countdown : Int32
}

///|
fn recording_backend(platform : Int32) -> RecordingBackend? {
  match platform {
    0 =>
      Some({
        name: "screencapturekit",
        sources: ["display", "region", "window"],
        system_audio: true,
        max_width: 3840,
        max_height: 3840,
        max_long_edge: 3840,
        fps: 30,
        countdown: 3,
      })
    1 =>
      Some({
        name: "gdi-media-foundation",
        sources: ["primary-display"],
        system_audio: false,
        max_width: 1920,
        max_height: 1080,
        max_long_edge: 0,
        fps: 15,
        countdown: 0,
      })
    _ => None
  }
}

///|
fn recording_platform(platform : String) -> Int32 raise @protocol.InputError {
  match platform {
    "macOS" => 0
    "windows" => 1
    "linux-x11" => 2
    "linux-wayland" => 3
    _ =>
      raise @protocol.InputError("invalid_input", "Unknown recording platform")
  }
}

///|
// This query is side-effect free. The host must still validate its installed
// backend, source lifetime, permissions and busy state before starting capture.
pub fn recording_capabilities(platform : String) -> String {
  @protocol.response(() => {
    let backend = recording_backend(recording_platform(platform))
    let supported = backend is Some(_)
    Json::object({
      "ok": Json(true),
      "platform": Json(platform),
      "supported": Json(supported),
      "backend": match backend {
        Some(b) => Json(b.name)
        None => Json::null()
      },
      "availability": Json(if supported { "unverified" } else { "unsupported" }),
      "permission": Json("unknown"),
      "requiresHostValidation": Json(true),
      "sources": Json::array(
        match backend {
          Some(b) => b.sources.map(s => Json(s))
          None => []
        },
      ),
      "systemAudio": Json(
        match backend {
          Some(b) => b.system_audio
          None => false
        },
      ),
      "microphone": Json(false),
      "pause": Json(false),
      "limits": match backend {
        Some(b) =>
          Json::object({
            "inputCoordinateSpace": Json("source-pixels"),
            "minInputDimension": Json(2),
            "maxInputDimension": Json(32768),
            "outputDimensionMultiple": Json(2),
            "maxWidth": Json(b.max_width),
            "maxHeight": Json(b.max_height),
            "maxLongEdge": if b.max_long_edge == 0 {
              Json::null()
            } else {
              Json(b.max_long_edge)
            },
            "framesPerSecond": Json(b.fps),
            "countdownSeconds": Json(b.countdown),
          })
        None => Json::null()
      },
    })
  })
}
