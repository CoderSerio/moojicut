///|
pub fn input_event(
  kind : Int32,
  x : Double,
  y : Double,
  dx : Double,
  dy : Double,
  flags : Int32,
  text : String,
) -> String {
  if flags < 0 || flags > 7 || text.length() > 256 {
    return ""
  }
  for n in [x, y, dx, dy] {
    if !(n >= -1000000 && n <= 1000000) {
      return ""
    }
  }
  if kind <= 5 && text != "" {
    return ""
  }
  let fields : Map[String, Json] = Map([])
  match kind {
    1 | 2 | 3 => {
      fields["type"] = Json(
        if kind == 1 {
          "pointerDown"
        } else if kind == 2 {
          "pointerMove"
        } else {
          "pointerUp"
        },
      )
      fields["x"] = Json(x)
      fields["y"] = Json(y)
    }
    4 => fields["type"] = Json("cancel")
    5 => {
      fields["type"] = Json("scroll")
      fields["x"] = Json(x)
      fields["y"] = Json(y)
      fields["deltaX"] = Json(dx)
      fields["deltaY"] = Json(dy)
      fields["mod"] = Json((flags & 1) != 0)
      fields["shift"] = Json((flags & 2) != 0)
      fields["precise"] = Json((flags & 4) != 0)
    }
    6 | 7 => {
      if text.length() == 0 {
        return ""
      }
      fields["type"] = Json(if kind == 6 { "key" } else { "activate" })
      fields[if kind == 6 { "key" } else { "id" }] = Json(text)
      if kind == 6 {
        fields["mod"] = Json((flags & 1) != 0)
        fields["shift"] = Json((flags & 2) != 0)
      }
    }
    8 => {
      if text != "light" && text != "dark" {
        return ""
      }
      fields["type"] = Json("appearance")
      fields["mode"] = Json(text)
    }
    _ => return ""
  }
  Json::object(fields).stringify()
}
