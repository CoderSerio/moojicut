///|
fn recording_bool(
  fields : Map[String, Json],
  key : String,
  fallback : Bool?,
) -> Bool raise @protocol.InputError {
  match fields.get(key) {
    Some(True) => true
    Some(False) => false
    None =>
      match fallback {
        Some(value) => value
        None =>
          raise @protocol.InputError(
            "invalid_input",
            "\{key} must be a boolean",
          )
      }
    _ => raise @protocol.InputError("invalid_input", "\{key} must be a boolean")
  }
}

///|
// The existing six-value host ABI consumes the same backend limits as the
// strict request API. Keep its historical Windows audio-bit normalization.
pub fn native_recording_plan(
  platform : Int32,
  width : Int32,
  height : Int32,
  system_audio : Int32,
) -> FixedArray[Int32] {
  if width < 2 ||
    height < 2 ||
    width > 32768 ||
    height > 32768 ||
    (system_audio != 0 && system_audio != 1) {
    return [0, 0, 0, 0, 0, 0]
  }
  let backend = match recording_backend(platform) {
    Some(backend) => backend
    None => return [0, 0, 0, 0, 0, 0]
  }
  let w = width.to_double()
  let h = height.to_double()
  let scale = if backend.max_long_edge > 0 {
    @protocol.smaller(
      1.0,
      backend.max_long_edge.to_double() / @protocol.larger(w, h),
    )
  } else {
    @protocol.smaller(
      1.0,
      @protocol.smaller(
        backend.max_width.to_double() / w,
        backend.max_height.to_double() / h,
      ),
    )
  }
  [
    @protocol.larger(2.0, @double.floor(w * scale / 2.0) * 2.0).to_int(),
    @protocol.larger(2.0, @double.floor(h * scale / 2.0) * 2.0).to_int(),
    backend.fps,
    if backend.system_audio {
      system_audio
    } else {
      0
    },
    0,
    backend.countdown,
  ]
}

///|
fn recording_plan_fields(values : FixedArray[Int32]) -> Map[String, Json] {
  {
    "ok": Json(true),
    "width": Json(values[0]),
    "height": Json(values[1]),
    "framesPerSecond": Json(values[2]),
    "systemAudio": Json(values[3] == 1),
    "microphone": Json(values[4] == 1),
    "countdownSeconds": Json(values[5]),
  }
}

///|
// Existing macOS host request/response and optional platform remain compatible.
pub fn recording_plan(request : String) -> String {
  @protocol.response(() => {
    let fields = @protocol.request_object(request)
    let width = @protocol.integer_field(fields, "width", 2, 32768).to_int()
    let height = @protocol.integer_field(fields, "height", 2, 32768).to_int()
    let audio = recording_bool(fields, "systemAudio", None)
    let platform = match fields.get("platform") {
      None | Some(String("macOS")) => 0
      Some(String("windows")) => 1
      _ =>
        raise @protocol.InputError(
          "invalid_input", "Unsupported recording platform",
        )
    }
    Json::object(
      recording_plan_fields(
        native_recording_plan(
          platform,
          width,
          height,
          if audio {
            1
          } else {
            0
          },
        ),
      ),
    )
  })
}

///|
// Validate a desired capture against static implementation support. This is a
// parameter plan, never authorization or a live source/resource lease.
pub fn recording_request_plan(request : String) -> String {
  @protocol.response(() => {
    let fields = @protocol.request_object(request)
    for key, _ in fields {
      if !(key == "platform" ||
        key == "source" ||
        key == "width" ||
        key == "height" ||
        key == "systemAudio" ||
        key == "microphone" ||
        key == "pause") {
        raise @protocol.InputError(
          "invalid_input",
          "Unknown recording request field: \{key}",
        )
      }
    }
    let platform_name = match fields.get("platform") {
      Some(String(name)) => name
      _ => raise @protocol.InputError("invalid_input", "platform must be text")
    }
    let platform = recording_platform(platform_name)
    let backend = match recording_backend(platform) {
      Some(b) => b
      None =>
        raise @protocol.InputError(
          "unsupported_backend", "此环境尚未实现录屏",
        )
    }
    let source = match fields.get("source") {
      Some(String(source)) => source
      _ => raise @protocol.InputError("invalid_input", "source must be text")
    }
    if !backend.sources.contains(source) {
      raise @protocol.InputError(
        "unsupported_source", "当前录屏后端不支持此来源",
      )
    }
    let width = @protocol.integer_field(fields, "width", 2, 32768).to_int()
    let height = @protocol.integer_field(fields, "height", 2, 32768).to_int()
    let audio = recording_bool(fields, "systemAudio", None)
    let microphone = recording_bool(fields, "microphone", Some(false))
    let pause = recording_bool(fields, "pause", Some(false))
    if audio && !backend.system_audio {
      raise @protocol.InputError(
        "unsupported_audio", "当前录屏后端不支持系统声音",
      )
    }
    if microphone {
      raise @protocol.InputError(
        "unsupported_audio", "当前录屏后端不支持麦克风",
      )
    }
    if pause {
      raise @protocol.InputError(
        "unsupported_pause", "当前录屏后端不支持暂停",
      )
    }
    let result = recording_plan_fields(
      native_recording_plan(platform, width, height, if audio { 1 } else { 0 }),
    )
    result["platform"] = Json(platform_name)
    result["backend"] = Json(backend.name)
    result["source"] = Json(source)
    result["inputCoordinateSpace"] = Json("source-pixels")
    result["permission"] = Json("unknown")
    result["availability"] = Json("unverified")
    result["requiresHostValidation"] = Json(true)
    result["pause"] = Json(false)
    Json::object(result)
  })
}
