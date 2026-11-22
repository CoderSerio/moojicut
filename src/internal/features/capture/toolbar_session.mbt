///|
/// Only the app composition facade constructs these from a verified catalog.
/// The feature receives values, never borrows a catalog handle or imports runtime.
pub(all) struct CaptureToolbarContribution {
  id : String
  title : String
  icon : String
  command : String
  payload : String
  reason : String
  slot : Int32
  kind : Int32
  interaction : Int32
  capability : Int32
  enabled : Bool
  available : Bool
}

///|
priv struct CaptureToolbar {
  image : Int32
  style : Int32
  ui : @capture_ui.ToolbarState
  mut entries : Array[CaptureToolbarContribution]
  mut active : String
  mut generation : Int32
  mut width : Double
  mut facts : Json
  mut has_region : Bool
  mut blocked : Bool
  mut field_focused : Bool
  mut body_editing : Bool
  mut toolbar_focused : Bool
  mut pin_available : Bool
  mut capabilities : Int32
  mut measured_edit : Int32
  mut measured_version : Int32
  mut measured_height : Double
  mut assets : Map[String, Json]
  mut effect : Int32
  mut ticket : Int32
  mut candidate : Int32
  mut effect_id : String
  mut payload : String
  mut error : String
}

///|
let capture_toolbars : Map[Int32, CaptureToolbar] = Map([])

///|
let capture_toolbar_owners : Map[Int32, Int32] = Map([])

///|
let capture_toolbar_next : Ref[Int32] = Ref(1)

///|
let capture_toolbar_ticket : Ref[Int32] = Ref(1)

///|
fn toolbar_current(handle : Int32) -> CaptureToolbar? {
  match capture_toolbars.get(handle) {
    Some(t) if native_image_sessions.contains(t.image) &&
      editor_style_sessions.contains(t.style) => Some(t)
    _ => None
  }
}

///|
fn toolbar_entry(
  t : CaptureToolbar,
  id : String,
) -> CaptureToolbarContribution? {
  for e in t.entries {
    if e.id == id {
      return Some(e)
    }
  }
  None
}

///|
fn toolbar_valid_entries(entries : Array[CaptureToolbarContribution]) -> Bool {
  if entries.length() > 507 {
    return false
  }
  let seen : Map[String, Bool] = Map([])
  for e in entries {
    if e.id == "" ||
      e.id.has_prefix("host.") ||
      seen.contains(e.id) ||
      e.id.length() > 256 ||
      e.title.length() > 1024 ||
      e.payload.length() > 262144 ||
      (e.slot != 0 && e.slot != 1) ||
      e.kind < 0 ||
      e.kind > 4 ||
      e.interaction < 0 ||
      e.interaction > 2 ||
      e.capability < 0 ||
      e.capability > 31 {
      return false
    }
    seen[e.id] = true
  }
  true
}

///|
pub fn toolbar_open(
  image : Int32,
  style : Int32,
  entries : Array[CaptureToolbarContribution],
) -> Int32 {
  if !native_image_sessions.contains(image) ||
    !editor_style_sessions.contains(style) ||
    capture_toolbar_owners.contains(image) ||
    capture_toolbars.length() >= 16 ||
    capture_toolbar_next.val >= 2147483647 ||
    !toolbar_valid_entries(entries) {
    return 0
  }
  let handle = capture_toolbar_next.val
  capture_toolbar_next.val += 1
  capture_toolbars[handle] = {
    image,
    style,
    entries: entries.copy(),
    ui: @capture_ui.toolbar_new(),
    active: "host.select",
    generation: 1,
    width: 640,
    facts: Json::null(),
    has_region: false,
    blocked: false,
    field_focused: false,
    body_editing: false,
    toolbar_focused: false,
    pin_available: false,
    capabilities: -1,
    measured_edit: 0,
    measured_version: 0,
    measured_height: 0,
    assets: Map([]),
    effect: 0,
    ticket: 0,
    candidate: 0,
    effect_id: "",
    payload: "",
    error: "",
  }
  capture_toolbar_owners[image] = handle
  handle
}

