///|
fn text_json(text : String, maximum : Int32) -> Json raise InputError {
  if text.length() > maximum {
    raise InputError("invalid_input", "Request is too large")
  }
  @json.parse(text, max_nesting_depth=32, reject_duplicate_keys=true) catch {
    _ => raise InputError("invalid_json", "Expected valid JSON")
  }
}

///|
fn text_decimal(value : Double) -> String {
  Json(value).stringify()
}

///|
// Foundation whitespaceAndNewline behavior expressed once for every host.
// This is a capture policy, deliberately absent from shared/ui/fields.
fn text_blank(raw : String) -> Bool {
  raw
  .trim(
    chars="\t\n\u{000b}\u{000c}\r \u{0085}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}",
  )
  .is_empty()
}

///|
fn text_numeric(s : @fields.Snapshot, property : Int32) -> Double? {
  if s.marked is Some(_) {
    return None
  }
  let trimmed = s.raw.trim()
  if trimmed.is_empty() || trimmed.has_suffix(".") {
    return None
  }
  // Decimal input is locale independent. Incomplete values stay raw; no host
  // formatter may silently replace or clamp them during focus transitions.
  for c in trimmed {
    if !((c >= '0' && c <= '9') ||
      c == '+' ||
      c == '-' ||
      c == '.' ||
      c == 'e' ||
      c == 'E') {
      return None
    }
  }
  let value = @string.parse_double(trimmed) catch { _ => return None }
  let value = if property == 1 { value / 100 } else { value }
  if @image.editor_style_value_valid(property, value) {
    Some(value)
  } else {
    None
  }
}

///|
fn text_refresh_preview(e : TextEdit) -> Unit {
  for token in property_tokens(e) {
    if @fields.snapshot(token) is Some(s) {
      let key = property_key(s.field_id)
      if key >= 1 && text_edit_numeric(e, s, key) is Some(value) {
        match key {
          1 => e.preview_opacity = value
          2 => e.preview_stroke = value
          3 => e.preview_font = value
          4 => e.preview_shape = value
          5 => e.preview_block = value
          _ => ()
        }
      }
    }
  }
}

///|
fn text_edit_numeric(
  e : TextEdit,
  s : @fields.Snapshot,
  property : Int32,
) -> Double? {
  let value = match text_numeric(s, property) {
    Some(n) => n
    None => return None
  }
  let original = property_initial(e, property)
  // Preserve the exact persisted Double on a no-op display round trip. Percent
  // multiplication/division can otherwise create an undo entry by one ULP.
  if s.raw == text_decimal(original * (if property == 1 { 100 } else { 1 })) {
    Some(original)
  } else {
    Some(value)
  }
}

///|
fn text_error(e : TextEdit) -> String {
  if !text_fresh(e) {
    return "The screenshot or defaults changed; reopen this edit"
  }
  for token in property_tokens(e) {
    if @fields.snapshot(token) is Some(s) {
      if s.marked is Some(_) {
        return "Finish the current input-method composition first"
      }
      let key = property_key(s.field_id)
      if key >= 1 &&
        property_visible(e, s.field_id) &&
        text_numeric(s, key) is None {
        return property_numeric_error(key)
      }
    } else if token != 0 {
      return "The text field is no longer active"
    }
  }
  ""
}

///|
fn text_selection(
  fields : Map[String, Json],
) -> @fields.Selection raise InputError {
  let s = @protocol.object_field(fields, "selection")
  match image_string(s, "kind", "") {
    "unknown" => {
      if s.contains("anchor") || s.contains("focus") {
        raise InputError(
          "invalid_selection", "Unknown selection cannot carry invented offsets",
        )
      }
      @fields.Unknown
    }
    "directed" | "undirected" as kind => {
      let anchor = @protocol.integer_field(s, "anchor", 0, 32768).to_int()
      let focus = @protocol.integer_field(s, "focus", 0, 32768).to_int()
      if kind == "directed" {
        @fields.Directed(anchor, focus)
      } else {
        @fields.Undirected(anchor, focus)
      }
    }
    _ =>
      raise InputError(
        "invalid_selection", "Expected explicit selection metadata",
      )
  }
}

///|
fn text_event_string(fields : Map[String, Json]) -> String raise InputError {
  match fields.get("text") {
    Some(String(s)) if s.length() <= 10000 => s
    _ => raise InputError("invalid_text", "Text must be a bounded string")
  }
}

///|
fn text_decode_edit(event : Map[String, Json]) -> @fields.Edit raise InputError {
  match image_string(event, "type", "") {
    "replace" =>
      @fields.Replace(
        @protocol.integer_field(event, "start", 0, 32768).to_int(),
        @protocol.integer_field(event, "end", 0, 32768).to_int(),
        text_event_string(event),
        text_selection(event),
      )
    "select" => @fields.Select(text_selection(event))
    "compositionStart" =>
      @fields.CompositionStart(
        @protocol.integer_field(event, "start", 0, 32768).to_int(),
        @protocol.integer_field(event, "end", 0, 32768).to_int(),
        text_selection(event),
      )
    "compositionUpdate" =>
      @fields.CompositionUpdate(text_event_string(event), text_selection(event))
    "compositionCommit" =>
      @fields.CompositionCommit(text_event_string(event), text_selection(event))
    "compositionCancel" => @fields.CompositionCancel
    "undo" => @fields.Undo
    "redo" => @fields.Redo
    _ => raise InputError("invalid_event", "Unknown field edit")
  }
}

///|
fn text_field_snapshot(s : @fields.Snapshot) -> Json {
  Json::object({
    "id": Json(s.field_id),
    "token": Json(s.token),
    "version": Json(s.version),
    "raw": Json(s.raw),
    "anchor": Json(s.anchor),
    "focus": Json(s.focus),
    "selectionKnown": Json(s.selection_known),
    "directionKnown": Json(s.direction_known),
    "canUndo": Json(s.can_undo),
    "canRedo": Json(s.can_redo),
    "marked": match s.marked {
      Some((start, end)) =>
        Json::object({ "start": Json(start), "end": Json(end) })
      None => Json::null()
    },
  })
}

///|
pub fn editor_style_visible_mask(tool : Int32, shape : Int32) -> Int32 {
  @annotation_tools.editor_style_visible_mask(tool, shape)
}

///|
pub fn editor_style_step(property : Int32) -> Double {
  @annotation_tools.editor_style_step(property)
}

///|
// Keep annotation capability defaults at the feature root, not in geometry UI.
pub fn capture_ui_event(request : String) -> String {
  @protocol.response(() => {
    let fields = @protocol.request_object(request)
    if image_string(fields, "type", "") == "begin" {
      let kind = @protocol.integer_field(fields, "kind", 1, 4).to_int()
      fields["shapeCount"] = Json(
        @annotation_tools.editor_style_shape_count(kind),
      )
      if !fields.contains("blockSize") {
        fields["blockSize"] = Json(@annotation_tools.editor_style_default(5))
      }
    }
    text_json(@capture_ui.event(Json::object(fields).stringify()), 65536)
  })
}
