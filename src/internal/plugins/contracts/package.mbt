///|
pub(all) enum PluginGesture {
  Invoke
  DragRect
}

///|
pub(all) enum PluginEffect {
  ShowText
  AddAnnotations
}

///|
pub fn PluginEffect::key(self : PluginEffect) -> String {
  match self {
    ShowText => "result.text"
    AddAnnotations => "capture.annotations.add"
  }
}

///|
pub struct PluginContribution {
  plugin_id : String
  tool_id : String
  title : String
  gesture : PluginGesture
  effect : PluginEffect
}

///|
pub fn PluginContribution::id(self : PluginContribution) -> String {
  "user." + self.plugin_id + "/" + self.tool_id
}

///|
pub struct PluginPackage {
  plugin_id : String
  name : String
  version : String
  priv contributions : Array[PluginContribution]
}

///|
pub fn PluginPackage::contributions(
  self : PluginPackage,
) -> Array[PluginContribution] {
  self.contributions.copy()
}

///|
pub fn PluginPackage::contribution(
  self : PluginPackage,
  id : String,
) -> PluginContribution? {
  for contribution in self.contributions {
    if contribution.id() == id {
      return Some(contribution)
    }
  }
  None
}

///|
fn require_plugin_version(fields : Map[String, Json]) -> Unit raise InputError {
  if fields.get("apiVersion") != Some(Json(2)) {
    raise InputError("unsupported_api_version", "Expected plugin API version 2")
  }
}

///|
pub fn parse_plugin_package(text : String) -> PluginPackage raise InputError {
  let code = "invalid_manifest"
  let fields = parse_object(text, 65536)
  require_plugin_version(fields)
  exact_fields(
    fields,
    ["apiVersion", "pluginId", "name", "version", "entry", "runtime", "tools"],
    code,
  )
  let plugin_id = string(fields, "pluginId", 96, code)
  let name = display_string(fields, "name", code)
  let version = string(fields, "version", 29, code)
  if !plugin_id_valid(plugin_id) || !version_valid(version) {
    raise InputError(code, "Expected reverse-domain pluginId and X.Y.Z version")
  }
  if fields.get("entry") != Some(Json("plugin.wasm")) ||
    fields.get("runtime") != Some(Json("extism-1")) {
    raise InputError(code, "Expected plugin.wasm and extism-1")
  }
  let tools = match fields.get("tools") {
    Some(Array(tools)) if tools.length() >= 1 && tools.length() <= 16 => tools
    _ => raise InputError(code, "A package must have 1–16 tools")
  }
  let contributions : Array[PluginContribution] = []
  let seen : Map[String, Bool] = Map([])
  for tool in tools {
    let tool = object(tool, code, "Tool")
    exact_fields(tool, ["toolId", "title", "gesture", "effect"], code)
    let tool_id = string(tool, "toolId", 48, code)
    if !local_key_valid(tool_id) || seen.contains(tool_id) {
      raise InputError(code, "Tool IDs must be unique lowercase local keys")
    }
    seen[tool_id] = true
    let gesture = match tool.get("gesture") {
      Some(String("invoke")) => Invoke
      Some(String("dragRect")) => DragRect
      _ => raise InputError(code, "Expected an invoke or dragRect tool")
    }
    let effect = match tool.get("effect") {
      Some(String("result.text")) => ShowText
      Some(String("capture.annotations.add")) => AddAnnotations
      _ => raise InputError("unsupported_capability", "Unknown plugin effect")
    }
    if effect is AddAnnotations && gesture is Invoke {
      raise InputError(code, "Annotation tools require a rectangle gesture")
    }
    contributions.push({
      plugin_id,
      tool_id,
      title: display_string(tool, "title", code),
      gesture,
      effect,
    })
  }
  { plugin_id, name, version, contributions, }
}

///|
pub fn plugin_health_request() -> String {
  Json::object({ "apiVersion": Json(2), "operation": Json("health") }).stringify()
}

///|
pub fn PluginPackage::validate_health(
  self : PluginPackage,
  response : String,
) -> Unit raise InputError {
  let code = "invalid_health"
  let output = parse_object(response, 4096)
  require_plugin_version(output)
  exact_fields(output, ["apiVersion", "operation", "toolIds"], code)
  if output.get("operation") != Some(Json("health")) {
    raise InputError(code, "Expected a health response")
  }
  let ids = match output.get("toolIds") {
    Some(Array(ids)) if ids.length() == self.contributions.length() => ids
    _ => raise InputError(code, "Expected the tools declared by the package")
  }
  for contribution in self.contributions {
    if !ids.contains(Json(contribution.tool_id)) {
      raise InputError(code, "Health tools must match the package declaration")
    }
  }
}
