///|
// Persistent style value domains are independent of tools and UI sessions.
priv struct EditorStyleProperty {
  minimum : Double
  maximum : Double
}

///|
fn editor_style_property(property : Int) -> EditorStyleProperty? {
  match property {
    0 => Some({ minimum: 0, maximum: 16777215 })
    1 => Some({ minimum: 0, maximum: 1 })
    2 => Some({ minimum: 1, maximum: 96 })
    3 => Some({ minimum: 8, maximum: 128 })
    4 => Some({ minimum: 0, maximum: 2 }) // shape variant
    5 => Some({ minimum: 4, maximum: 48 }) // mosaic pixels
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
  (!(property == 0 || property == 4 || property == 5) || @double.floor(value) == value)
}

///|
pub fn editor_style_min(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.minimum; None => 0 }
}

///|
pub fn editor_style_max(property : Int) -> Double {
  match editor_style_property(property) { Some(domain) => domain.maximum; None => 0 }
}
