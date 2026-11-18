///|
pub fn editor_style_property_mask(tool : Int32) -> Int32 {
  match tool {
    1 => 23 // color, opacity, stroke, shape
    2 => 7
    3 => 11 // color, opacity, font
    4 => 51 // color, opacity, shape, mosaic pixels
    _ => 0
  }
}

///|
pub fn editor_style_shape_count(tool : Int32) -> Int32 {
  match tool {
    1 => 2
    4 => 3
    _ => 0
  }
}

///|
// Creation defaults belong to tools; document fallbacks remain in the model.
pub fn editor_style_default(property : Int32) -> Double {
  match property {
    0 => (0xf26769).to_double()
    1 => 1
    2 => 4
    3 => 32
    4 => 0
    5 => 12
    _ => 0
  }
}

///|
pub fn editor_style_visible_mask(tool : Int, shape : Int) -> Int {
  if tool == 4 { if shape == 2 { 48 } else { 19 } }
  else { editor_style_property_mask(tool) }
}

///|
pub fn editor_style_step(property : Int) -> Double {
  match property { 0 | 2 | 3 | 4 | 5 => 1; 1 => 0.01; _ => 0 }
}

///|
/// Contribution-owned field identity, order and presentation domains. The root
/// injects these into capture UI; UI does not import an annotation extension.
pub fn text_property_descriptors() -> Json {
  Json::array([
    Json::object({"id":Json("style.color"),"kind":Json("color"),"label":Json("颜色"),
      "tooltip":Json("文字颜色"),"width":Json(22),"labelWidth":Json(24)}),
    Json::object({"id":Json("style.opacity"),"kind":Json("number"),"label":Json("透明度"),
      "tooltip":Json("文字透明度（百分比）"),"property":Json(1),"min":Json(0),"max":Json(100),
      "step":Json(1),"displayScale":Json(100),"width":Json(54),"labelWidth":Json(35)}),
    Json::object({"id":Json("style.fontSize"),"kind":Json("number"),"label":Json("字号"),
      "tooltip":Json("文字字号"),"property":Json(3),"min":Json(@image.editor_style_min(3)),
      "max":Json(@image.editor_style_max(3)),"step":Json(editor_style_step(3)),
      "displayScale":Json(1),"width":Json(54),"labelWidth":Json(24)}),
  ])
}

///|
pub fn property_context_valid(tool : Int32, command : String) -> Bool {
  (tool >= 1 && tool <= 4 && command == "") ||
  (tool == 1 && command == "capture.numberedRectangle")
}

///|
pub fn property_visible_mask(
  tool : Int32,
  shape : Int32,
  command : String,
) -> Int32 {
  if !property_context_valid(tool, command) {
    return 0
  }
  let mask = editor_style_visible_mask(tool, shape)
  if command == "capture.numberedRectangle" {
    mask & 7
  } else {
    mask
  }
}

///|
fn numeric_descriptor(id : String, label : String, property : Int32) -> Json {
  Json::object({
    "id": Json(id),
    "kind": Json("number"),
    "label": Json(label),
    "tooltip": Json(label),
    "property": Json(property),
    "min": Json(@image.editor_style_min(property)),
    "max": Json(@image.editor_style_max(property)),
    "step": Json(editor_style_step(property)),
    "displayScale": Json(1),
    "width": Json(54),
    "labelWidth": Json(24),
  })
}

///|
pub fn property_descriptors(
  tool : Int32,
  shape : Int32,
  command : String,
) -> Json {
  if tool == 3 && command == "" {
    return text_property_descriptors()
  }
  let mask = property_visible_mask(tool, shape, command)
  let result : Array[Json] = []
  if (mask & 16) != 0 {
    let options : Array[Json] = []
    for value in 0..<editor_style_shape_count(tool) {
      let (icon, label) = if value == 2 {
        ("mosaic", "马赛克")
      } else if tool == 4 {
        if value == 0 {
          ("filledRectangle", "实心方框")
        } else {
          ("filledEllipse", "实心圆框")
        }
      } else if value == 0 {
        ("rectangle", "方框")
      } else {
        ("ellipse", "圆框")
      }
      options.push(
        Json::object({
          "id": Json("style.shape.\{value}"),
          "value": Json(value),
          "label": Json(label),
          "icon": Json(icon),
        }),
      )
    }
    result.push(
      Json::object({
        "id": Json("style.shape"),
        "kind": Json("choice"),
        "label": Json("形状"),
        "tooltip": Json("标注形状"),
        "labelWidth": Json(24),
        "width": Json(options.length() * 26),
        "value": Json(shape),
        "options": Json::array(options),
      }),
    )
  }
  if (mask & 1) != 0 {
    result.push(
      Json::object({
        "id": Json("style.color"),
        "kind": Json("color"),
        "label": Json("颜色"),
        "tooltip": Json("标注颜色"),
        "width": Json(22),
        "labelWidth": Json(24),
      }),
    )
  }
  if (mask & 2) != 0 {
    result.push(
      Json::object({
        "id": Json("style.opacity"),
        "kind": Json("number"),
        "label": Json("透明度"),
        "tooltip": Json("透明度（百分比）"),
        "property": Json(1),
        "min": Json(0),
        "max": Json(100),
        "step": Json(1),
        "displayScale": Json(100),
        "width": Json(54),
        "labelWidth": Json(35),
      }),
    )
  }
  if (mask & 4) != 0 {
    result.push(numeric_descriptor("style.stroke", "线宽", 2))
  }
  if (mask & 32) != 0 {
    result.push(numeric_descriptor("style.blockSize", "颗粒", 5))
  }
  Json::array(result)
}
