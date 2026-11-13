///|
/// Intersect an integer source-pixel selection with the image bounds.
#export_name("crop_rect")
pub fn crop_rect(request : String) -> String {
  response(() => {
    let fields = request_object(request)
    let source_width = integer_field(fields, "sourceWidth", 1.0, 32768.0)
    let source_height = integer_field(fields, "sourceHeight", 1.0, 32768.0)
    let x = integer_field(fields, "x", -32768.0, 32768.0)
    let y = integer_field(fields, "y", -32768.0, 32768.0)
    let width = integer_field(fields, "width", 1.0, 32768.0)
    let height = integer_field(fields, "height", 1.0, 32768.0)
    let left = larger(0.0, x)
    let top = larger(0.0, y)
    let right = smaller(source_width, x + width)
    let bottom = smaller(source_height, y + height)
    if right <= left || bottom <= top {
      raise InputError(
        "empty_crop", "The selected region does not intersect the image",
      )
    }
    Json::object({
      "ok": Json(true),
      "rect": Json::object({
        "x": Json(left),
        "y": Json(top),
        "width": Json(right - left),
        "height": Json(bottom - top),
      }),
    })
  })
}
