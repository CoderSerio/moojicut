///|
let frames : Map[Int32, Frame] = Map([])

///|
let next_frame : Ref[Int32] = Ref(1)

///|
pub fn open(json : String) -> Int32 {
  if frames.length() >= 64 || next_frame.val >= 2147483647 {
    return 0
  }
  let frame = decode(json) catch { _ => return 0 }
  let handle = next_frame.val
  next_frame.val += 1
  frames[handle] = frame
  handle
}

///|
pub fn close(handle : Int32) -> Int32 {
  if !frames.contains(handle) {
    return 0
  }
  frames.remove(handle)
  1
}

///|
pub fn value(handle : Int32, field : Int32) -> Int32 {
  let frame = match frames.get(handle) {
    Some(frame) => frame
    None => return -1
  }
  match field {
    0 => frame.cursor
    1 => if frame.video is Some(_) { 1 } else { 0 }
    _ => -1
  }
}

///|
pub fn video_rect(handle : Int32, field : Int32) -> Double {
  match frames.get(handle) {
    Some({ video: Some(rect), .. }) if field >= 0 && field < 4 => rect[field]
    _ => 0
  }
}

///|
fn layer(handle : Int32, layer : Int32) -> Array[Draw]? {
  match frames.get(handle) {
    Some(frame) if layer >= 0 && layer < 2 => Some(frame.layers[layer])
    _ => None
  }
}

///|
pub fn command_count(handle : Int32, plane : Int32) -> Int32 {
  match layer(handle, plane) {
    Some(items) => items.length()
    None => -1
  }
}

///|
fn command(handle : Int32, plane : Int32, index : Int32) -> Draw? {
  match layer(handle, plane) {
    Some(items) if index >= 0 && index < items.length() => Some(items[index])
    _ => None
  }
}

///|
pub fn command_value(
  handle : Int32,
  plane : Int32,
  index : Int32,
  field : Int32,
) -> Int32 {
  match command(handle, plane, index) {
    Some(item) if field >= 0 && field < item.integers.length() =>
      item.integers[field]
    _ => -1
  }
}

///|
pub fn command_number(
  handle : Int32,
  plane : Int32,
  index : Int32,
  field : Int32,
) -> Double {
  match command(handle, plane, index) {
    Some(item) if field >= 0 && field < item.numbers.length() =>
      item.numbers[field]
    _ => 0
  }
}

///|
pub fn command_text(handle : Int32, plane : Int32, index : Int32) -> String {
  match command(handle, plane, index) {
    Some(item) => item.text
    None => ""
  }
}

///|
pub fn semantic_count(handle : Int32) -> Int32 {
  match frames.get(handle) {
    Some(frame) => frame.semantics.length()
    None => -1
  }
}

///|
fn node(handle : Int32, index : Int32) -> Semantic? {
  match frames.get(handle) {
    Some(frame) if index >= 0 && index < frame.semantics.length() =>
      Some(frame.semantics[index])
    _ => None
  }
}

///|
pub fn semantic_value(handle : Int32, index : Int32, field : Int32) -> Int32 {
  match node(handle, index) {
    Some(item) if field >= 0 && field < item.integers.length() =>
      item.integers[field]
    _ => -1
  }
}

///|
pub fn semantic_number(handle : Int32, index : Int32, field : Int32) -> Double {
  match node(handle, index) {
    Some(item) if field >= 0 && field < item.numbers.length() =>
      item.numbers[field]
    _ => 0
  }
}

///|
pub fn semantic_text(handle : Int32, index : Int32, field : Int32) -> String {
  match node(handle, index) {
    Some(item) if field >= 0 && field < item.texts.length() => item.texts[field]
    _ => ""
  }
}
