// Icons are shared vector descriptions. No system symbol/font glyph dependency.

///|
fn draw_icon(
  commands : Array[Json],
  s : UI,
  r : Rect,
  id : String,
  color : String,
) -> Unit {
  let x = r.x + r.width / 2
  let y = r.y + r.height / 2
  if id == "play" {
    if s.playing {
      for dx in [-6.0, 2.0] {
        draw_rect(
          commands,
          s,
          { x: x + dx, y: y - 7, width: 4, height: 14, },
          1,
          color,
          "",
        )
      }
    } else {
      draw_line(commands, s, x - 5, y - 8, x + 7, y, color, 1.8)
      draw_line(commands, s, x + 7, y, x - 5, y + 8, color, 1.8)
      draw_line(commands, s, x - 5, y + 8, x - 5, y - 8, color, 1.8)
    }
  } else if id == "start" || id == "end" {
    let direction = if id == "start" { -1.0 } else { 1.0 }
    draw_line(
      commands,
      s,
      x + direction * 8,
      y - 8,
      x + direction * 8,
      y + 8,
      color,
      1.8,
    )
    draw_line(
      commands,
      s,
      x - direction * 5,
      y - 7,
      x + direction * 4,
      y,
      color,
      1.8,
    )
    draw_line(
      commands,
      s,
      x + direction * 4,
      y,
      x - direction * 5,
      y + 7,
      color,
      1.8,
    )
    draw_line(
      commands,
      s,
      x - direction * 5,
      y + 7,
      x - direction * 5,
      y - 7,
      color,
      1.8,
    )
  } else if id == "backward" || id == "forward" {
    let direction = if id == "backward" { -1.0 } else { 1.0 }
    for dx in [-3.0, 3.0] {
      draw_line(
        commands,
        s,
        x + dx - direction * 3,
        y - 7,
        x + dx + direction * 3,
        y,
        color,
        1.6,
      )
      draw_line(
        commands,
        s,
        x + dx + direction * 3,
        y,
        x + dx - direction * 3,
        y + 7,
        color,
        1.6,
      )
    }
  } else if id == "undo" || id == "redo" {
    let d = if id == "undo" { -1.0 } else { 1.0 }
    draw_line(commands, s, x - d * 7, y + 8, x - d * 7, y + 2, color, 1.7)
    draw_line(commands, s, x - d * 7, y + 2, x - d * 2, y - 3, color, 1.7)
    draw_line(commands, s, x - d * 2, y - 3, x + d * 7, y - 3, color, 1.7)
    draw_line(commands, s, x + d * 7, y - 3, x + d * 2, y - 8, color, 1.7)
    draw_line(commands, s, x + d * 7, y - 3, x + d * 2, y + 2, color, 1.7)
  }
}

///|
fn draw_rate_menu(
  commands : Array[Json],
  semantics : Array[Json],
  s : UI,
) -> Unit {
  let p = palette(s)
  let menu = rate_menu_rect(s)
  draw_rect(commands, s, menu, 9, p.panel, p.border)
  semantics.push(semantic(s, "preview-rate-menu", "group", Json::null()))
  for i, id in rate_ids {
    let r = control_rect(s, id)
    let selected = s.preview_rate == preview_rates[i]
    if s.focus == id || s.hover == id {
      draw_rect(
        commands,
        s,
        r,
        5,
        if s.gesture == id {
          p.button_pressed
        } else {
          p.button_hover
        },
        if s.focus == id {
          p.focus
        } else {
          ""
        },
      )
    }
    if selected {
      draw_line(commands, s, r.x + 8, r.y + 13, r.x + 11, r.y + 16, p.text, 1.5)
      draw_line(commands, s, r.x + 11, r.y + 16, r.x + 17, r.y + 9, p.text, 1.5)
    }
    let label = rate_label(preview_rates[i])
    draw_text(
      commands,
      s,
      { x: r.x + 26, y: r.y, width: r.width - 32, height: r.height, },
      label,
      p.text,
      12,
      if selected {
        "medium"
      } else {
        "regular"
      },
      "left",
    )
    semantics.push(semantic(s, id, "button", Json(selected)))
  }
}
