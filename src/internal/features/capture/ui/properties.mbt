///|
pub fn editor_style_visible_mask(tool : Int, shape : Int) -> Int {
  if tool == 4 { if shape == 2 { 48 } else { 19 } }
  else { @annotation_tools.editor_style_property_mask(tool) }
}

///|
// Spinner/keyboard increments are presentation, not value quantization.
pub fn editor_style_step(property : Int) -> Double {
  match property { 0 | 2 | 3 | 4 | 5 => 1; 1 => 0.01; _ => 0 }
}

///|
// Space between complete property groups, in logical points. Native control
// intrinsic sizes and label/control spacing remain inside each group.
pub fn editor_style_group_gap() -> Int {
  8
}

///|
pub fn editor_style_swatch_size() -> Int {
  22
}
