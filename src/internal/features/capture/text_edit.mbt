///|
using @protocol {type InputError}

///|
priv struct TextEdit {
  session : Int32
  style : Int32
  style_revision : Int32
  base_revision : Double
  mode : Int32
  tool : Int32
  contribution_command : String
  annotation_id : String
  original : Json
  x : Double
  y : Double
  width : Double
  height : Double
  body : Int32
  opacity : Int32
  font : Int32
  stroke : Int32
  shape : Int32
  block : Int32
  initial_opacity : Double
  initial_font : Double
  initial_stroke : Double
  initial_shape : Double
  initial_block : Double
  initial_body : String
  mut version : Int32
  mut color : Int32
  mut preview_opacity : Double
  mut preview_font : Double
  mut preview_stroke : Double
  mut preview_shape : Double
  mut preview_block : Double
  mut active_field : String
  mut color_pressed : String
  mut color_hovered : String
}

///|
let text_edits : Map[Int32, TextEdit] = Map([])

///|
let text_active : Map[Int32, Int32] = Map([])

///|
let text_next_edit : Ref[Int32] = Ref(1)

///|
fn text_current(session : Int32, edit : Int32) -> TextEdit? {
  if !native_image_sessions.contains(session) ||
    text_active.get(session) != Some(edit) {
    return None
  }
  match text_edits.get(edit) {
    Some(e) if e.session == session => Some(e)
    _ => None
  }
}

///|
fn text_fresh(e : TextEdit) -> Bool {
  image_session_revision(e.session) == e.base_revision &&
  (match editor_style_sessions.get(e.style) {
    Some(bank) => bank.revision == e.style_revision
    None => false
  })
}

///|
fn text_field(e : TextEdit, id : String) -> Int32 {
  match id {
    "annotation.text" => e.body
    "style.opacity" => e.opacity
    "style.fontSize" => e.font
    "style.stroke" => e.stroke
    "style.shape" => e.shape
    "style.blockSize" => e.block
    _ => 0
  }
}

///|
fn text_raw(token : Int32) -> String {
  match @fields.snapshot(token) {
    Some(s) => s.raw
    None => ""
  }
}

///|
fn text_retire(edit : Int32) -> Unit {
  match text_edits.get(edit) {
    Some(e) => {
      for field in property_tokens(e) {
        ignore(@fields.close(field))
      }
      text_active.remove(e.session)
      text_edits.remove(edit)
    }
    None => ()
  }
}

///|
fn text_dispose_session(session : Int32) -> Unit {
  match text_active.get(session) {
    Some(e) => text_retire(e)
    None => ()
  }
  candidate_retire_session(session)
}

