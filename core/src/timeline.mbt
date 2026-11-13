///|
fn append_segment(
  segments : Array[Json],
  start : Double,
  end : Double,
  output_start : Double,
) -> Double {
  if end <= start {
    return output_start
  }
  let output_end = output_start + end - start
  segments.push(
    Json::object({
      "sourceStartMs": Json(start),
      "sourceEndMs": Json(end),
      "outputStartMs": Json(output_start),
      "outputEndMs": Json(output_end),
    }),
  )
  output_end
}

///|
/// Retain a trim range and optionally remove one source-time interval.
/// Times are integer milliseconds, bounded to seven days. Endpoints are exclusive.
#export_name("edit_plan")
pub fn edit_plan(request : String) -> String {
  response(() => {
    let fields = request_object(request)
    let duration = integer_field(fields, "durationMs", 1.0, 604800000.0)
    let trim = object_field(fields, "trim")
    let start = integer_field(trim, "startMs", 0.0, duration)
    let end = integer_field(trim, "endMs", 0.0, duration)
    if start >= end {
      raise InputError("invalid_range", "Trim start must precede trim end")
    }
    let segments : Array[Json] = []
    let output_duration = match fields.get("cut") {
      None | Some(Null) => append_segment(segments, start, end, 0.0)
      Some(Object(cut)) => {
        let cut_start = integer_field(cut, "startMs", 0.0, duration)
        let cut_end = integer_field(cut, "endMs", 0.0, duration)
        if cut_start >= cut_end {
          raise InputError("invalid_range", "Cut start must precede cut end")
        }
        let overlap_start = larger(start, cut_start)
        let overlap_end = smaller(end, cut_end)
        if overlap_start >= overlap_end {
          append_segment(segments, start, end, 0.0)
        } else {
          let cursor = append_segment(segments, start, overlap_start, 0.0)
          append_segment(segments, overlap_end, end, cursor)
        }
      }
      _ => raise InputError("invalid_input", "cut must be an object or null")
    }
    if output_duration <= 0.0 {
      raise InputError(
        "empty_output", "The cut removes the entire trimmed clip",
      )
    }
    Json::object({
      "ok": Json(true),
      "segments": Json::array(segments),
      "outputDurationMs": Json(output_duration),
    })
  })
}
