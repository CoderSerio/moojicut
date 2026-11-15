///|
using @json {type Json}

///|
let frame_ticks : Double = 3000

///|
let max_ticks : Double = 54432000000

///|
priv struct Clip {
  id : String
  kind : String
  source_start : Double
  source_end : Double
  start : Double
  duration : Double
  link : String?
}

///|
priv struct Project {
  source : Map[String, Json]
  mut clips : Array[Clip]
  mut crop : Json
  mut muted : Bool
  preset : String
}

///|
fn text(
  m : Map[String, Json],
  key : String,
) -> String raise @protocol.InputError {
  match m.get(key) {
    Some(String(value)) => value
    _ => raise @protocol.InputError("invalid_input", "\{key} must be text")
  }
}

///|
fn boolean(
  m : Map[String, Json],
  key : String,
  default? : Bool,
) -> Bool raise @protocol.InputError {
  match m.get(key) {
    Some(True) => true
    Some(False) => false
    None =>
      match default {
        Some(value) => value
        None =>
          raise @protocol.InputError("invalid_input", "\{key} must be boolean")
      }
    _ => raise @protocol.InputError("invalid_input", "\{key} must be boolean")
  }
}

///|
fn integer(
  m : Map[String, Json],
  key : String,
  lo : Double,
  hi : Double,
) -> Double raise @protocol.InputError {
  @protocol.integer_field(m, key, lo, hi)
}

///|
fn quantized(
  m : Map[String, Json],
  key : String,
  lo : Double,
  hi : Double,
) -> Double raise @protocol.InputError {
  let value = match m.get(key) {
    Some(Number(value, ..)) if value >= lo && value <= hi => value
    _ =>
      raise @protocol.InputError(
        "invalid_input",
        "\{key} must be finite and within range",
      )
  }
  let result = @double.floor(value / frame_ticks + 0.5) * frame_ticks
  if result < lo || result > hi {
    raise @protocol.InputError(
      "invalid_input",
      "\{key} rounds outside the supported range",
    )
  }
  result
}

///|
fn grid(value : Double) -> Bool {
  value % frame_ticks == 0
}

///|
fn object(value : Json) -> Map[String, Json] raise @protocol.InputError {
  match value {
    Object(m) => m
    _ => raise @protocol.InputError("invalid_input", "Expected an object")
  }
}

///|
fn known_fields(
  m : Map[String, Json],
  allowed : Array[String],
) -> Unit raise @protocol.InputError {
  for key, _ in m {
    if !allowed.contains(key) {
      raise @protocol.InputError(
        "unsupported_field",
        "当前版本无法保留项目字段：\{key}",
      )
    }
  }
}

///|
fn document_object(
  value : String,
) -> Map[String, Json] raise @protocol.InputError {
  if value.length() > 524288 {
    raise @protocol.InputError("invalid_input", "Project is too large")
  }
  let parsed = @json.parse(
    value,
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise @protocol.InputError("invalid_json", "Expected a valid project")
  }
  object(parsed)
}

///|
fn source_metadata(
  source : Map[String, Json],
) -> Map[String, Json] raise @protocol.InputError {
  let duration = integer(source, "durationMs", 34, 604800000)
  {
    "durationMs": Json(duration),
    "width": Json(integer(source, "width", 2, 32768)),
    "height": Json(integer(source, "height", 2, 32768)),
    "hasAudio": Json(boolean(source, "hasAudio")),
  }
}

///|
fn source_limit(
  source : Map[String, Json],
) -> Double raise @protocol.InputError {
  integer(source, "durationMs", 34, 604800000) * 90
}

///|
fn ordinal(id : String, prefix : String) -> Int32 raise @protocol.InputError {
  if id.length() < 2 || !id.has_prefix(prefix) {
    raise @protocol.InputError("invalid_id", "Invalid \{prefix} identifier")
  }
  let n = @string.parse_int(id[1:]) catch {
    _ => raise @protocol.InputError("invalid_id", "Invalid numeric identifier")
  }
  if n < 1 || n >= 1000000000 || id != "\{prefix}\{n}" {
    raise @protocol.InputError("invalid_id", "Invalid numeric identifier")
  }
  n
}

