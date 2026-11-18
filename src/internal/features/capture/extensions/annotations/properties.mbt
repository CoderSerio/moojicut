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
      "tooltip":Json("文字颜色"),"width":Json(22),"labelWidth":Json(26)}),
    Json::object({"id":Json("style.opacity"),"kind":Json("number"),"label":Json("透明度"),
      "tooltip":Json("文字透明度（百分比）"),"property":Json(1),"min":Json(0),"max":Json(100),
      "step":Json(1),"displayScale":Json(100),"width":Json(58),"labelWidth":Json(39)}),
    Json::object({"id":Json("style.fontSize"),"kind":Json("number"),"label":Json("字号"),
      "tooltip":Json("文字字号"),"property":Json(3),"min":Json(@image.editor_style_min(3)),
      "max":Json(@image.editor_style_max(3)),"step":Json(editor_style_step(3)),
      "displayScale":Json(1),"width":Json(58),"labelWidth":Json(26)}),
  ])
}
