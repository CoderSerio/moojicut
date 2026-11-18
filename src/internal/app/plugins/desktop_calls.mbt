///|
fn DesktopPlugins::capture_owner(
  self : DesktopPlugins,
  id : Int32,
) -> @runtime.OwnerSnapshot raise InputError {
  let revision = @capture.image_session_revision(id)
  let owner = match self.owners.get(id) {
    Some(old) if old.revision == revision => Some(old)
    Some(old) => self.runtime.update_owner(old, revision)
    None => self.runtime.open_owner(id, revision)
  }
  guard owner is Some(owner) else {
    raise InputError("stale_invocation", "Screenshot is no longer active")
  }
  self.owners[id] = owner
  owner
}

///|
fn host_coordinate(
  fields : Map[String, Json],
  key : String,
) -> Double raise InputError {
  match fields.get(key) {
    Some(Number(value, ..)) => value
    _ => raise InputError("invalid_input", "Invalid selection coordinate")
  }
}

///|
fn host_selection(
  fields : Map[String, Json],
) -> @contract.PluginSelection? raise InputError {
  match fields.get("selection") {
    Some(Null) => None
    Some(Object(rect)) =>
      Some({
        x: host_coordinate(rect, "x"),
        y: host_coordinate(rect, "y"),
        width: host_coordinate(rect, "width"),
        height: host_coordinate(rect, "height"),
      })
    _ =>
      raise InputError("invalid_input", "selection must be a rectangle or null")
  }
}

///|
fn host_tool_package(tool : String) -> String {
  let parts = tool.split("/").to_array()
  if parts.length() != 2 {
    return ""
  }
  let name = parts[0].to_owned()
  if name.has_prefix("user.") {
    name[5:].to_owned()
  } else {
    ""
  }
}

///|
fn DesktopPlugins::start_call(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  let capture = host_id(fields, "capture")
  let tool = host_string(fields, "tool")
  let plugin_id = host_tool_package(tool)
  guard self.installed.get(plugin_id) is Some(installed) else {
    raise InputError("unknown_tool", "Tool package is not installed")
  }
  let selection = host_selection(fields)
  let owner = self.capture_owner(capture)
  let ticket = self.allocate()
  let call = installed.begin_capture_call(
    owner,
    tool,
    "capture-\{ticket}",
    selection,
  )
  self.calls[ticket] = call
  plugin_ok({
    "ticket": Json(ticket),
    "digest": Json(installed.installed.content.digest),
    "request": Json(call.request()),
  })
}

///|
fn DesktopPlugins::finish_call(
  self : DesktopPlugins,
  fields : Map[String, Json],
) -> Json raise InputError {
  let id = host_id(fields, "ticket")
  guard self.calls.get(id) is Some(call) else {
    raise InputError("stale_ticket", "Plugin call is no longer active")
  }
  let response = match fields.get("output") {
    Some(String(output)) => Some(output)
    Some(Null) => None
    _ => raise InputError("invalid_input", "output must be UTF-8 JSON or null")
  }
  self.calls.remove(id)
  match response {
    None => {
      call.worker_failed()
      plugin_ok({ "result": Json("discarded") })
    }
    Some(output) =>
      match call.complete(output) {
        DocumentChanged => plugin_ok({ "result": Json("documentChanged") })
        ShowText(title, text) =>
          plugin_ok({
            "result": Json("text"),
            "title": Json(title),
            "text": Json(text),
          })
        Discarded => plugin_ok({ "result": Json("discarded") })
      }
  }
}
