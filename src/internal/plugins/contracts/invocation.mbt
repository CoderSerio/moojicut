///|
pub(all) struct PluginSelection {
  x : Double
  y : Double
  width : Double
  height : Double
}

///|
pub(all) struct PluginCapture {
  width : Int32
  height : Int32
  revision : Double
  selection : PluginSelection?
}

///|
pub struct PluginInvocation {
  priv invocation_id : String
  priv effect : PluginEffect
  priv request : String
}

///|
pub(all) enum PluginResponse {
  Text(String, String)
  Annotations(Array[Json])
}

///|
pub fn PluginInvocation::request(self : PluginInvocation) -> String {
  self.request
}

///|
pub fn PluginInvocation::effect_key(self : PluginInvocation) -> String {
  self.effect.key()
}

///|
pub fn PluginPackage::prepare_invocation(
  self : PluginPackage,
  contribution_id : String,
  request_id : String,
  capture : PluginCapture,
) -> PluginInvocation raise InputError {
  let code = "invalid_request"
  let tool = match self.contribution(contribution_id) {
    Some(tool) => tool
    None =>
      raise InputError("unknown_tool", "Tool does not belong to this package")
  }
  let id = invocation_id({ "invocationId": Json(request_id) })
  if capture.width < 1 ||
    capture.width > 32768 ||
    capture.height < 1 ||
    capture.height > 32768 ||
    !(capture.revision >= 0 && capture.revision <= 9007199254740990) ||
    @double.floor(capture.revision) != capture.revision {
    raise InputError(code, "Invalid screenshot metadata")
  }
  let selection = match (tool.gesture, capture.selection) {
    (Invoke, None) => Json::null()
    (DragRect, Some(rect)) if rect.x >= 0 &&
      rect.y >= 0 &&
      rect.width >= 1 &&
      rect.height >= 1 &&
      rect.x + rect.width <= capture.width.to_double() &&
      rect.y + rect.height <= capture.height.to_double() =>
      Json::object({
        "x": Json(rect.x),
        "y": Json(rect.y),
        "width": Json(rect.width),
        "height": Json(rect.height),
      })
    _ =>
      raise InputError(
        code, "Selection does not match the tool gesture or screenshot",
      )
  }
  let request = Json::object({
    "apiVersion": Json(2),
    "operation": Json("invoke"),
    "invocationId": Json(id),
    "toolId": Json(tool.tool_id),
    "capture": Json::object({
      "width": Json(capture.width),
      "height": Json(capture.height),
      "format": Json("png"),
      "revision": Json(capture.revision),
    }),
    "selection": selection,
  }).stringify()
  { invocation_id: id, effect: tool.effect, request, }
}

///|
pub fn PluginInvocation::validate_output(
  self : PluginInvocation,
  response : String,
) -> PluginResponse raise InputError {
  let code = "invalid_output"
  let output = parse_object(response, 262144)
  require_plugin_version(output)
  if output.get("invocationId") != Some(Json(self.invocation_id)) {
    raise InputError(
      "invocation_mismatch", "Output belongs to a different invocation",
    )
  }
  match (self.effect, output.get("kind")) {
    (ShowText, Some(String("text"))) => {
      exact_fields(
        output,
        ["apiVersion", "invocationId", "kind", "title", "text"],
        code,
      )
      let title = display_string(output, "title", code)
      let text = string(output, "text", 32768, code)
      if @utf8.encode(text).length() > 32768 {
        raise InputError("limit_exceeded", "Result text exceeds 32 KiB UTF-8")
      }
      for char in text.iter() {
        if (char.to_int() < 32 && char != '\n' && char != '\t') ||
          char.to_int() == 127 {
          raise InputError(code, "Result text contains a control character")
        }
      }
      Text(title, text)
    }
    (AddAnnotations, Some(String("annotations"))) => {
      exact_fields(
        output,
        ["apiVersion", "invocationId", "kind", "annotations"],
        code,
      )
      match output.get("annotations") {
        Some(Array(annotations)) if annotations.length() >= 1 &&
          annotations.length() <= 16 => Annotations(annotations)
        _ => raise InputError(code, "Expected 1–16 annotations")
      }
    }
    _ =>
      raise InputError(
        "unsupported_effect", "Output is outside the tool's declared effect",
      )
  }
}