///|
fn clip_json(c : Clip) -> Json {
  Json::object({
    "id": Json(c.id),
    "kind": Json(c.kind),
    "sourceStartTicks": Json(c.source_start),
    "sourceEndTicks": Json(c.source_end),
    "startTicks": Json(c.start),
    "durationTicks": Json(c.duration),
    "linkGroup": match c.link {
      Some(id) => Json(id)
      None => Json::null()
    },
  })
}

///|
fn ordered(clips : Array[Clip]) -> Array[Clip] {
  let result : Array[Clip] = []
  for clip in clips {
    let mut at = result.length()
    for i, other in result {
      if clip.start < other.start ||
        (clip.start == other.start && clip.id < other.id) {
        at = i
        break
      }
    }
    result.insert(at, clip)
  }
  result
}

///|
fn document_json(p : Project, next_id : Int32, revision : Double) -> Json {
  Json::object({
    "schemaVersion": Json(2),
    "timebase": Json(90000),
    "frameRate": Json::object({ "num": Json(30), "den": Json(1) }),
    "source": Json::object(p.source),
    "clips": Json::array(ordered(p.clips).map(clip_json)),
    "crop": p.crop,
    "muted": Json(p.muted),
    "preset": Json(p.preset),
    "nextId": Json(next_id),
    "revision": Json(revision),
  })
}

///|
fn plan_json(p : Project) -> Json {
  let video : Array[Json] = []
  let audio : Array[Json] = []
  let mut end = 0.0
  for c in ordered(p.clips) {
    end = @protocol.larger(end, c.start + c.duration)
    if c.kind == "video" {
      video.push(clip_json(c))
    } else if !p.muted {
      audio.push(clip_json(c))
    }
  }
  Json::object({
    "schemaVersion": Json(2),
    "timebase": Json(90000),
    "frameRate": Json::object({ "num": Json(30), "den": Json(1) }),
    "source": Json::object(p.source),
    "outputDurationTicks": Json(end),
    "video": Json::array(video),
    "audio": Json::array(audio),
    "crop": p.crop,
    "muted": Json(p.muted),
    "preset": Json(p.preset),
  })
}

///|
fn validate(p : Project) -> Unit raise @protocol.InputError {
  let limit = source_limit(p.source)
  let ids : Map[String, Bool] = Map([])
  let groups : Map[String, Array[Clip]] = Map([])
  let mut videos = 0
  let mut audios = 0
  for c in p.clips {
    if c.kind != "video" && c.kind != "audio" {
      raise @protocol.InputError("invalid_clip", "Unknown clip kind")
    }
    ignore(ordinal(c.id, if c.kind == "video" { "v" } else { "a" }))
    if ids.contains(c.id) {
      raise @protocol.InputError("invalid_id", "Duplicate clip identifier")
    }
    ids[c.id] = true
    if c.source_start < 0 ||
      c.source_end > limit ||
      c.source_end - c.source_start < frame_ticks ||
      c.duration < frame_ticks ||
      c.start < 0 ||
      c.start + c.duration > max_ticks ||
      !grid(c.start) ||
      !grid(c.duration) {
      raise @protocol.InputError(
        "invalid_clip", "Clip bounds must preserve at least one source/output frame and the output grid",
      )
    }
    let rate = (c.source_end - c.source_start) / c.duration
    // A split rounds one derived source boundary by at most half a 90k tick.
    // Permit that quantization at the configured endpoints, not arbitrary rates.
    let epsilon = 0.5 / c.duration
    if rate < 0.25 - epsilon || rate > 4 + epsilon {
      raise @protocol.InputError(
        "unsupported_speed", "帧量化后的片段速度超出 0.25–4 倍范围。",
      )
    }
    if c.kind == "video" {
      videos = videos + 1
    } else {
      audios = audios + 1
      if !boolean(p.source, "hasAudio") {
        raise @protocol.InputError("invalid_clip", "Source has no audio")
      }
      if rate < 1 - epsilon {
        raise @protocol.InputError(
          "unsupported_audio_slowdown", "有声慢放暂不支持，可先解除关联并保留原速音频",
        )
      }
    }
    match c.link {
      Some(group) => {
        ignore(ordinal(group, "g"))
        match groups.get(group) {
          Some(members) => members.push(c)
          None => groups[group] = [c]
        }
      }
      None => ()
    }
  }
  if videos == 0 {
    raise @protocol.InputError(
      "empty_output", "至少保留一个视频片段。",
    )
  }
  if videos > 256 || audios > 256 {
    raise @protocol.InputError(
      "clip_limit", "At most 256 video and 256 audio clips",
    )
  }
  let sorted = ordered(p.clips.filter(c => c.kind == "video"))
  let mut previous_end = 0.0
  for c in sorted {
    if c.start < previous_end {
      raise @protocol.InputError(
        "overlap", "视频片段发生重叠，请启用合拢或调整位置。",
      )
    }
    previous_end = c.start + c.duration
  }
  for _, members in groups {
    if members.length() != 2 {
      raise @protocol.InputError(
        "invalid_link", "A link group must contain one video and one audio clip",
      )
    }
    let a = members[0]
    let b = members[1]
    if a.kind == b.kind ||
      a.start != b.start ||
      a.duration != b.duration ||
      a.source_start != b.source_start ||
      a.source_end != b.source_end {
      raise @protocol.InputError(
        "invalid_link", "Linked clips must retain the same source/output timing",
      )
    }
  }
}

