///|
/// Trusted presentation facts, injected by the capture root. Slot 0 is the
/// function group; slot 1 is the completion group. An asset ID is present only
/// when the host has registered that resource. No command policy lives here.
#derive(Eq)
pub(all) struct ToolbarItem {
  id : String
  title : String
  tooltip : String
  icon : String
  asset_id : String
  slot : Int32
  enabled : Bool
  selected : Bool
}

///|
pub extend ToolbarItem with Eq::{equal, not_equal}

///|
pub struct ToolbarState {
  mut items : Array[ToolbarItem]
  mut maximum : Double
  mut generation : Int32
  mut page : Int32
  mut pressed : String
  mut hovered : String
  mut focused : String
  mut focus_visible : Bool
}

///|
priv struct ToolbarPlacement {
  item : ToolbarItem
  x : Double
}

///|
priv struct ToolbarLayout {
  placements : Array[ToolbarPlacement]
  separator : Double
  width : Double
  scale : Double
  capacity : Int32
  pageable : Int32
  pages : Int32
}

///|
pub fn toolbar_new() -> ToolbarState {
  {
    items: [],
    maximum: 86,
    generation: -1,
    page: 0,
    pressed: "",
    hovered: "",
    focused: "",
    focus_visible: false,
  }
}

///|
fn toolbar_asset_valid(id : String) -> Bool {
  if id.length() > 128 {
    return false
  }
  for c in id.iter() {
    if !((c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '.' ||
      c == '_' ||
      c == '-') {
      return false
    }
  }
  true
}

///|
/// Replacing a registry/document presentation generation invalidates a held
/// press even if its ID survives. Repeated identical renders preserve focus,
/// hover and press. A rejected update leaves the entire old state unchanged.
pub fn toolbar_sync(
  state : ToolbarState,
  items : Array[ToolbarItem],
  max_width : Double,
  generation : Int32,
) -> Bool {
  if !(max_width >= 32 && max_width <= 65536) ||
    items.length() > 512 ||
    generation < 0 {
    return false
  }
  let max_width = @protocol.smaller(384, max_width)
  let seen : Map[String, Bool] = Map([])
  let ordered : Array[ToolbarItem] = []
  for item in items {
    if item.id == "" ||
      item.id.length() > 256 ||
      item.id.has_prefix("__toolbar.") ||
      seen.contains(item.id) ||
      item.title.length() > 4096 ||
      item.tooltip.length() > 4096 ||
      item.icon.length() > 128 ||
      !toolbar_asset_valid(item.asset_id) ||
      (item.slot != 0 && item.slot != 1) {
      return false
    }
    seen[item.id] = true
  }
  for slot in [0, 1] {
    for item in items {
      if item.slot == slot {
        ordered.push(item)
      }
    }
  }
  if state.items == ordered &&
    state.maximum == max_width &&
    state.generation == generation {
    return true
  }
  state.items = ordered
  state.maximum = max_width
  state.generation = generation
  state.pressed = ""
  state.hovered = ""
  if !ordered.any(item => item.id == state.focused && item.enabled) {
    state.focused = ""
  }
  let layout = toolbar_layout(state)
  state.page = @protocol.smaller(
    state.page.to_double(),
    (layout.pages - 1).to_double(),
  ).to_int()
  toolbar_reveal_focus(state)
  true
}

///|
fn toolbar_navigation(previous : Bool, enabled : Bool) -> ToolbarItem {
  {
    id: if previous {
      "__toolbar.previous"
    } else {
      "__toolbar.next"
    },
    title: if previous {
      "Previous tools"
    } else {
      "Next tools"
    },
    tooltip: if previous {
      "Previous tools"
    } else {
      "Next tools"
    },
    icon: if previous {
      "chevron_left"
    } else {
      "chevron_right"
    },
    asset_id: "",
    slot: 0,
    enabled,
    selected: false,
  }
}

///|
fn toolbar_group_width(count : Int32) -> Double {
  if count == 0 {
    0
  } else {
    count.to_double() * 26 - 2
  }
}

///|
fn toolbar_layout(state : ToolbarState) -> ToolbarLayout {
  let scale = @protocol.smaller(1, state.maximum / 86)
  let maximum = state.maximum / scale
  let placements : Array[ToolbarPlacement] = []
  let tools = state.items.filter(item => item.slot == 0).length()
  let finish = state.items.length() - tools
  let separator_width = if tools > 0 && finish > 0 { 9.0 } else { 0.0 }
  let natural = 8.0 +
    toolbar_group_width(tools) +
    toolbar_group_width(finish) +
    separator_width
  if natural <= maximum {
    let mut x = 4.0
    let mut separator = -1.0
    for index, item in state.items {
      if index == tools && index > 0 && finish > 0 {
        x += 7 // Replace the regular 2px gap with the single 9px group gap.
        separator = x - 5.5
      }
      placements.push({ item, x, })
      x += 26
    }
    return {
      placements,
      separator,
      width: natural,
      scale,
      capacity: tools,
      pageable: tools,
      pages: 1,
    }
  }
  // Keep completion actions visible whenever a full tool + navigation still
  // fits. Tiny surfaces fall back to paging the complete ordered list.
  let fixed_finish = finish > 0 &&
    tools > 0 &&
    maximum - 8 - toolbar_group_width(finish) - 9 >= 76
  let pageable = if fixed_finish { tools } else { state.items.length() }
  let reserved = if fixed_finish {
    toolbar_group_width(finish) + 9
  } else {
    9.0
  }
  let capacity = @protocol.larger(
    1,
    ((maximum - 8 - 52 - reserved + 2) / 26).floor(),
  ).to_int()
  let pages = (pageable + capacity - 1) / capacity
  let page = @protocol.smaller(state.page.to_double(), (pages - 1).to_double()).to_int()
  let start = page * capacity
  let end = @protocol.smaller(
    (start + capacity).to_double(),
    pageable.to_double(),
  ).to_int()
  placements.push({ item: toolbar_navigation(true, page > 0), x: 4, })
  let mut x = 30.0
  let mut separator = -1.0
  for i in start..<end {
    if i == tools && i > start {
      x += 7
      separator = x - 5.5
    }
    placements.push({ item: state.items[i], x, })
    x += 26
  }
  let next_x = if fixed_finish {
    maximum - 4 - toolbar_group_width(finish) - 9 - 24
  } else {
    maximum - 28
  }
  placements.push({
    item: toolbar_navigation(false, page + 1 < pages),
    x: next_x,
  })
  if fixed_finish {
    let finish_x = maximum - 4 - toolbar_group_width(finish)
    separator = finish_x - 5.5
    for i in tools..<state.items.length() {
      placements.push({
        item: state.items[i],
        x: finish_x + (i - tools).to_double() * 26,
      })
    }
  }
  { placements, separator, width: maximum, scale, capacity, pageable, pages, }
}

///|
fn toolbar_reveal_focus(state : ToolbarState) -> Unit {
  let layout = toolbar_layout(state)
  if layout.pages <= 1 {
    return
  }
  for index, item in state.items {
    if item.id == state.focused && index < layout.pageable {
      state.page = index / layout.capacity
      return
    }
  }
}

///|
pub fn toolbar_size(state : ToolbarState) -> FixedArray[Double] {
  let layout = toolbar_layout(state)
  [layout.width * layout.scale, 32 * layout.scale]
}

///|
pub fn toolbar_cancel(state : ToolbarState) -> Unit {
  state.pressed = ""
  state.hovered = ""
  state.focus_visible = false
}

///|
fn toolbar_hit(layout : ToolbarLayout, x : Double, y : Double) -> ToolbarItem? {
  if y < 4 * layout.scale || y >= 28 * layout.scale {
    return None
  }
  for p in layout.placements {
    if x >= p.x * layout.scale && x < (p.x + 24) * layout.scale {
      return Some(p.item)
    }
  }
  None
}

///|
fn toolbar_activate(state : ToolbarState, id : String) -> String {
  let layout = toolbar_layout(state)
  for p in layout.placements {
    if p.item.id == id && p.item.enabled {
      if id == "__toolbar.previous" || id == "__toolbar.next" {
        state.page += if id == "__toolbar.previous" { -1 } else { 1 }
        state.pressed = ""
        state.hovered = ""
        state.focused = ""
        return ""
      }
      state.focused = id
      return id
    }
  }
  ""
}

///|
/// Returns (handled, activated stable ID). Navigation and hover never emit a
/// product command. Pointer-up must match the still-valid pressed target.
pub fn toolbar_input(
  state : ToolbarState,
  event_json : String,
) -> (Bool, String) {
  let event = @protocol.request_object(event_json) catch {
    _ => return (false, "")
  }
  let kind = property_string(event, "type", "")
  let layout = toolbar_layout(state)
  match kind {
    "cancel" => {
      toolbar_cancel(state)
      (true, "")
    }
    "pointerDown" | "pointerMove" | "pointerUp" => {
      let x = match event.get("x") {
        Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 => n
        _ => return (false, "")
      }
      let y = match event.get("y") {
        Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 => n
        _ => return (false, "")
      }
      let hit = toolbar_hit(layout, x, y)
      state.hovered = match hit {
        Some(item) => item.id
        None => ""
      }
      if kind == "pointerMove" {
        return (true, "")
      }
      if kind == "pointerDown" {
        state.focus_visible = false
        state.pressed = match hit {
          Some(item) if item.enabled => item.id
          _ => ""
        }
        if state.pressed != "" {
          state.focused = state.pressed
        }
        return (true, "")
      }
      let pressed = state.pressed
      state.pressed = ""
      (
        true,
        if pressed != "" && pressed == state.hovered {
          toolbar_activate(state, pressed)
        } else {
          ""
        },
      )
    }
    "activate" =>
      (true, toolbar_activate(state, property_string(event, "id", "")))
    "key" => {
      if event.get("mod") == Some(Json(true)) {
        return (false, "")
      }
      let key = property_string(event, "key", "")
      if key == "Enter" || key == " " || key == "Space" {
        if state.focused == "" {
          return (false, "")
        }
        state.focus_visible = true
        return (true, toolbar_activate(state, state.focused))
      }
      if key != "Tab" &&
        key != "ArrowLeft" &&
        key != "ArrowRight" &&
        key != "Home" &&
        key != "End" {
        return (false, "")
      }
      let choices = state.items.filter(item => item.enabled)
      if choices.is_empty() {
        return (false, "")
      }
      let backward = key == "ArrowLeft" ||
        (key == "Tab" && event.get("shift") == Some(Json(true)))
      let mut current = -1
      for index, item in choices {
        if item.id == state.focused {
          current = index
        }
      }
      let next = if key == "Home" {
        0
      } else if key == "End" {
        choices.length() - 1
      } else if current < 0 {
        if backward {
          choices.length() - 1
        } else {
          0
        }
      } else {
        (current + choices.length() + (if backward { -1 } else { 1 })) %
        choices.length()
      }
      state.focused = choices[next].id
      state.focus_visible = true
      state.pressed = ""
      toolbar_reveal_focus(state)
      (true, "")
    }
    "scroll" => {
      // A host canvas can be wider than the compact row. Wheel input over its
      // unused area must not invisibly change the current toolbar page.
      let inside = match (event.get("x"), event.get("y")) {
        (Some(Number(x, ..)), Some(Number(y, ..))) =>
          x >= 0 &&
          x < layout.width * layout.scale &&
          y >= 0 &&
          y < 32 * layout.scale
        _ => false
      }
      if !inside {
        return (false, "")
      }
      let delta = match event.get("deltaX") {
        Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 && n != 0 => n
        _ =>
          match event.get("deltaY") {
            Some(Number(n, ..)) if n >= -1000000 && n <= 1000000 => n
            _ => return (false, "")
          }
      }
      if layout.pages <= 1 || delta == 0 {
        return (false, "")
      }
      ignore(
        toolbar_activate(
          state,
          if delta < 0 {
            "__toolbar.previous"
          } else {
            "__toolbar.next"
          },
        ),
      )
      (true, "")
    }
    _ => (false, "")
  }
}

///|
pub fn toolbar_surface_color(dark : Bool) -> Int32 {
  if dark { 0x27272a } else { 0xf1f1f3 }
}

///|
let light_disabled_icon_color : Int32 = 0x73737b

///|
pub fn toolbar_frame_json(state : ToolbarState, dark : Bool) -> String {
  let layout = toolbar_layout(state)
  let commands : Array[Json] = []
  let semantics : Array[Json] = []
  let scale = layout.scale
  let background = toolbar_surface_color(dark)
  for p in layout.placements {
    let item = p.item
    let pressed = state.pressed == item.id && state.hovered == item.id
    let hovered = state.hovered == item.id && item.enabled
    let focused = state.focused == item.id && item.enabled
    let show_focus = focused && state.focus_visible
    let fill = if pressed {
      if dark {
        0x48484e
      } else {
        0xd7d7dd
      }
    } else if item.selected {
      if dark {
        0x304562
      } else {
        0xdce8fa
      }
    } else if hovered {
      if dark {
        0x38383e
      } else {
        0xe6e6eb
      }
    } else {
      background
    }
    let ink = if !item.enabled {
      if dark {
        0x777777
      } else {
        light_disabled_icon_color
      }
    } else if dark {
      0xf5f5f5
    } else {
      0x252525
    }
    let rect = property_command(
      "rect",
      p.x * scale,
      4 * scale,
      24 * scale,
      24 * scale,
    )
    rect["radius"] = Json(5.0 * scale)
    if fill != background {
      rect["fill"] = Json(@icons.color(fill))
    }
    if show_focus {
      rect["stroke"] = Json(if dark { "#9abcf0" } else { "#4772ae" })
      rect["lineWidth"] = Json(scale)
    }
    if fill != background || show_focus {
      commands.push(Json::object(rect))
    }
    if item.asset_id != "" {
      let asset = property_command(
        "asset",
        (p.x + 3) * scale,
        7 * scale,
        18 * scale,
        18 * scale,
      )
      asset["assetId"] = Json(item.asset_id)
      commands.push(Json::object(asset))
    } else {
      for
        command in @icons.commands(
          item.icon,
          (p.x + 3) * scale,
          7 * scale,
          18 * scale,
          ink,
          fill,
        ) {
        commands.push(command)
      }
    }
    let semantic = property_rect(p.x * scale, 4 * scale, 24 * scale, 24 * scale)
    semantic["id"] = Json(item.id)
    semantic["role"] = Json("button")
    semantic["label"] = Json(item.title)
    semantic["tooltip"] = Json(
      if item.tooltip == "" {
        item.title
      } else {
        item.tooltip
      },
    )
    semantic["enabled"] = Json(item.enabled)
    semantic["focused"] = Json(focused)
    semantic["value"] = Json(item.selected)
    semantics.push(Json::object(semantic))
  }
  if layout.separator >= 0 {
    commands.push(
      Json::object({
        "type": Json("line"),
        "x1": Json(layout.separator * scale),
        "x2": Json(layout.separator * scale),
        "y1": Json(8.0 * scale),
        "y2": Json(24.0 * scale),
        "lineWidth": Json(scale),
        "color": Json(if dark { "#555555" } else { "#cccccc" }),
      }),
    )
  }
  Json::object({
    "ok": Json(true),
    "commands": Json::array(commands),
    "overlayCommands": Json::array([]),
    "semantics": Json::array(semantics),
    "cursor": Json("default"),
  }).stringify()
}
