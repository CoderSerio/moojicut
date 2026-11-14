///|
// Style domains and per-tool defaults belong to the shared editor core. Native
// controls keep focus/drag drafts, then read or update these typed records.
priv struct EditorStyleProperty {
  minimum : Double
  maximum : Double
  step : Double
  initial : Double
}

///|
fn editor_style_property(property : Int) -> EditorStyleProperty? {
  match property {
    0 => Some({ minimum: 0, maximum: 16777215, step: 1, initial: (0xf26769).to_double() })
    1 => Some({ minimum: 0, maximum: 1, step: 0.01, initial: 1 })
    2 => Some({ minimum: 1, maximum: 96, step: 1, initial: 4 })
    3 => Some({ minimum: 8, maximum: 128, step: 1, initial: 32 })
    _ => None
  }
}

///|
// A step describes keyboard/spinner increments, not valid-value quantization.
// Documents already allow fractional stroke/font values; keep them compatible.
pub fn editor_style_value_valid(property : Int, value : Double) -> Bool {
  let domain = match editor_style_property(property) {
    Some(domain) => domain
    None => return false
  }
  value >= domain.minimum && value <= domain.maximum &&
  (property != 0 || @double.floor(value) == value)
}

///|
pub fn editor_style_property_mask(tool : Int) -> Int {
  match tool {
    1 | 2 => 7 // color, opacity, stroke
    3 => 11 // color, opacity, font
    4 => 3 // color, opacity
    _ => 0
  }
}

///|
pub fn editor_style_min(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.minimum; None => 0 }
}

///|
pub fn editor_style_max(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.maximum; None => 0 }
}

///|
pub fn editor_style_step(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.step; None => 0 }
}

///|
pub fn editor_style_default(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.initial; None => 0 }
}
