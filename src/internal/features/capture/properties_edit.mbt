///|
fn property_tokens(e : TextEdit) -> Array[Int32] {
  [e.body, e.opacity, e.font, e.stroke, e.shape, e.block]
}

///|
fn property_key(id : String) -> Int32 {
  match id {
    "style.color" => 0
    "style.opacity" => 1
    "style.stroke" => 2
    "style.fontSize" => 3
    "style.shape" => 4
    "style.blockSize" => 5
    _ => -1
  }
}

///|
fn property_mask(e : TextEdit) -> Int32 {
  @annotation_tools.property_visible_mask(
    e.tool,
    e.preview_shape.to_int(),
    e.contribution_command,
  )
}

///|
fn property_visible(e : TextEdit, id : String) -> Bool {
  if id == "annotation.text" {
    return e.body != 0
  }
  let key = property_key(id)
  key >= 0 && (property_mask(e) & (1 << key)) != 0
}

///|
fn property_descriptors(e : TextEdit) -> Json {
  let descriptors = @annotation_tools.property_descriptors(
    e.tool,
    e.preview_shape.to_int(),
    e.contribution_command,
  )
  if descriptors is Array(items) {
    for item in items {
      if item is Object(field) && field.get("kind") == Some(Json("number")) {
        let id = image_string(field, "id", "")
        field["displayText"] = Json(text_raw(text_field(e, id)))
      }
    }
  }
  descriptors
}

///|
fn property_initial(e : TextEdit, key : Int32) -> Double {
  match key {
    1 => e.initial_opacity
    2 => e.initial_stroke
    3 => e.initial_font
    4 => e.initial_shape
    5 => e.initial_block
    _ => 0
  }
}

///|
fn property_numeric_error(key : Int32) -> String {
  match key {
    1 => "Opacity must be a number between 0 and 100"
    2 => "线宽请输入 1–96 之间的数字"
    3 => "Font size must be a number between 8 and 128"
    4 => "请选择可用形状"
    5 => "颗粒请输入 4–48 之间的整数"
    _ => "属性值无效"
  }
}

///|
fn property_patch(e : TextEdit) -> Json {
  let original = match e.original {
    Object(a) => a
    _ => Map([])
  }
  let patch : Map[String, Json] = Map([])
  let mask = property_mask(e)
  if (mask & 1) != 0 && native_annotation_value(original, 5).to_int() != e.color {
    patch["color"] = Json(native_image_color(e.color))
  }
  for
    item in [
      (1, "opacity", e.preview_opacity),
      (2, "stroke", e.preview_stroke),
      (5, "blockSize", e.preview_block),
    ] {
    let (key, name, value) = item
    if (mask & (1 << key)) != 0 &&
      image_number(
        original,
        name,
        if key == 1 {
          1
        } else if key == 2 {
          3
        } else {
          12
        },
      ) !=
      value {
      patch[name] = Json(value)
    }
  }
  Json::object(patch)
}

///|
fn property_shape_change(e : TextEdit) -> Int32? {
  if e.shape != 0 && e.preview_shape != e.initial_shape {
    Some(e.preview_shape.to_int())
  } else {
    None
  }
}

///|
fn property_preview_annotation(e : TextEdit) -> Json {
  if e.mode == 0 {
    return Json::null()
  }
  if e.tool == 3 {
    let annotation = match e.original {
      Object(a) => text_copy(a)
      _ => Map([])
    }
    annotation["id"] = Json(e.annotation_id)
    annotation["type"] = Json("text")
    annotation["x"] = Json(e.x)
    annotation["y"] = Json(e.y)
    annotation["width"] = Json(e.width)
    annotation["height"] = Json(e.height)
    annotation["text"] = Json(text_raw(e.body))
    annotation["fontSize"] = Json(e.preview_font)
    annotation["color"] = Json(native_image_color(e.color))
    annotation["opacity"] = Json(e.preview_opacity)
    return Json::object(annotation)
  }
  @image.image_style_annotation(
    e.original,
    property_shape_change(e),
    property_patch(e),
  ) catch {
    _ => Json::null()
  }
}

///|
fn property_prepare(e : TextEdit, purpose : Int32) -> Int32 {
  let s = native_image_sessions[e.session]
  let mut command = Json::null()
  if e.mode == 2 {
    let preview = property_preview_annotation(e)
    if preview == Json::null() {
      return 0
    }
    if preview != e.original {
      let fields : Map[String, Json] = {
        "type": Json("style"),
        "id": Json(e.annotation_id),
        "patch": property_patch(e),
      }
      if property_shape_change(e) is Some(shape) {
        fields["shape"] = Json(shape)
      }
      command = Json::object(fields)
    }
  }
  let document = match candidate_apply(s.document, command) {
    Some(d) => d
    None => return 0
  }
  let defaults = if e.mode == 0 {
    let values : Map[Int32, Double] = Map([])
    let all = [
      e.color.to_double(),
      e.preview_opacity,
      e.preview_stroke,
      e.preview_font,
      e.preview_shape,
      e.preview_block,
    ]
    let mask = property_mask(e)
    for key in 0..<6 {
      if (mask & (1 << key)) != 0 {
        values[key] = all[key]
      }
    }
    let patch : StylePatch = { tool: e.tool, values, }
    if style_patch_changed(e.style, patch) {
      if e.style_revision >= 2147483647 {
        return 0
      }
      Some(patch)
    } else {
      None
    }
  } else {
    None
  }
  candidate_store({
    session: e.session,
    revision: e.base_revision,
    style: e.style,
    style_revision: e.style_revision,
    edit: text_active[e.session],
    edit_version: e.version,
    purpose,
    document,
    defaults,
  })
}