///|
fn toolbar_bool(m : Map[String, Json], key : String) -> Bool? {
  match m.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

///|
fn toolbar_asset_valid(s : String) -> Bool {
  if s == "" || s.length() > 128 {
    return false
  }
  for c in s.to_array() {
    let n = c.to_int()
    if !((n >= 65 && n <= 90) ||
      (n >= 97 && n <= 122) ||
      (n >= 48 && n <= 57) ||
      n == 46 ||
      n == 95 ||
      n == 45) {
      return false
    }
  }
  true
}

///|
pub fn toolbar_context(handle : Int32, request : String) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  let m = @protocol.request_object(request) catch { _ => return 0 }
  let region = match toolbar_bool(m, "hasRegion") {
    Some(v) => v
    None => return 0
  }
  let blocked = match toolbar_bool(m, "blocked") {
    Some(v) => v
    None => return 0
  }
  let focused = match toolbar_bool(m, "fieldFocused") {
    Some(v) => v
    None => return 0
  }
  let body_editing = if m.contains("bodyEditing") {
    match toolbar_bool(m, "bodyEditing") {
      Some(v) => v
      None => return 0
    }
  } else {
    false
  }
  let toolbar_focused = if m.contains("toolbarFocused") {
    match toolbar_bool(m, "toolbarFocused") {
      Some(v) => v
      None => return 0
    }
  } else {
    false
  }
  let pin = match toolbar_bool(m, "pinAvailable") {
    Some(v) => v
    None => return 0
  }
  let edit = (@protocol.integer_field(m, "edit", 0, 2147483646) catch {
    _ => return 0
  }).to_int()
  let version = (@protocol.integer_field(m, "editVersion", 0, 2147483646) catch {
    _ => return 0
  }).to_int()
  let height = match m.get("measuredHeight") {
    Some(Number(v, ..)) if v >= 0 && v <= 65536 => v
    _ => return 0
  }
  let capabilities = if m.contains("capabilities") {
    (@protocol.integer_field(m, "capabilities", 0, 31) catch { _ => return 0 }).to_int()
  } else {
    -1
  }
  if edit == 0 {
    if text_active.contains(t.image) || version != 0 {
      return 0
    }
  } else {
    let e = match text_current(t.image, edit) {
      Some(e) => e
      None => return 0
    }
    if e.style != t.style || e.version != version {
      return 0
    }
  }
  let assets = match m.get("assets") {
    None => Map([])
    Some(Object(a)) => a
    _ => return 0
  }
  if assets.length() > 512 {
    return 0
  }
  for id, value in assets {
    if id.length() > 512 {
      return 0
    }
    match value {
      String(s) if toolbar_asset_valid(s) => ()
      _ => return 0
    }
  }
  t.facts = Json::object(m)
  t.has_region = region
  t.blocked = blocked
  t.field_focused = focused
  t.pin_available = pin
  t.toolbar_focused = toolbar_focused
  t.body_editing = body_editing
  t.capabilities = capabilities
  t.measured_edit = edit
  t.measured_version = version
  t.measured_height = height
  t.assets = assets
  1
}

///|
fn toolbar_edit(t : CaptureToolbar) -> TextEdit? {
  match text_active.get(t.image) {
    Some(id) => text_current(t.image, id)
    None => None
  }
}

///|
fn toolbar_edit_valid(t : CaptureToolbar) -> Bool {
  match toolbar_edit(t) {
    Some(e) => text_error(e) == ""
    None => true
  }
}

///|
fn toolbar_available(
  t : CaptureToolbar,
  e : CaptureToolbarContribution,
) -> Bool {
  if t.capabilities < 0 {
    e.available
  } else {
    (t.capabilities & e.capability) == e.capability
  }
}

///|
fn toolbar_history(t : CaptureToolbar, redo : Bool) -> Bool {
  match toolbar_edit(t) {
    Some(e) => {
      let field = text_value(
          t.image,
          text_active[t.image],
          if redo {
            11
          } else {
            10
          },
        ) ==
        1
      if t.field_focused || t.body_editing || field {
        return field
      }
      if text_error(e) != "" {
        return false
      }
    }
    None => ()
  }
  match
    native_image_sessions[t.image].document.get(
      if redo {
        "redo"
      } else {
        "undo"
      },
    ) {
    Some(Array(items)) => items.length() > 0
    _ => false
  }
}

