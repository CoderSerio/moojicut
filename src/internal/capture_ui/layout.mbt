///|
// Top-left logical coordinates; native adapters convert once at the boundary.
// Measurements come from the renderer. Placement and padding are shared.
pub fn toolbar_frame(
  surface_width : Double,
  surface_height : Double,
  region_x : Double,
  region_y : Double,
  region_width : Double,
  region_height : Double,
  row_width : Double,
  properties_width : Double,
) -> FixedArray[Double] {
  let margin = @protocol.smaller(8, surface_width / 8)
  let available = @protocol.larger(1, surface_width - 2 * margin)
  let inset = @protocol.smaller(6, available / 8)
  let width = @protocol.smaller(
    available,
    @protocol.larger(row_width, properties_width) + 2 * inset,
  )
  measured_toolbar_frame(surface_width, surface_height, region_x, region_y,
    region_width, region_height, width, if properties_width > 0 { 72 } else { 40 })
}

///|
// Native toolkit fonts/themes may require a taller row. Use their measured
// size with the same placement policy; do not reproduce clamping in the host.
pub fn measured_toolbar_frame(
  surface_width : Double, surface_height : Double, region_x : Double, region_y : Double,
  region_width : Double, region_height : Double, measured_width : Double, measured_height : Double,
) -> FixedArray[Double] {
  let margin = @protocol.smaller(8, surface_width / 8)
  let width = @protocol.smaller(@protocol.larger(1, measured_width), @protocol.larger(1, surface_width - 2 * margin))
  let vertical_margin = @protocol.smaller(8, surface_height / 8)
  let height = @protocol.smaller(@protocol.larger(1, measured_height), surface_height - 2 * vertical_margin)
  let x = @protocol.larger(
    margin,
    @protocol.smaller(
      region_x + region_width - width,
      surface_width - width - margin,
    ),
  )
  let mut y = region_y + region_height + 6
  if y + height > surface_height - vertical_margin {
    let above = region_y - height - 6
    y = if above >= vertical_margin {
      above
    } else {
      region_y + region_height - height - 6
    }
  }
  y = @protocol.larger(
    vertical_margin,
    @protocol.smaller(y, surface_height - height - vertical_margin),
  )
  [x, y, width, height]
}
