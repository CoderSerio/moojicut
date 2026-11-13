///|
/// Estimate an encoder profile. Actual encoder output can differ from this estimate.
/// Share uses a 25 MiB default budget; quality preserves its pixel-based bitrate.
#export_name("export_profile")
pub fn export_profile(request : String) -> String {
  response(() => {
    let fields = request_object(request)
    let duration = integer_field(fields, "durationMs", 1.0, 604800000.0)
    let width = integer_field(fields, "width", 1.0, 32768.0)
    let height = integer_field(fields, "height", 1.0, 32768.0)
    let share = match fields.get("preset") {
      Some(String("share")) => true
      Some(String("quality")) => false
      _ => raise InputError("invalid_input", "preset must be share or quality")
    }
    let has_audio = match fields.get("hasAudio") {
      Some(True) => true
      Some(False) => false
      _ => raise InputError("invalid_input", "hasAudio must be a boolean")
    }
    let target = match fields.get("targetBytes") {
      None => if share { Some(26214400.0) } else { None }
      Some(_) =>
        Some(integer_field(fields, "targetBytes", 1.0, 1099511627776.0))
    }
    let max_width = if share { 1280.0 } else { 1920.0 }
    let output_width = smaller(width, max_width)
    let output_height = larger(
      1.0,
      @double.round(height * output_width / width),
    )
    let audio_bitrate = if has_audio {
      if share {
        96.0
      } else {
        160.0
      }
    } else {
      0.0
    }
    let baseline = if share {
      larger(
        500.0,
        smaller(6000.0, @double.round(output_width * output_height * 0.00225)),
      )
    } else {
      larger(
        1000.0,
        smaller(20000.0, @double.round(output_width * output_height * 0.003)),
      )
    }
    let video_bitrate = match (share, target) {
      (true, Some(bytes)) => {
        let available = @double.floor(
          bytes * 8.0 / (duration * 1.05) - audio_bitrate,
        )
        larger(250.0, smaller(baseline, available))
      }
      _ => baseline
    }
    // Kbit/s multiplied by milliseconds yields bits; reserve 5% for mux overhead.
    let estimated = @double.ceil(
      (video_bitrate + audio_bitrate) * duration / 8.0 * 1.05,
    )
    let fits = match target {
      Some(bytes) => estimated <= bytes
      None => true
    }
    Json::object({
      "ok": Json(true),
      "videoBitrateKbps": Json(video_bitrate),
      "audioBitrateKbps": Json(audio_bitrate),
      "maxWidth": Json(max_width),
      "estimatedBytes": Json(estimated),
      "fitsTarget": Json(fits),
    })
  })
}
