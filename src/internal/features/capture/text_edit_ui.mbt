///|
fn text_frame_field(e : TextEdit, token : Int32) -> Json {
  let s = match @fields.snapshot(token) {
    Some(s) => s
    None => return Json::null()
  }
  let selection = if !s.selection_known {
    Json::object({ "kind": Json("unknown") })
  } else {
    Json::object({
      "kind": Json(if s.direction_known { "directed" } else { "undirected" }),
      "anchor": Json(s.anchor),
      "focus": Json(s.focus),
    })
  }
  let error = if !text_fresh(e) {
    text_error(e)
  } else if s.marked is Some(_) {
    ""
  } else if property_key(s.field_id) >= 1 &&
    text_numeric(s, property_key(s.field_id)) is None {
    property_numeric_error(property_key(s.field_id))
  } else {
    ""
  }
  Json::object({
    "id": Json(s.field_id),
    "token": Json(s.token),
    "version": Json(s.version),
    "raw": Json(s.raw),
    "selection": selection,
    "marked": match s.marked {
      Some((start, end)) =>
        Json::object({ "start": Json(start), "end": Json(end) })
      None => Json::null()
    },
    "canUndo": Json(s.can_undo),
    "canRedo": Json(s.can_redo),
    "error": Json(error),
  })
}

///|
pub fn text_frame(
  session : Int32,
  edit : Int32,
  surface : Int32,
  width : Double,
  height : Double,
  scale : Double,
  dark : Int32,
) -> String {
  @protocol.response(() => {
    let e = match text_current(session, edit) {
      Some(e) => e
      None =>
        raise InputError("closed_edit", "The text edit is no longer active")
    }
    if !(width > 0 &&
      width <= 1000000 &&
      height > 0 &&
      height <= 1000000 &&
      scale >= 1.0 / 65536 &&
      scale <= 16) ||
      (dark != 0 && dark != 1) ||
      (surface != 0 && surface != 1) ||
      (surface == 1 && e.tool != 3) {
      raise InputError("invalid_input", "Invalid text surface")
    }
    let frame = if surface == 0 {
      @capture_ui.text_properties_frame(
        property_descriptors(e),
        Json::array(property_tokens(e).map(token => text_frame_field(e, token))),
        native_image_color(e.color),
        e.active_field,
        text_fresh(e),
        width,
        height,
        dark == 1,
        e.color_pressed,
        e.color_hovered,
        text_error(e) == "",
      )
    } else {
      @capture_ui.text_inline_frame(
        text_frame_field(e, e.body),
        width,
        height,
        e.preview_font * scale,
        native_image_color(e.color),
        e.preview_opacity,
        text_fresh(e),
        e.active_field == "annotation.text",
      )
    }
    text_json(frame, 65536)
  })
}

///|
pub fn text_ui_event(
  session : Int32,
  edit : Int32,
  version : Int32,
  event : String,
  width : Double,
  height : Double,
) -> Int32 {
  let e = match text_current(session, edit) {
    Some(e) => e
    None => return 0
  }
  if !text_fresh(e) ||
    e.version != version ||
    !(width > 0 && width <= 1000000 && height > 0 && height <= 1000000) {
    return 0
  }
  let event = text_json(event, 65536) catch { _ => return 0 }
  if event is Object(input) && image_string(input, "type", "") == "key" {
    let key = image_string(input, "key", "")
    if (key != "ArrowUp" && key != "ArrowDown") ||
      input.get("mod") == Some(Json(true)) ||
      input.get("shift") == Some(Json(true)) ||
      ![1, 2, 3, 5].contains(property_key(e.active_field)) {
      return 0
    }
    return text_event_json(
      session,
      edit,
      version,
      Json::object({
        "type": Json("step"),
        "id": Json(e.active_field),
        "delta": Json(if key == "ArrowUp" { 1 } else { -1 }),
      }).stringify(),
    )
  }
  let (result, pressed, hovered) = @capture_ui.text_property_event(
    property_descriptors(e),
    event,
    width,
    height,
    e.color_pressed,
  )
  if result >= 10 && result <= 12 {
    e.color_pressed = ""
    e.color_hovered = ""
    return text_event_json(
      session,
      edit,
      version,
      Json::object({ "type": Json("shape"), "value": Json(result - 10) }).stringify(),
    )
  }
  if result != 0 {
    e.color_pressed = pressed
    e.color_hovered = hovered
    if result == 2 {
      e.active_field = "style.color"
    }
  }
  result
}
