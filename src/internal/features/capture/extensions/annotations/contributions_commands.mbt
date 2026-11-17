///|
using @json {type Json}

///|
using @protocol {type InputError}

///|
// Built-in command handlers produce existing document operations. They do not
// own a second image document or ask a platform to invent new drawing types.
pub fn contribution_drag_command(
  name : String,
  rectangle : Json,
  existing : Array[Json],
) -> Json raise InputError {
  if name != "capture.numberedRectangle" {
    raise InputError(
      "unsupported_command", "Unknown screenshot contribution command",
    )
  }
  let fields = match rectangle {
    Object(fields) => fields
    _ => raise InputError("invalid_input", "Expected a rectangle gesture")
  }
  let number = (key : String) => {
    match fields.get(key) {
      Some(Number(value, ..)) => value
      _ => 1.0 / 0.0
    }
  }
  let x = number("x")
  let y = number("y")
  let width = number("width")
  let height = number("height")
  if !(x >= 0 &&
    x <= 65536 &&
    y >= 0 &&
    y <= 65536 &&
    width > 0 &&
    width <= 65536 &&
    height > 0 &&
    height <= 65536) {
    raise InputError("invalid_input", "Invalid contribution rectangle")
  }
  let ids : Map[String, Bool] = Map([])
  let mut ordinal = 1
  for annotation in existing {
    if annotation is Object(annotation) {
      if annotation.get("id") is Some(String(id)) {
        ids[id] = true
      }
      if annotation.get("contribution") == Some(Json(name)) &&
        annotation.get("number") is Some(Number(n, ..)) &&
        n >= 1 &&
        n <= 10000 &&
        n == n.to_int().to_double() {
        ordinal = @protocol.larger(ordinal.to_double(), n + 1).to_int()
      }
    }
  }
  while ordinal <= 10000 &&
        (
          ids.contains("numbered-\{ordinal}-frame") ||
          ids.contains("numbered-\{ordinal}-label")
        ) {
    ordinal += 1
  }
  if ordinal > 10000 {
    raise InputError("limit_exceeded", "Too many numbered rectangles")
  }
  let base : Map[String, Json] = {
    "id": Json("numbered-\{ordinal}-frame"),
    "type": Json("rect"),
    "x": Json(x),
    "y": Json(y),
    "width": Json(width),
    "height": Json(height),
    "color": fields.get("color").unwrap_or(Json("#f26769")),
    "stroke": fields.get("stroke").unwrap_or(Json(4)),
    "opacity": fields.get("opacity").unwrap_or(Json(1)),
    "contribution": Json(name),
    "number": Json(ordinal),
  }
  let inset = @protocol.smaller(4, @protocol.smaller(width, height) / 4)
  let label_width = width - 2 * inset
  let label_height = height - 2 * inset
  let text = ordinal.to_string()
  // Reserve a full em per digit and room for native line metrics. The same
  // geometry must remain legible in all three renderers, including clipped
  // Windows text. A tiny gesture is rejected without publishing any history.
  let font_size = @protocol.smaller(
    24,
    @protocol.smaller(label_width / text.length().to_double(), label_height / 1.5),
  )
  if font_size < 8 {
    raise InputError("invalid_input", "Rectangle is too small for its number")
  }
  let label : Map[String, Json] = {
    "id": Json("numbered-\{ordinal}-label"),
    "type": Json("text"),
    "x": Json(x + inset),
    "y": Json(y + inset),
    "width": Json(label_width),
    "height": Json(label_height),
    "color": base["color"],
    "stroke": base["stroke"],
    "opacity": base["opacity"],
    "fontSize": Json(font_size),
    "text": Json(text),
    "contribution": Json(name),
    "number": Json(ordinal),
  }
  Json::object({
    "type": Json("add"),
    "annotations": Json::array([Json::object(base), Json::object(label)]),
  })
}

///|
// JSON hosts and the typed session bridge use the same handler. This produces
// a validated candidate command; only the caller's normal image_apply commit
// publishes it. expectedRevision is required to reject a stale gesture.
pub fn contribution_command_json(request : String) -> String {
  @protocol.response(() => {
    if request.length() > 33554432 {
      raise InputError("invalid_input", "Contribution request too large")
    }
    let fields = match
      (@json.parse(request, max_nesting_depth=32, reject_duplicate_keys=true) catch {
        _ => raise InputError("invalid_json", "Expected contribution JSON")
      }) {
      Object(fields) => fields
      _ => raise InputError("invalid_input", "Expected contribution object")
    }
    let doc = match fields.get("document") {
      Some(Object(doc)) => doc
      _ => raise InputError("invalid_input", "Expected current image document")
    }
    let existing = match doc.get("annotations") {
      Some(Array(items)) => items
      _ => []
    }
    let name = match fields.get("command") {
      Some(String(s)) => s
      _ => ""
    }
    let source_width = @protocol.integer_field(doc, "width", 1, 32768)
    let source_height = @protocol.integer_field(doc, "height", 1, 32768)
    // A native gesture has already been normalized to the image canvas. JSON
    // callers must supply that same in-bounds rectangle, not off-canvas shapes.
    let rectangle = fields.get("rectangle").unwrap_or(Json::null())
    match rectangle {
      Object({ "x": Number(x, ..), "y": Number(y, ..),
        "width": Number(width, ..), "height": Number(height, ..), .. }) => {
        if !(x >= 0 && y >= 0 && width > 0 && height > 0 &&
          x + width <= source_width && y + height <= source_height) {
          raise InputError("invalid_input", "Contribution rectangle is outside the image")
        }
      }
      _ => raise InputError("invalid_input", "Expected a normalized rectangle")
    }
    let command = contribution_drag_command(
      name,
      rectangle,
      existing,
    )
    let revision = fields.get("expectedRevision").unwrap_or(Json::null())
    let validation = @json.parse(
      @image.image_apply(
        Json::object({
          "document": Json::object(doc),
          "expectedRevision": revision,
          "command": command,
        }).stringify(),
      ),
    ) catch {
      _ => raise InputError("invalid_input", "Image validation failed")
    }
    match validation {
      Object({ "ok": True, .. }) =>
        Json::object({ "ok": Json(true), "command": command })
      Object(
        {
          "error": Object(
            { "code": String(code), "message": String(message), .. }
          ),
          ..
        }
      ) => raise InputError(code, message)
      _ => raise InputError("invalid_input", "Image validation failed")
    }
  })
}