///|
/// mode 0 edits text-tool defaults, 1 creates a new annotation, 2 edits a stable
/// existing text ID. No document/default mutation occurs until candidate commit.
/// The style handle is borrowed and must remain live until commit/cancel.
pub fn text_begin(
  session : Int32,
  style : Int32,
  mode : Int32,
  annotation_id : String,
  revision : Double,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Int32 {
  capture_edit_begin(
    session, style, 3, mode, annotation_id, revision, x, y, width, height, "",
  )
}

///|
pub fn properties_begin(
  session : Int32,
  style : Int32,
  tool : Int32,
  annotation_id : String,
  revision : Double,
  contribution_command : String,
) -> Int32 {
  if ![1, 2, 4].contains(tool) ||
    !@annotation_tools.property_context_valid(tool, contribution_command) ||
    (annotation_id != "" && contribution_command != "") {
    return 0
  }
  capture_edit_begin(
    session,
    style,
    tool,
    if annotation_id == "" {
      0
    } else {
      2
    },
    annotation_id,
    revision,
    0,
    0,
    1,
    1,
    contribution_command,
  )
}

///|
fn capture_edit_begin(
  session : Int32,
  style : Int32,
  tool : Int32,
  mode : Int32,
  annotation_id : String,
  revision : Double,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
  contribution_command : String,
) -> Int32 {
  let s = match native_image_sessions.get(session) {
    Some(s) => s
    None => return 0
  }
  let bank = match editor_style_sessions.get(style) {
    Some(s) => s
    None => return 0
  }
  if mode < 0 ||
    mode > 2 ||
    text_active.contains(session) ||
    text_next_edit.val >= 2147483647 ||
    image_session_revision(session) != revision {
    return 0
  }
  let original = if mode == 2 {
    let mut found = Json::null()
    for item in native_image_annotations(session) {
      if item is Object(a) {
        if image_string(a, "id", "") == annotation_id &&
          native_annotation_value(a, 0).to_int() == tool {
          found = item
        }
      }
    }
    if found == Json::null() {
      return 0
    }
    found
  } else {
    Json::null()
  }
  if mode == 1 && annotation_id != "" {
    return 0
  }
  let original_fields = match original {
    Object(a) => a
    _ => Map([])
  }
  let x = if mode == 2 {
    image_number(original_fields, "x", 0)
  } else if mode == 0 {
    0
  } else {
    x
  }
  let y = if mode == 2 {
    image_number(original_fields, "y", 0)
  } else if mode == 0 {
    0
  } else {
    y
  }
  let width = if mode == 2 {
    native_annotation_value(original_fields, 3)
  } else if mode == 0 {
    1
  } else {
    width
  }
  let height = if mode == 2 {
    native_annotation_value(original_fields, 4)
  } else if mode == 0 {
    1
  } else {
    height
  }
  let image_width = image_number(s.document, "width", 0)
  let image_height = image_number(s.document, "height", 0)
  // Existing annotations are already checked by the document reducer and may
  // intentionally cross an image edge after move/resize. Do not apply new-tool
  // placement constraints again when reopening them.
  if mode != 2 &&
    !(x >= 0 &&
    x < image_width &&
    y >= 0 &&
    y < image_height &&
    width > 0 &&
    width <= image_width - x &&
    height > 0 &&
    height <= image_height - y) {
    return 0
  }
  let values = bank.tools[tool]
  let color = if mode == 2 {
    native_annotation_value(original_fields, 5).to_int()
  } else {
    values.color
  }
  let opacity_value = if mode == 2 {
    image_number(original_fields, "opacity", 1)
  } else {
    values.opacity
  }
  let font_value = if mode == 2 {
    image_number(original_fields, "fontSize", 24)
  } else {
    values.font
  }
  let initial = if mode == 2 {
    image_string(original_fields, "text", "")
    .replace_all(old="\r\n", new="\n")
    .replace_all(old="\r", new="\n")
  } else {
    ""
  }
  let stroke_value = if mode == 2 {
    image_number(original_fields, "stroke", 3)
  } else {
    values.stroke
  }
  let shape_value = if contribution_command != "" {
    0.0
  } else if mode == 2 {
    native_annotation_value(original_fields, 9)
  } else {
    values.shape
  }
  let block_value = if mode == 2 {
    image_number(original_fields, "blockSize", 12)
  } else {
    values.block
  }
  let body = if mode == 0 || tool != 3 {
    0
  } else {
    @fields.open(
      "annotation.text",
      initial,
      10000,
      @fields.Directed(initial.length(), initial.length()),
    )
  }
  if mode != 0 && tool == 3 && body == 0 {
    return 0
  }
  let opacity_text = text_decimal(opacity_value * 100)
  let opacity = @fields.open("style.opacity", opacity_text, 64, @fields.Unknown)
  let font_text = text_decimal(font_value)
  let font = if tool == 3 {
    @fields.open("style.fontSize", font_text, 64, @fields.Unknown)
  } else {
    0
  }
  let stroke = if tool == 1 || tool == 2 {
    @fields.open(
      "style.stroke",
      text_decimal(stroke_value),
      64,
      @fields.Unknown,
    )
  } else {
    0
  }
  let shape = if (tool == 1 || tool == 4) && contribution_command == "" {
    @fields.open("style.shape", text_decimal(shape_value), 64, @fields.Unknown)
  } else {
    0
  }
  let block = if tool == 4 {
    @fields.open(
      "style.blockSize",
      text_decimal(block_value),
      64,
      @fields.Unknown,
    )
  } else {
    0
  }
  if opacity == 0 ||
    (tool == 3 && font == 0) ||
    ((tool == 1 || tool == 2) && stroke == 0) ||
    ((tool == 1 || tool == 4) && contribution_command == "" && shape == 0) ||
    (tool == 4 && block == 0) {
    for token in [body, opacity, font, stroke, shape, block] {
      ignore(@fields.close(token))
    }
    return 0
  }
  let edit = text_next_edit.val
  text_next_edit.val += 1
  let annotation_id = if mode == 1 {
    "text-\{session}-\{edit}"
  } else if mode == 0 {
    ""
  } else {
    annotation_id
  }
  // A checked command may have supplied its own ID, including our prefix.
  if mode == 1 {
    for item in native_image_annotations(session) {
      if item is Object(a) && image_string(a, "id", "") == annotation_id {
        for token in [body, opacity, font, stroke, shape, block] {
          ignore(@fields.close(token))
        }
        return 0
      }
    }
  }
  text_edits[edit] = {
    session,
    style,
    style_revision: bank.revision,
    base_revision: revision,
    mode,
    tool,
    contribution_command,
    annotation_id,
    original,
    x,
    y,
    width,
    height,
    body,
    opacity,
    font,
    stroke,
    shape,
    block,
    initial_stroke: stroke_value,
    initial_shape: shape_value,
    initial_block: block_value,
    initial_opacity: opacity_value,
    initial_font: font_value,
    initial_body: initial,
    version: 0,
    color,
    preview_opacity: opacity_value,
    preview_font: font_value,
    preview_stroke: stroke_value,
    preview_shape: shape_value,
    preview_block: block_value,
    active_field: if mode == 0 || tool != 3 {
      ""
    } else {
      "annotation.text"
    },
    color_pressed: "",
    color_hovered: "",
  }
  text_active[session] = edit
  candidate_retire_session(session)
  edit
}

///|
/// Cancel also works after an unrelated document/style change, so stale drafts
/// can be retired; it still checks the exact live edit version.
pub fn text_cancel(session : Int32, edit : Int32, version : Int32) -> Int32 {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return 0
  }
  if e.version != version {
    return 0
  }
  text_retire(edit)
  candidate_retire_session(session)
  1
}

