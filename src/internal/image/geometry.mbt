///|
/// Intersect an integer source-pixel selection with the image bounds.
pub fn crop_rect(request : String) -> String {
  @protocol.response(() => {
    let fields = @protocol.request_object(request)
    let source_width = @protocol.integer_field(fields, "sourceWidth", 1.0, 32768.0)
    let source_height = @protocol.integer_field(fields, "sourceHeight", 1.0, 32768.0)
    let x = @protocol.integer_field(fields, "x", -32768.0, 32768.0)
    let y = @protocol.integer_field(fields, "y", -32768.0, 32768.0)
    let width = @protocol.integer_field(fields, "width", 1.0, 32768.0)
    let height = @protocol.integer_field(fields, "height", 1.0, 32768.0)
    let left = @protocol.larger(0.0, x)
    let top = @protocol.larger(0.0, y)
    let right = @protocol.smaller(source_width, x + width)
    let bottom = @protocol.smaller(source_height, y + height)
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
