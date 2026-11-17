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