///|
fn toolbar_allowed(t : CaptureToolbar, id : String) -> Bool {
  if t.effect != 0 {
    return false
  }
  if id == "host.cancel" {
    return true
  }
  if t.blocked {
    return false
  }
  if id == "host.undo" || id == "host.redo" {
    return toolbar_history(t, id == "host.redo")
  }
  if !toolbar_edit_valid(t) {
    return false
  }
  if id == "host.select" {
    return true
  }
  if id == "host.confirm" || id == "host.save" {
    return t.has_region
  }
  match toolbar_entry(t, id) {
    Some(e) if e.enabled && toolbar_available(t, e) =>
      if e.interaction != 0 {
        true
      } else {
        t.has_region && (e.command != "pin" || t.pin_available)
      }
    _ => false
  }
}

///|
fn toolbar_rejection(t : CaptureToolbar, id : String) -> String {
  if t.effect != 0 {
    return "正在处理当前操作"
  }
  if t.blocked {
    return "请先结束当前拖动或对话框"
  }
  if toolbar_edit(t) is Some(e) && text_error(e) != "" {
    return text_error(e)
  }
  if toolbar_entry(t, id) is Some(e) {
    if !e.enabled {
      return if e.command == "pin" {
        "贴图已关闭"
      } else {
        "工具已关闭"
      }
    }
    if !toolbar_available(t, e) {
      return "当前平台暂不支持此功能"
    }
    if e.command == "pin" && !t.pin_available {
      return "贴图已关闭"
    }
    if e.interaction == 0 && !t.has_region {
      return "请先选择截图区域"
    }
  }
  if (id == "host.confirm" || id == "host.save") && !t.has_region {
    return "请先选择截图区域"
  }
  if id == "host.undo" {
    return "没有可撤销的内容"
  }
  if id == "host.redo" {
    return "没有可重做的内容"
  }
  "操作当前不可用"
}

///|
fn toolbar_tooltip(t : CaptureToolbar, id : String, title : String) -> String {
  if toolbar_allowed(t, id) {
    title
  } else {
    title + "（" + toolbar_rejection(t, id) + "）"
  }
}

///|
fn toolbar_item(
  t : CaptureToolbar,
  id : String,
  title : String,
  icon : String,
  slot : Int32,
) -> @capture_ui.ToolbarItem {
  {
    id,
    title,
    tooltip: toolbar_tooltip(t, id, title),
    icon,
    asset_id: "",
    slot,
    enabled: toolbar_allowed(t, id),
    selected: t.active == id,
  }
}

///|
fn toolbar_items(t : CaptureToolbar) -> Array[@capture_ui.ToolbarItem] {
  let items = [toolbar_item(t, "host.select", "选择", "select", 0)]
  for e in t.entries {
    // The text result window needs a recognition provider to open.
    if e.enabled && e.slot == 0 && (e.command != "ocr" || toolbar_available(t, e)) {
      items.push({
        id: e.id,
        title: e.title,
        tooltip: toolbar_tooltip(t, e.id, e.title),
        icon: e.icon,
        asset_id: if e.id.has_prefix("user.") {
          image_string(t.assets, e.id, "")
        } else {
          ""
        },
        slot: 0,
        enabled: toolbar_allowed(t, e.id),
        selected: t.active == e.id,
      })
    }
  }
  items.push(toolbar_item(t, "host.undo", "撤销", "undo", 0))
  items.push(toolbar_item(t, "host.redo", "重做", "redo", 0))
  items.push(toolbar_item(t, "host.save", "保存到本地", "save", 1))
  for e in t.entries {
    if e.enabled && e.slot == 1 {
      items.push({
        id: e.id,
        title: e.title,
        tooltip: toolbar_tooltip(t, e.id, e.title),
        icon: e.icon,
        asset_id: if e.id.has_prefix("user.") {
          image_string(t.assets, e.id, "")
        } else {
          ""
        },
        slot: 1,
        enabled: toolbar_allowed(t, e.id),
        selected: false,
      })
    }
  }
  items.push(toolbar_item(t, "host.cancel", "取消", "close", 1))
  items.push(toolbar_item(t, "host.confirm", "复制截图", "check", 1))
  items
}

