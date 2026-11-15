// Every icon is composed from the same portable line/rect commands as transport.

///|
fn icon_path(
  commands : Array[Json],
  s : UI,
  x : Double,
  y : Double,
  points : Array[(Double, Double)],
  color : String,
) -> Unit {
  for i = 1; i < points.length(); i = i + 1 {
    draw_line(
      commands,
      s,
      x + points[i - 1].0,
      y + points[i - 1].1,
      x + points[i].0,
      y + points[i].1,
      color,
      1.6,
    )
  }
}

///|
fn draw_action_icon(
  commands : Array[Json],
  s : UI,
  r : Rect,
  id : String,
  color : String,
) -> Unit {
  let x = r.x + r.width / 2
  let y = r.y + r.height / 2
  match id {
    "project-mute" => {
      icon_path(
        commands,
        s,
        x,
        y,
        [(-8, -3), (-4, -3), (1, -7), (1, 7), (-4, 3), (-8, 3), (-8, -3)],
        color,
      )
      if project(s).muted {
        draw_line(commands, s, x + 4, y - 3, x + 9, y + 3, color, 1.6)
        draw_line(commands, s, x + 4, y + 3, x + 9, y - 3, color, 1.6)
      } else {
        icon_path(commands, s, x, y, [(5, -5), (8, -2), (8, 2), (5, 5)], color)
      }
    }
    "project-crop" => {
      icon_path(commands, s, x, y, [(-5, -9), (-5, 5), (9, 5)], color)
      icon_path(commands, s, x, y, [(-9, -5), (5, -5), (5, 9)], color)
    }
    "project-crop-apply" =>
      icon_path(commands, s, x, y, [(-7, 0), (-2, 5), (8, -6)], color)
    "project-crop-cancel" => {
      draw_line(commands, s, x - 6, y - 6, x + 6, y + 6, color, 1.6)
      draw_line(commands, s, x - 6, y + 6, x + 6, y - 6, color, 1.6)
    }
    "project-crop-reset" =>
      for d in [-1.0, 1.0] {
        icon_path(
          commands,
          s,
          x,
          y,
          [(d * 3, -8), (d * 8, -8), (d * 8, -3)],
          color,
        )
        icon_path(
          commands,
          s,
          x,
          y,
          [(d * 3, 8), (d * 8, 8), (d * 8, 3)],
          color,
        )
      }
    "project-split" =>
      for d in [-1.0, 1.0] {
        icon_path(
          commands,
          s,
          x,
          y,
          [
            (d * 3, 4),
            (d * 3, 7),
            (d * 5, 9),
            (d * 8, 8),
            (d * 9, 5),
            (d * 7, 3),
            (d * 4, 3),
            (d * 3, 4),
          ],
          color,
        )
        draw_line(commands, s, x + d * 4, y + 3, x - d * 7, y - 8, color, 1.6)
      }
    "project-remove" => {
      icon_path(commands, s, x, y, [(-6, -4), (-5, 8), (5, 8), (6, -4)], color)
      draw_line(commands, s, x - 8, y - 5, x + 8, y - 5, color, 1.6)
      icon_path(
        commands,
        s,
        x,
        y,
        [(-3, -5), (-3, -8), (3, -8), (3, -5)],
        color,
      )
      for d in [-2.0, 2.0] {
        draw_line(commands, s, x + d, y - 1, x + d, y + 5, color, 1.4)
      }
    }
    "project-move-earlier"
    | "project-move-later"
    | "project-offset-earlier"
    | "project-offset-later" => {
      let d = if id == "project-move-earlier" || id == "project-offset-earlier" {
        -1.0
      } else {
        1.0
      }
      let offset = id == "project-offset-earlier" ||
        id == "project-offset-later"
      let yy = if offset { y - 3 } else { y }
      draw_line(commands, s, x - d * 6, yy, x + d * 5, yy, color, 1.6)
      icon_path(commands, s, x, yy, [(d, -4), (d * 5, 0), (d, 4)], color)
      if offset {
        for (dx, h) in [(-6.0, 2.0), (-2.0, 4.0), (2.0, 3.0), (6.0, 2.0)] {
          draw_line(
            commands,
            s,
            x + dx,
            y + 5 - h / 2,
            x + dx,
            y + 5 + h / 2,
            color,
            1.4,
          )
        }
      } else {
        draw_line(commands, s, x + d * 8, y - 8, x + d * 8, y + 8, color, 1.6)
      }
    }
    "project-unlink" => {
      icon_path(
        commands,
        s,
        x,
        y,
        [
          (-3, -1),
          (-5, 1),
          (-8, 1),
          (-10, -1),
          (-10, -4),
          (-7, -7),
          (-4, -7),
          (-2, -5),
        ],
        color,
      )
      icon_path(
        commands,
        s,
        x,
        y,
        [(3, 1), (5, -1), (8, -1), (10, 1), (10, 4), (7, 7), (4, 7), (2, 5)],
        color,
      )
      draw_line(commands, s, x - 2, y + 3, x - 5, y + 7, color, 1.6)
      draw_line(commands, s, x + 2, y - 3, x + 5, y - 7, color, 1.6)
    }
    "project-audio-toggle" =>
      for
        (dx, h) in [
          (-8.0, 3.0),
          (-4.0, 6.0),
          (0.0, 9.0),
          (4.0, 5.0),
          (8.0, 3.0),
        ] {
        draw_line(commands, s, x + dx, y - h, x + dx, y + h, color, 1.8)
      }
    "project-zoom-in" | "project-zoom-out" => {
      icon_path(
        commands,
        s,
        x - 2,
        y - 2,
        [
          (-6, -2),
          (-4, -5),
          (0, -6),
          (4, -4),
          (6, 0),
          (5, 4),
          (2, 6),
          (-2, 6),
          (-5, 3),
          (-6, -2),
        ],
        color,
      )
      draw_line(commands, s, x + 2, y + 3, x + 8, y + 9, color, 1.8)
      draw_line(commands, s, x - 5, y - 2, x + 1, y - 2, color, 1.4)
      if id == "project-zoom-in" {
        draw_line(commands, s, x - 2, y - 5, x - 2, y + 1, color, 1.4)
      }
    }
    "project-zoom-fit" => {
      for d in [-1.0, 1.0] {
        icon_path(
          commands,
          s,
          x,
          y,
          [(d * 4, -7), (d * 9, -7), (d * 9, 7), (d * 4, 7)],
          color,
        )
        icon_path(
          commands,
          s,
          x,
          y,
          [(d * 2, -3), (d * 5, 0), (d * 2, 3)],
          color,
        )
      }
      draw_line(commands, s, x - 5, y, x + 5, y, color, 1.4)
    }
    "export" =>
      if s.export_busy {
        // A distinct hourglass remains recognizable without an animation clock.
        icon_path(
          commands,
          s,
          x,
          y,
          [
            (-6, -8),
            (6, -8),
            (6, -5),
            (-6, 5),
            (-6, 8),
            (6, 8),
            (6, 5),
            (-6, -5),
            (-6, -8),
          ],
          color,
        )
      } else {
        draw_line(commands, s, x, y - 9, x, y + 2, color, 1.7)
        icon_path(commands, s, x, y, [(-4, -2), (0, 2), (4, -2)], color)
        icon_path(commands, s, x, y, [(-8, 3), (-8, 8), (8, 8), (8, 3)], color)
      }
    "preview-rate" => {
      icon_path(
        commands,
        s,
        x,
        y,
        [(-8, -7), (8, -7), (8, 4), (-8, 4), (-8, -7)],
        color,
      )
      icon_path(
        commands,
        s,
        x,
        y,
        [(-2, -4), (3, -1.5), (-2, 1), (-2, -4)],
        color,
      )
      draw_line(commands, s, x, y + 4, x, y + 7, color, 1.4)
      draw_line(commands, s, x - 4, y + 7, x + 4, y + 7, color, 1.4)
    }
    "project-speed" => {
      icon_path(
        commands,
        s,
        x,
        y,
        [(-8, -7), (8, -7), (8, 7), (-8, 7), (-8, -7)],
        color,
      )
      for dy in [-3.0, 3.0] {
        draw_line(commands, s, x - 8, y + dy, x + 8, y + dy, color, 1.3)
      }
      for dx in [-4.0, 4.0] {
        draw_line(commands, s, x + dx, y - 7, x + dx, y - 3, color, 1.3)
        draw_line(commands, s, x + dx, y + 3, x + dx, y + 7, color, 1.3)
      }
    }
    _ => ()
  }
}

///|
fn draw_rate_button_content(
  commands : Array[Json],
  s : UI,
  r : Rect,
  id : String,
  value : String,
  color : String,
) -> Unit {
  draw_action_icon(
    commands,
    s,
    { x: r.x + 8, y: r.y, width: 20, height: r.height, },
    id,
    color,
  )
  draw_text(
    commands,
    s,
    { x: r.x + 30, y: r.y, width: r.width - 50, height: r.height, },
    value,
    color,
    12,
    "medium",
    "center",
  )
  let x = r.x + r.width - 13
  let y = r.y + r.height / 2
  icon_path(commands, s, x, y, [(-3, -1.5), (0, 1.5), (3, -1.5)], color)
}
