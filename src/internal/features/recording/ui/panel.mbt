///|
pub fn recording_ui_frame(
  handle : Int32,
  width : Double,
  height : Double,
) -> FixedArray[Double] {
  let phase = @recording.recording_flow_value(handle, 0)
  if !(width >= 96 && width <= 32768 && height >= 96 && height <= 32768) ||
    !(phase >= 2 && phase <= 5) {
    return FixedArray::make(14, 0)
  }
  let countdown = phase == 2
  let w = @protocol.smaller(200, width - 16)
  let h = @protocol.smaller(if countdown { 176 } else { 112 }, height - 16)
  let x = (width - w) / 2
  let y = (height - h) / 2
  let action = if countdown {
    8
  } else if phase == 3 || phase == 4 {
    5
  } else {
    0
  }
  let button : Double = if action == 0 { 0 } else { 32 }
  // Timer digits use a monospaced host font. Reserve generous glyph advance so
  // HH:mm:ss still fits the same panel on small displays/accessibility layouts.
  let text_width = w - 16
  let text_height = h - 56
  let preferred : Double = if countdown && h >= 144 { 64 } else { 24 }
  let font = @protocol.smaller(
    preferred,
    @protocol.smaller(
      text_width /
      (
        @protocol.larger(1, recording_ui_text(handle).length().to_double()) *
        0.75
      ),
      text_height * 0.85,
    ),
  )
  [
    x,
    y,
    w,
    h,
    x + 8,
    y + 8,
    w - 16,
    h - 56,
    x + (w - button) / 2,
    y + h - 40,
    button,
    button,
    font,
    action.to_double(),
  ]
}

///|
pub fn recording_ui_hit(
  handle : Int32,
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> Int32 {
  let frame = recording_ui_frame(handle, width, height)
  if x >= frame[8] &&
    y >= frame[9] &&
    x < frame[8] + frame[10] &&
    y < frame[9] + frame[11] {
    frame[13].to_int()
  } else {
    0
  }
}

///|
fn two_digits(value : Int32) -> String {
  if value < 10 {
    "0\{value}"
  } else {
    "\{value}"
  }
}

///|
pub fn recording_ui_text(handle : Int32) -> String {
  match @recording.recording_flow_value(handle, 0) {
    2 => "\{@recording.recording_flow_value(handle, 1)}"
    3 | 5 => "…"
    4 => {
      let seconds = @recording.recording_flow_value(handle, 2) / 1000
      let minutes = seconds / 60
      if minutes >= 60 {
        "\{two_digits(minutes / 60)}:\{two_digits(minutes % 60)}:\{two_digits(seconds % 60)}"
      } else {
        "\{two_digits(minutes)}:\{two_digits(seconds % 60)}"
      }
    }
    _ => ""
  }
}
