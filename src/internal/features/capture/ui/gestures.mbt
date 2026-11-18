///|
using @json {type Json}

///|
using @protocol {type InputError}

///|
priv struct Draft {
  id : String
  kind : Int32
  x : Double
  y : Double
  color : String
  opacity : Double
  stroke : Double
  shape : Int
  block : Double
}

///|
priv struct CaptureUI {
  width : Double
  height : Double
  mut draft : Draft?
}

///|
let sessions : Map[Int32, CaptureUI] = Map([])

///|
let next_id : Ref[Int32] = Ref(1)

///|
pub fn open(width : Double, height : Double) -> Int32 {
  if !(width >= 1 && width <= 32768 && height >= 1 && height <= 32768) ||
    sessions.length() >= 64 ||
    next_id.val >= 2147483647 {
    return 0
  }
  let id = next_id.val
  next_id.val += 1
  sessions[id] = { width, height, draft: None, }
  id
}

///|
pub fn close(id : Int32) -> Unit {
  sessions.remove(id)
}

///|
fn number(fields : Map[String, Json], key : String) -> Double raise InputError {
  match fields.get(key) {
    Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 => n
    _ => raise InputError("invalid_input", "Invalid \{key}")
  }
}

///|
fn text(fields : Map[String, Json], key : String) -> String raise InputError {
  match fields.get(key) {
    Some(String(value)) if value.length() > 0 && value.length() <= 256 => value
    _ => raise InputError("invalid_input", "Invalid \{key}")
  }
}

///|
fn clamp(value : Double, maximum : Double) -> Double {
  @protocol.larger(0, @protocol.smaller(maximum, value))
}

///|
fn annotation(s : CaptureUI, draft : Draft, x : Double, y : Double) -> Json {
  let x = clamp(x, s.width)
  let y = clamp(y, s.height)
  let dx = x - draft.x
  let dy = y - draft.y
  let width = dx.abs()
  let height = dy.abs()
  // A click is not a shape. Rectangles/covers need area, while a perfectly
  // horizontal or vertical arrow is valid. Source pixels, independent of zoom.
  if dx * dx + dy * dy < 9 || (draft.kind != 2 && (width < 2 || height < 2)) {
    return Json::null()
  }
  let arrow = draft.kind == 2
  let fields : Map[String, Json] = {
    "id": Json(draft.id),
    "type": Json(
      if arrow {
        "arrow"
      } else if draft.kind == 4 {
        if draft.shape == 2 { "mosaic" } else { "redact" }
      } else {
        if draft.shape == 1 { "ellipse" } else { "rect" }
      },
    ),
    "x": Json(if arrow { draft.x } else { @protocol.smaller(draft.x, x) }),
    "y": Json(if arrow { draft.y } else { @protocol.smaller(draft.y, y) }),
    "width": Json(@protocol.larger(1, width)),
    "height": Json(@protocol.larger(1, height)),
    "color": Json(draft.color),
    "opacity": Json(if draft.kind == 4 && draft.shape == 2 { 1.0 } else { draft.opacity }),
    "stroke": Json(draft.stroke),
  }
  if arrow {
    fields["x2"] = Json(x)
    fields["y2"] = Json(y)
  }
  if draft.kind == 4 && draft.shape == 1 { fields["shape"] = Json("ellipse") }
  if draft.kind == 4 && draft.shape == 2 { fields["blockSize"] = Json(draft.block) }
  Json::object(fields)
}

///|
// Ephemeral interaction state only. A completed gesture returns the same add
// command that an agent can send to image_apply with an expected revision.
pub fn event(request : String) -> String {
  @protocol.response(() => {
    let fields = @protocol.request_object(request)
    let id = @protocol.integer_field(fields, "session", 1, 2147483646).to_int()
    let s = match sessions.get(id) {
      Some(s) => s
      None =>
        raise InputError("closed_session", "Screenshot interaction is closed")
    }
    let mut preview = Json::null()
    let mut command = Json::null()
    match text(fields, "type") {
      "cancel" => s.draft = None
      "begin" => {
        if s.draft is Some(_) {
          raise InputError("busy", "Finish or cancel the current gesture")
        }
        let kind = @protocol.integer_field(fields, "kind", 1, 4).to_int()
        if kind == 3 {
          raise InputError("invalid_tool", "Text uses the input-method adapter")
        }
        let id = text(fields, "id")
        if id.length() > 160 {
          raise InputError("invalid_input", "Annotation id is too long")
        }
        let x = number(fields, "x")
        let y = number(fields, "y")
        let stroke = number(fields, "stroke")
        let opacity = number(fields, "opacity")
        let color = text(fields, "color")
        let shape = if fields.contains("shape") { @protocol.integer_field(fields, "shape", 0, 2).to_int() } else { 0 }
        let block = number(fields, "blockSize")
        let shape_count = @protocol.integer_field(fields, "shapeCount", 0, 3).to_int()
        if (shape != 0 && shape >= shape_count) ||
          !@image.editor_style_value_valid(5, block) {
          raise InputError("invalid_style", "Invalid screenshot shape or mosaic size")
        }
        if !@image.editor_style_value_valid(2, stroke) ||
          !@image.editor_style_value_valid(1, opacity) ||
          color.length() != 7 ||
          !color.has_prefix("#") {
          raise InputError("invalid_style", "Invalid screenshot tool style")
        }
        for i in 1..<7 {
          let c = color[i]
          if !((c >= '0' && c <= '9') ||
            (c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F')) {
            raise InputError("invalid_style", "Invalid screenshot tool color")
          }
        }
        s.draft = Some({
          id,
          kind,
          x: clamp(x, s.width),
          y: clamp(y, s.height),
          color,
          opacity,
          stroke,
          shape,
          block,
        })
      }
      "move" | "end" as phase => {
        let x = number(fields, "x")
        let y = number(fields, "y")
        if s.draft is Some(draft) {
          let candidate = annotation(s, draft, x, y)
          if phase == "end" {
            s.draft = None
            if candidate != Json::null() {
              command = Json::object({
                "type": Json("add"),
                "annotations": Json::array([candidate]),
              })
            }
          } else {
            preview = candidate
          }
        }
      }
      _ => raise InputError("invalid_event", "Unknown screenshot interaction")
    }
    Json::object({
      "ok": Json(true),
      "preview": preview,
      "command": command,
      "active": Json(s.draft is Some(_)),
    })
  })
}