///|
pub fn toolbar_frame(handle : Int32, width : Double, dark : Int32) -> String {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return ""
  }
  if !(width >= 32 && width <= 65536) || (dark != 0 && dark != 1) {
    return ""
  }
  if !@capture_ui.toolbar_sync(t.ui, toolbar_items(t), width, t.generation) {
    return ""
  }
  t.width = width
  @capture_ui.toolbar_frame_json(t.ui, dark == 1)
}

///|
fn toolbar_prepare(t : CaptureToolbar) -> Int32 {
  match toolbar_edit(t) {
    Some(e) => {
      let edit = text_active[t.image]
      if e.style != t.style ||
        t.measured_edit != edit ||
        t.measured_version != e.version {
        return 0
      }
      text_prepare(t.image, edit, e.version, 1, t.measured_height)
    }
    None =>
      image_session_prepare_command(
        t.image,
        t.style,
        image_session_revision(t.image),
        "null",
        "null",
      )
  }
}

///|
fn toolbar_issue(
  t : CaptureToolbar,
  effect : Int32,
  id : String,
  payload : String,
  candidate : Int32,
) -> Int32 {
  let ticket = capture_toolbar_ticket.val
  toolbar_plugin_cancel(t.image)
  capture_toolbar_ticket.val += 1
  t.effect = effect
  t.ticket = ticket
  t.candidate = candidate
  t.effect_id = id
  t.payload = payload
  t.error = ""
  t.generation += 1
  @capture_ui.toolbar_cancel(t.ui)
  1
}

///|
pub fn toolbar_activate(
  handle : Int32,
  generation : Int32,
  id : String,
) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  if t.generation != generation ||
    generation >= 2147483645 ||
    capture_toolbar_ticket.val >= 2147483647 {
    return 0
  }
  t.error = ""
  if !toolbar_allowed(t, id) {
    t.error = toolbar_rejection(t, id)
    return 0
  }
  if id == "host.cancel" {
    return toolbar_issue(t, 3, id, "", 0)
  }
  if id == "host.undo" || id == "host.redo" {
    let redo = id == "host.redo"
    if toolbar_edit(t) is Some(e) {
      let edit = text_active[t.image]
      let field = text_value(t.image, edit, if redo { 11 } else { 10 }) == 1
      if t.field_focused || t.body_editing || field {
        if text_event_json(
            t.image,
            edit,
            e.version,
            Json::object({ "type": Json(if redo { "redo" } else { "undo" }) }).stringify(),
          ) ==
          0 {
          return 0
        }
        return toolbar_issue(t, 1, id, "", 0)
      }
    }
    let candidate = toolbar_prepare(t)
    if candidate == 0 || candidate_ready(t.image, candidate) == 0 {
      return 0
    }
    let c = text_candidates[candidate]
    let document = match
      candidate_apply(
        c.document,
        Json::object({ "type": Json(if redo { "redo" } else { "undo" }) }),
      ) {
      Some(d) => d
      None => {
        ignore(candidate_close(candidate))
        return 0
      }
    }
    candidate_publish({
      session: c.session,
      revision: c.revision,
      style: c.style,
      style_revision: c.style_revision,
      edit: c.edit,
      edit_version: c.edit_version,
      purpose: c.purpose,
      defaults: c.defaults,
      document,
    })
    return toolbar_issue(t, 1, id, "", 0)
  }
  let entry = toolbar_entry(t, id)
  let effect = if id == "host.select" {
    1
  } else if id == "host.save" {
    9
  } else if id == "host.confirm" {
    2
  } else {
    let e = entry.unwrap()
    if e.interaction != 0 {
      1
    } else {
      match e.command {
        "pin" => 4
        "ocr" => 5
        "translate" => 6
        "scroll" => 7
        "plugin.run" => 8
        _ => return 0
      }
    }
  }
  let candidate = toolbar_prepare(t)
  if candidate == 0 {
    t.error = "属性已改变，请完成输入后重试"
    return 0
  }
  let defer_commit = effect == 4 || effect == 9
  if !defer_commit && candidate_commit(t.image, candidate) == 0 {
    return 0
  }
  if effect == 1 {
    t.active = id
  }
  toolbar_issue(
    t,
    effect,
    id,
    match entry {
      Some(e) => e.payload
      None => ""
    },
    if defer_commit {
      candidate
    } else {
      0
    },
  )
}

