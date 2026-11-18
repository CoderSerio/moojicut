///|
// User rectangles borrow the built-in gesture reducer and preview. They are
// input drafts, never provisional document annotations or worker leases.
priv struct ToolbarPluginGesture {
  toolbar : Int32
  generation : Int32
  contribution : String
  revision : Double
  x : Double
  y : Double
  width : Double
  height : Double
  effect : Json
}

///|
let toolbar_plugin_gestures : Map[Int32, ToolbarPluginGesture] = Map([])

///|
fn toolbar_plugin_cancel(image : Int32) -> Unit {
  if toolbar_plugin_gestures.contains(image) {
    toolbar_plugin_gestures.remove(image)
    if native_image_sessions.get(image) is Some(s) {
      ignore(
        @capture_ui.event(
          Json::object({ "session": Json(s.gesture), "type": Json("cancel") }).stringify(),
        ),
      )
      s.preview = Json::null()
      s.contribution = ""
      s.gesture_revision = Json::null()
    }
  }
}

///|
fn toolbar_plugin_begin(
  image : Int32,
  x : Double,
  y : Double,
  color : Int32,
  stroke : Double,
  opacity : Double,
  block : Double,
) -> Int32 {
  let s = match native_image_sessions.get(image) {
    Some(s) => s
    None => return 0
  }
  let handle = match capture_toolbar_owners.get(image) {
    Some(handle) => handle
    None => return 0
  }
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  let entry = match toolbar_entry(t, t.active) {
    Some(entry) if entry.command == "plugin.run" && entry.interaction == 2 =>
      entry
    _ => return 0
  }
  if !t.has_region ||
    !toolbar_allowed(t, entry.id) ||
    text_active.contains(image) ||
    text_candidate_sessions.contains(image) ||
    toolbar_config_owners.contains(handle) ||
    @capture_ui.active(s.gesture) ||
    t.generation >= 2147483645 ||
    capture_toolbar_ticket.val >= 2147483647 {
    return 0
  }
  let effect = match
    (text_json(entry.payload, 262144) catch { _ => return 0 }) {
    Object({ "effect": String(effect), .. }) if effect.length() > 0 &&
      effect.length() <= 160 => Json(effect)
    _ => return 0
  }
  let viewport_x = image_session_viewport_value(image, 0)
  let viewport_y = image_session_viewport_value(image, 1)
  let width = image_session_viewport_value(image, 2)
  let height = image_session_viewport_value(image, 3)
  if !(x >= viewport_x &&
    y >= viewport_y &&
    x <= viewport_x + width &&
    y <= viewport_y + height) {
    return 0
  }
  if image_session_shape_begin(image, 1, x, y, color, stroke, opacity, 0, block) ==
    0 {
    return 0
  }
  toolbar_plugin_gestures[image] = {
    toolbar: handle,
    generation: t.generation,
    contribution: entry.id,
    revision: image_session_revision(image),
    x: viewport_x,
    y: viewport_y,
    width,
    height,
    effect,
  }
  1
}

///|
fn toolbar_plugin_current(
  image : Int32,
  gesture : ToolbarPluginGesture,
) -> CaptureToolbar? {
  let t = match toolbar_current(gesture.toolbar) {
    Some(t) => t
    None => return None
  }
  if t.image != image ||
    capture_toolbar_owners.get(image) != Some(gesture.toolbar) ||
    t.generation != gesture.generation ||
    t.active != gesture.contribution ||
    t.effect != 0 ||
    !t.has_region ||
    image_session_revision(image) != gesture.revision ||
    text_active.contains(image) ||
    text_candidate_sessions.contains(image) ||
    toolbar_config_owners.contains(gesture.toolbar) {
    return None
  }
  match toolbar_entry(t, gesture.contribution) {
    Some(e) if e.enabled &&
      e.command == "plugin.run" &&
      e.interaction == 2 &&
      toolbar_available(t, e) => Some(t)
    _ => None
  }
}

///|
fn toolbar_plugin_event(
  image : Int32,
  phase : Int32,
  x : Double,
  y : Double,
) -> Int32 {
  let gesture = match toolbar_plugin_gestures.get(image) {
    Some(gesture) => gesture
    None => return 0
  }
  if phase == 2 {
    toolbar_plugin_cancel(image)
    return 1
  }
  if (phase != 0 && phase != 1) ||
    !(x >= -1000000 && x <= 1000000 && y >= -1000000 && y <= 1000000) {
    return 0
  }
  let t = match toolbar_plugin_current(image, gesture) {
    Some(t) => t
    None => {
      toolbar_plugin_cancel(image)
      return 0
    }
  }
  let s = native_image_sessions[image]
  // Native pointers are in source-image coordinates. Only the root knows the
  // crop; preview stays in source pixels and release maps it once to viewport
  // pixels. Reverse and outside drags retain the existing UI geometry rules.
  let x = @protocol.larger(
    gesture.x,
    @protocol.smaller(gesture.x + gesture.width, x),
  )
  let y = @protocol.larger(
    gesture.y,
    @protocol.smaller(gesture.y + gesture.height, y),
  )
  let result = @json.parse(
    @capture_ui.event(
      Json::object({
        "session": Json(s.gesture),
        "type": Json(if phase == 0 { "move" } else { "end" }),
        "x": Json(x),
        "y": Json(y),
      }).stringify(),
    ),
  ) catch {
    _ => return 0
  }
  let (preview, command) = match result {
    Object({ "ok": True, "preview": preview, "command": command, .. }) =>
      (preview, command)
    _ => return 0
  }
  s.preview = preview
  if phase == 0 {
    return 1
  }
  // Clear ownership before dispatch. Duplicate releases cannot enqueue another
  // request; effect ACK is dispatch acceptance, never worker completion.
  toolbar_plugin_cancel(image)
  if command is Null {
    return 1
  }
  let rectangle = match command {
    Object({ "annotations": Array([Object(rectangle)]), .. }) => rectangle
    _ => return 0
  }
  if t.generation >= 2147483645 || capture_toolbar_ticket.val >= 2147483647 {
    return 0
  }
  let payload = Json::object({
    "effect": gesture.effect,
    "capture": Json::object({
      "width": Json(gesture.width),
      "height": Json(gesture.height),
      "format": Json("png"),
      "revision": Json(gesture.revision),
    }),
    "selection": Json::object({
      "x": Json(image_number(rectangle, "x", 0) - gesture.x),
      "y": Json(image_number(rectangle, "y", 0) - gesture.y),
      "width": rectangle["width"],
      "height": rectangle["height"],
    }),
  })
  toolbar_issue(t, 8, gesture.contribution, payload.stringify(), 0)
}
