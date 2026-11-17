///|
// Immutable projections of an already validated document. A media worker gets
// copied values, never the mutable editing session or a second document model.
priv struct MediaPlan {
  width : Int
  height : Int
  quality : Bool
  muted : Bool
  numbers : Array[Double]
  clips : Array[Array[Clip]]
}

///|
let media_plans : Map[Int, MediaPlan] = Map([])

///|
let next_media_plan : Ref[Int] = Ref(1)

///|
pub fn media_plan_open(session_id : Int) -> Int {
  if media_plans.length() >= 64 || next_media_plan.val == 2147483647 {
    return 0
  }
  let project = try load(session(session_id)) catch { _ => return 0 }
  let width = media_number(project.source, "width")
  let height = media_number(project.source, "height")
  let crop = match project.crop {
    Object(crop) => [
      media_number(crop, "x"), media_number(crop, "y"),
      media_number(crop, "width"), media_number(crop, "height"),
    ]
    _ => [0.0, 0.0, width, height]
  }
  let mut end = 0.0
  for clip in project.clips {
    end = @protocol.larger(end, clip.start + clip.duration)
  }
  let numbers = [end, media_number(project.source, "durationMs")]
  numbers.append(crop)
  let handle = next_media_plan.val
  next_media_plan.val += 1
  media_plans[handle] = {
    width: width.to_int(), height: height.to_int(),
    quality: project.preset == "quality", muted: project.muted,
    numbers,
    clips: [media_clips(project, 0), media_clips(project, 1)],
  }
  handle
}

///|
fn media_number(values : Map[String, Json], key : String) -> Double {
  match values.get(key) { Some(Number(value, ..)) => value; _ => -1 }
}

///|
pub fn media_plan_close(handle : Int) -> Unit {
  media_plans.remove(handle)
}

///|
fn media_clips(project : Project, kind : Int) -> Array[Clip] {
  if kind < 0 || kind > 1 { return [] }
  let name = if kind == 0 { "video" } else { "audio" }
  if kind == 1 && project.muted { return [] }
  ordered(project.clips.filter(c => c.kind == name))
}

///|
pub fn media_plan_value(handle : Int, key : Int) -> Int {
  let project = match media_plans.get(handle) {
    Some(project) => project
    None => return -1
  }
  match key {
    0 => project.width
    1 => project.height
    2 => project.clips[0].length()
    3 => project.clips[1].length()
    4 => if project.quality { 1 } else { 0 }
    5 => if project.muted { 1 } else { 0 }
    _ => -1
  }
}

///|
pub fn media_plan_number(handle : Int, key : Int) -> Double {
  let project = match media_plans.get(handle) {
    Some(project) => project
    None => return -1
  }
  if key < 0 || key >= project.numbers.length() { -1 } else { project.numbers[key] }
}

///|
pub fn media_plan_clip_number(
  handle : Int, kind : Int, index : Int, key : Int,
) -> Double {
  let project = match media_plans.get(handle) {
    Some(project) => project
    None => return -1
  }
  if kind < 0 || kind > 1 { return -1 }
  let clips = project.clips[kind]
  if index < 0 || index >= clips.length() { return -1 }
  let clip = clips[index]
  match key {
    0 => clip.start
    1 => clip.source_start
    2 => clip.source_end
    3 => clip.duration
    _ => -1
  }
}