///|
fn crop_value(
  m : Map[String, Json],
  source : Map[String, Json],
) -> Json raise @protocol.InputError {
  @video.normalize_crop(
    integer(source, "width", 2, 32768),
    integer(source, "height", 2, 32768),
    m.get("crop").unwrap_or(Json::null()),
  )
}

///|
fn read_project(
  source : Map[String, Json],
  m : Map[String, Json],
) -> (Project, Int32, Double) raise @protocol.InputError {
  known_fields(m, [
    "schemaVersion", "timebase", "frameRate", "source", "clips", "crop", "muted",
    "preset", "nextId", "revision",
  ])
  ignore(integer(m, "schemaVersion", 2, 2))
  ignore(integer(m, "timebase", 90000, 90000))
  let fps = @protocol.object_field(m, "frameRate")
  ignore(integer(fps, "num", 30, 30))
  ignore(integer(fps, "den", 1, 1))
  if source_metadata(@protocol.object_field(m, "source")) != source {
    raise @protocol.InputError(
      "source_mismatch", "Draft source metadata does not match the opened source",
    )
  }
  let next_id = integer(m, "nextId", 2, 1000000000).to_int()
  let revision = integer(m, "revision", 0, 9007199254740990)
  let clips : Array[Clip] = []
  let values = match m.get("clips") {
    Some(Array(values)) if values.length() <= 512 => values
    _ =>
      raise @protocol.InputError("invalid_input", "Expected at most 512 clips")
  }
  for value in values {
    let c = object(value)
    known_fields(c, [
      "id", "kind", "sourceStartTicks", "sourceEndTicks", "startTicks", "durationTicks",
      "linkGroup",
    ])
    let kind = text(c, "kind")
    if kind != "video" && kind != "audio" {
      raise @protocol.InputError("invalid_clip", "Unknown clip kind")
    }
    let id = text(c, "id")
    let n = ordinal(id, if kind == "video" { "v" } else { "a" })
    let link = match c.get("linkGroup") {
      Some(Null) => None
      Some(String(group)) => {
        if ordinal(group, "g") >= next_id {
          raise @protocol.InputError(
            "invalid_id", "nextId must exceed all identifiers",
          )
        }
        Some(group)
      }
      _ =>
        raise @protocol.InputError(
          "invalid_link", "linkGroup must be text or null",
        )
    }
    if n >= next_id {
      raise @protocol.InputError(
        "invalid_id", "nextId must exceed all identifiers",
      )
    }
    clips.push({
      id,
      kind,
      source_start: integer(c, "sourceStartTicks", 0, max_ticks),
      source_end: integer(c, "sourceEndTicks", frame_ticks, max_ticks),
      start: integer(c, "startTicks", 0, max_ticks),
      duration: integer(c, "durationTicks", frame_ticks, max_ticks),
      link,
    })
  }
  let preset = text(m, "preset")
  if preset != "share" && preset != "quality" {
    raise @protocol.InputError("invalid_input", "Unknown preset")
  }
  let p = {
    source,
    clips,
    crop: crop_value(m, source),
    muted: boolean(m, "muted"),
    preset,
  }
  validate(p)
  (p, next_id, revision)
}