///|
pub fn text_event_json(
  session : Int32,
  edit : Int32,
  version : Int32,
  event : String,
) -> Int32 {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return 0
  }
  if !text_fresh(e) || e.version != version || e.version >= 2147483647 {
    return 0
  }
  let event = @protocol.request_object(event) catch { _ => return 0 }
  match image_string(event, "type", "") {
    "field" => {
      let id = image_string(event, "id", "")
      let token = text_field(e, id)
      if token == 0 || !property_visible(e, id) || id == "style.shape" {
        return 0
      }
      let supplied = @protocol.integer_field(event, "token", 1, 2147483646) catch {
        _ => return 0
      }
      let field_version = @protocol.integer_field(
        event, "expectedVersion", 0, 2147483647,
      ) catch {
        _ => return 0
      }
      if supplied.to_int() != token {
        return 0
      }
      let raw_edit = @protocol.object_field(event, "edit") catch {
        _ => return 0
      }
      // Native bridges normalize CRLF and their offsets before sending input.
      // Normalizing here would silently invalidate the supplied UTF-16 ranges.
      if image_string(raw_edit, "text", "").contains("\r") {
        return 0
      }
      let action = text_decode_edit(raw_edit) catch { _ => return 0 }
      if !@fields.apply(token, id, field_version.to_int(), action) {
        return 0
      }
      e.active_field = id
    }
    "color" => {
      if !property_visible(e, "style.color") {
        return 0
      }
      let rgb = @protocol.integer_field(event, "rgb", 0, 16777215) catch {
        _ => return 0
      }
      e.color = rgb.to_int()
    }
    "step" => {
      let id = image_string(event, "id", "")
      let property = property_key(id)
      if ![1, 2, 3, 5].contains(property) || !property_visible(e, id) {
        return 0
      }
      let delta = @protocol.integer_field(event, "delta", -1, 1) catch {
        _ => return 0
      }
      if delta == 0 {
        return 0
      }
      let token = text_field(e, id)
      let snapshot = match @fields.snapshot(token) {
        Some(s) => s
        None => return 0
      }
      let current = match text_edit_numeric(e, snapshot, property) {
        Some(n) => n
        None => return 0
      }
      let value = @protocol.smaller(
        @image.editor_style_max(property),
        @protocol.larger(
          @image.editor_style_min(property),
          current + delta * editor_style_step(property),
        ),
      )
      let raw = text_decimal(value * (if property == 1 { 100 } else { 1 }))
      if !@fields.apply(
          token,
          id,
          snapshot.version,
          @fields.Replace(0, snapshot.raw.length(), raw, @fields.Unknown),
        ) {
        return 0
      }
      e.active_field = id
    }
    "shape" => {
      if e.shape == 0 || text_error(e) != "" {
        return 0
      }
      let value = (@protocol.integer_field(event, "value", 0, 2) catch {
        _ => return 0
      }).to_int()
      if value >= @annotation_tools.editor_style_shape_count(e.tool) {
        return 0
      }
      let s = @fields.snapshot(e.shape).unwrap()
      if !@fields.apply(
          e.shape,
          "style.shape",
          s.version,
          @fields.Replace(
            0,
            s.raw.length(),
            text_decimal(value.to_double()),
            @fields.Unknown,
          ),
        ) {
        return 0
      }
      e.active_field = "style.shape"
    }
    "undo" | "redo" as kind => {
      let token = text_field(e, e.active_field)
      if !property_visible(e, e.active_field) ||
        (e.active_field == "style.shape" && text_error(e) != "") {
        return 0
      }
      let s = match @fields.snapshot(token) {
        Some(s) => s
        None => return 0
      }
      if !@fields.apply(
          token,
          e.active_field,
          s.version,
          if kind == "undo" {
            @fields.Undo
          } else {
            @fields.Redo
          },
        ) {
        return 0
      }
    }
    _ => return 0
  }
  e.version += 1
  text_refresh_preview(e)
  1
}