///|
pub fn toolbar_event(
  handle : Int32,
  generation : Int32,
  event : String,
) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  if t.generation != generation {
    return 0
  }
  let input = @protocol.request_object(event) catch { _ => return 0 }
  t.error = ""
  if image_string(input, "type", "") == "key" {
    let key = image_string(input, "key", "")
    let modified = input.get("mod") == Some(Json(true))
    let shift = input.get("shift") == Some(Json(true))
    let id = if modified && (key == "z" || key == "Z") {
      if shift {
        "host.redo"
      } else {
        "host.undo"
      }
    } else if modified && (key == "y" || key == "Y") {
      "host.redo"
    } else if (modified && (key == "c" || key == "C")) ||
      (key == "Enter" && !t.toolbar_focused) {
      "host.confirm"
    } else if key == "Escape" {
      "host.cancel"
    } else {
      ""
    }
    if id != "" {
      return toolbar_activate(handle, generation, id)
    }
  }
  if !@capture_ui.toolbar_sync(t.ui, toolbar_items(t), t.width, t.generation) {
    return 0
  }
  let (handled, id) = @capture_ui.toolbar_input(t.ui, event)
  if id != "" {
    return toolbar_activate(handle, generation, id)
  }
  if handled {
    1
  } else {
    0
  }
}

///|
pub fn toolbar_ack(
  handle : Int32,
  ticket : Int32,
  success : Int32,
  error : String,
) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  if t.ticket != ticket ||
    t.effect == 0 ||
    (success != 0 && success != 1) ||
    error.length() > 4096 {
    return 0
  }
  let mut published = true
  if t.candidate != 0 {
    if success == 1 {
      published = candidate_commit(t.image, t.candidate) == 1
    }
    ignore(candidate_close(t.candidate))
  }
  t.error = if !published {
    "截图已改变，操作结果已过期"
  } else if success == 0 {
    error
  } else {
    ""
  }
  t.effect = 0
  t.ticket = 0
  t.candidate = 0
  t.effect_id = ""
  t.payload = ""
  t.generation += 1
  if published {
    1
  } else {
    0
  }
}

///|
pub fn toolbar_value(handle : Int32, key : Int32) -> Double {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return -1
  }
  match key {
    0 =>
      match toolbar_entry(t, t.active) {
        Some(e) => if e.interaction == 2 { 1 } else { e.kind.to_double() }
        None => 0
      }
    1 =>
      match toolbar_entry(t, t.active) {
        Some(e) => e.interaction.to_double()
        None => 0
      }
    2 => t.generation.to_double()
    3 | 4 => @capture_ui.toolbar_size(t.ui)[key - 3]
    5 => t.effect.to_double()
    6 => t.ticket.to_double()
    7 => t.candidate.to_double()
    _ => -1
  }
}

///|
pub fn toolbar_text(handle : Int32, key : Int32) -> String {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return ""
  }
  match key {
    0 => t.active
    1 =>
      match toolbar_entry(t, t.active) {
        Some(e) if e.interaction == 2 => e.command
        _ => ""
      }
    2 => t.effect_id
    3 => t.payload
    4 => t.error
    _ => ""
  }
}

///|
pub fn toolbar_tool_enabled(handle : Int32, kind : Int32) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  if kind == 0 {
    return 1
  }
  for e in t.entries {
    if e.interaction == 1 &&
      e.kind == kind &&
      e.enabled &&
      toolbar_available(t, e) {
      return 1
    }
  }
  0
}

///|
pub fn toolbar_close(handle : Int32) -> Int32 {
  let t = match capture_toolbars.get(handle) {
    Some(t) => t
    None => return 0
  }
  toolbar_plugin_cancel(t.image)
  toolbar_config_retire(handle)
  if t.candidate != 0 {
    ignore(candidate_close(t.candidate))
  }
  capture_toolbar_owners.remove(t.image)
  capture_toolbars.remove(handle)
  1
}
