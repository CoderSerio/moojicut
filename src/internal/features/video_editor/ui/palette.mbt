// Shared UI colors. The host reports an appearance; no platform adapter chooses
// product colors. Every value is neutral (R = G = B), including error text.

///|
priv struct Palette {
  background : String
  panel : String
  border : String
  stage : String
  text : String
  secondary : String
  muted : String
  disabled : String
  button : String
  button_hover : String
  button_pressed : String
  primary : String
  primary_hover : String
  primary_pressed : String
  on_primary : String
  focus : String
  tick : String
  track : String
  clip : String
  clip_border : String
  cut : String
  handle : String
  handle_disabled : String
  handle_grip : String
  playhead : String
}

///|
fn palette(s : UI) -> Palette {
  if s.appearance == "light" {
    {
      background: "#EFEFEF",
      panel: "#FAFAFA",
      border: "#C2C2C2",
      stage: "#111111",
      text: "#202020",
      secondary: "#505050",
      muted: "#626262",
      disabled: "#8A8A8A",
      button: "#E1E1E1",
      button_hover: "#D0D0D0",
      button_pressed: "#BBBBBB",
      primary: "#363636",
      primary_hover: "#4C4C4C",
      primary_pressed: "#202020",
      on_primary: "#FFFFFF",
      focus: "#111111",
      tick: "#858585",
      track: "#E2E2E2",
      clip: "#C6C6C6",
      clip_border: "#777777",
      cut: "#EAEAEA",
      handle: "#555555",
      handle_disabled: "#B0B0B0",
      handle_grip: "#FFFFFF",
      playhead: "#111111",
    }
  } else {
    {
      background: "#191919",
      panel: "#252525",
      border: "#434343",
      stage: "#080808",
      text: "#EFEFEF",
      secondary: "#C2C2C2",
      muted: "#A6A6A6",
      disabled: "#858585",
      button: "#2D2D2D",
      button_hover: "#3D3D3D",
      button_pressed: "#505050",
      primary: "#D9D9D9",
      primary_hover: "#F0F0F0",
      primary_pressed: "#BBBBBB",
      on_primary: "#191919",
      focus: "#FFFFFF",
      tick: "#777777",
      track: "#313131",
      clip: "#515151",
      clip_border: "#999999",
      cut: "#2B2B2B",
      handle: "#D9D9D9",
      handle_disabled: "#6F6F6F",
      handle_grip: "#333333",
      playhead: "#FFFFFF",
    }
  }
}