///|
pub fn text_value(session : Int32, edit : Int32, key : Int32) -> Double {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return -1
  }
  match key {
    0 => e.version.to_double()
    1 => e.mode.to_double()
    2 => e.color.to_double()
    3 => e.preview_opacity
    4 => e.preview_font
    5 => e.x
    6 => e.y
    7 => e.width
    8 => e.height
    9 => image_session_revision(session)
    10 | 11 =>
      match @fields.snapshot(text_field(e, e.active_field)) {
        Some(s) =>
          if (key == 10 && s.can_undo) || (key == 11 && s.can_redo) {
            1
          } else {
            0
          }
        None => 0
      }
    12 => if text_error(e) == "" { 1 } else { 0 }
    13 | 14 => @capture_ui.text_row_size(property_descriptors(e))[key - 13]
    15 => e.tool.to_double()
    16 => e.preview_stroke
    17 => e.preview_shape
    18 => e.preview_block
    19 => property_mask(e).to_double()
    _ => -1
  }
}

///|
pub fn text_text(session : Int32, edit : Int32, key : Int32) -> String {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return ""
  }
  match key {
    0 => e.annotation_id
    1 => text_raw(e.body)
    2 => text_error(e)
    3 => property_preview_annotation(e).stringify()
    _ => ""
  }
}

///|
pub fn text_snapshot(session : Int32, edit : Int32) -> String {
  @protocol.response(() => {
    let e = match text_current(session, edit) {
      Some(e) => e
      None =>
        raise InputError("closed_edit", "The text edit is no longer active")
    }
    let fields : Array[Json] = []
    for token in property_tokens(e) {
      if @fields.snapshot(token) is Some(s) {
        fields.push(text_field_snapshot(s))
      }
    }
    Json::object({
      "ok": Json(true),
      "edit": Json(edit),
      "version": Json(e.version),
      "baseRevision": Json(e.base_revision),
      "annotationID": Json(e.annotation_id),
      "mode": Json(e.mode),
      "tool": Json(e.tool),
      "previewAnnotation": property_preview_annotation(e),
      "fields": Json::array(fields),
      "error": Json(text_error(e)),
      "activeField": Json(e.active_field),
      "preview": Json::object({
        "rgb": Json(e.color),
        "opacity": Json(e.preview_opacity),
        "fontSize": Json(e.preview_font),
        "stroke": Json(e.preview_stroke),
        "shape": Json(e.preview_shape),
        "blockSize": Json(e.preview_block),
        "x": Json(e.x),
        "y": Json(e.y),
        "width": Json(e.width),
        "height": Json(e.height),
      }),
    })
  })
}
