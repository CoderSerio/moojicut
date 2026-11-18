///|
// Keep reply parsing in MoonBit so native platform code uses one JSON codec.
pub fn desktop_plugin_reply_field(
  reply : String,
  key : String,
  index : Int,
  child : String,
  literal : Int,
) -> String {
  let fields = @contract.parse_object(reply, 14680064) catch { _ => return "" }
  let current = fields.get(key)
  let current = if index < 0 {
    current
  } else {
    match current {
      Some(Array(items)) => items.get(index)
      _ => None
    }
  }
  let current = if child == "" {
    current
  } else {
    match current {
      Some(Object(fields)) => fields.get(child)
      _ => None
    }
  }
  match current {
    Some(value) if literal == 1 => value.stringify()
    Some(String(value)) => value
    _ => ""
  }
}
