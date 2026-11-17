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
fn timeline_plan(fields : Map[String, Json]) -> Json raise @protocol.InputError {
  let duration = @protocol.integer_field(fields, "durationMs", 1.0, 604800000.0)
  let trim = @protocol.object_field(fields, "trim")
  let start = @protocol.integer_field(trim, "startMs", 0.0, duration)
  let end = @protocol.integer_field(trim, "endMs", 0.0, duration)
  if start >= end {
    raise @protocol.InputError("invalid_range", "起点必须早于终点")
  }
  let cuts : Array[(Double, Double)] = []
  fn add_cut(value : Json) -> Unit raise @protocol.InputError {
    match value {
      Object(cut) => {
        let a = @protocol.integer_field(cut, "startMs", 0.0, duration)
        let b = @protocol.integer_field(cut, "endMs", 0.0, duration)
        if a >= b { raise @protocol.InputError("invalid_range", "删除片段的起点必须早于终点") }
        cuts.push((a, b))
      }
      _ => raise @protocol.InputError("invalid_input", "删除片段必须为时间区间")
    }
  }
  match fields.get("cut") {
    None | Some(Null) => ()
    Some(Object(_) as cut) => add_cut(cut)
    _ => raise @protocol.InputError("invalid_input", "cut must be an object or null")
  }
  match fields.get("cuts") {
    None => ()
    Some(Array(items)) => {
      if items.length() > 99 { raise @protocol.InputError("invalid_input", "最多支持 99 个删除区间") }
      for cut in items { add_cut(cut) }
    }
    _ => raise @protocol.InputError("invalid_input", "cuts must be an array")
  }
  cuts.sort_by_key(pair => pair.0)
  let segments : Array[Json] = []
  let mut cursor = start
  let mut output = 0.0
  for (a, b) in cuts {
    if b <= cursor || a >= end { continue }
    output = append_segment(segments, cursor, @protocol.smaller(a, end), output)
    cursor = @protocol.larger(cursor, @protocol.smaller(b, end))
  }
  output = append_segment(segments, cursor, end, output)
  if output <= 0.0 { raise @protocol.InputError("empty_output", "至少保留一段内容") }
  Json::object({ "ok": Json(true), "segments": Json::array(segments), "outputDurationMs": Json(output) })
}

///|
/// Keep source-order segments after subtracting any number of overlapping cuts.
/// Legacy `cut` remains accepted alongside the new `cuts` array.
pub fn edit_plan(request : String) -> String {
  @protocol.response(() => timeline_plan(@protocol.request_object(request)))
}
