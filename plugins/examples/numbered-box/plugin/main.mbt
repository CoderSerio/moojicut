///|
using @json {type Json}

///|
fn numbered_box(id : String, selection : Json) -> Json? {
  let (x, y, width, height) = match selection {
    Object(
      {
        "x": Number(x, ..),
        "y": Number(y, ..),
        "width": Number(width, ..),
        "height": Number(height, ..),
        ..
      }
    ) if x >= 0 && y >= 0 && width >= 12 && height >= 18 =>
      (x, y, width, height)
    _ => return None
  }
  let color = Json("#ef4444")
  let size = if height >= 50 && width >= 30 { 22 } else { 10 }
  let frame = Json::object({
    "type": Json("rect"),
    "x": Json(x),
    "y": Json(y),
    "width": Json(width),
    "height": Json(height),
    "color": color,
    "stroke": Json(3),
  })
  let label = Json::object({
    "type": Json("text"),
    "x": Json(x + 2),
    "y": Json(y + 2),
    "width": Json(width - 4),
    "height": Json(height - 4),
    "color": color,
    "fontSize": Json(size),
    "text": Json("1"),
  })
  Some(
    Json::object({
      "apiVersion": Json(2),
      "invocationId": Json(id),
      "kind": Json("annotations"),
      "annotations": Json::array([frame, label]),
    }),
  )
}

///|
fn respond(input : Json) -> Json? {
  match input {
    Object(
      { "apiVersion": Number(version, ..), "operation": String("health"), .. }
    ) if version == 2 =>
      Some(
        Json::object({
          "apiVersion": Json(2),
          "operation": Json("health"),
          "toolIds": Json::array([Json("numbered-box"), Json("describe")]),
        }),
      )
    Object(
      {
        "apiVersion": Number(version, ..),
        "operation": String("invoke"),
        "invocationId": String(id),
        "toolId": String("numbered-box"),
        "selection": selection,
        ..
      }
    ) if version == 2 => numbered_box(id, selection)
    Object(
      {
        "apiVersion": Number(version, ..),
        "operation": String("invoke"),
        "invocationId": String(id),
        "toolId": String("describe"),
        "capture": Object(
          { "width": Number(width, ..), "height": Number(height, ..), .. }
        ),
        ..
      }
    ) if version == 2 =>
      Some(
        Json::object({
          "apiVersion": Json(2),
          "invocationId": Json(id),
          "kind": Json("text"),
          "title": Json("截图尺寸"),
          "text": Json("\{width.to_int()} × \{height.to_int()} 像素"),
        }),
      )
    _ => None
  }
}

///|
pub fn mooji_run() -> Int32 {
  let input = @json.parse(
    @host.input_string(),
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => {
      @host.set_error("Invalid Mooji Cut request JSON")
      return 1
    }
  }
  match respond(input) {
    Some(result) => {
      @host.output_string(result.stringify())
      0
    }
    None => {
      @host.set_error("Unsupported request or rectangle too small for a label")
      1
    }
  }
}
