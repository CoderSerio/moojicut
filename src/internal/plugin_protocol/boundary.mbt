///|
pub fn encode_manifest(manifest : Manifest) -> Json {
  Json::object({
    "apiVersion": Json(1),
    "pluginId": Json(manifest.plugin_id),
    "name": Json(manifest.name),
    "version": Json(manifest.version),
    "runtime": Json("extism-1"),
    "entry": Json("plugin.wasm"),
    "capabilities": Json::array([Json("capture.metadata"), Json("result.text")]),
    "tools": Json::array(
      manifest.tools.map(tool => {
        Json::object({
          "toolId": Json(tool.local_id),
          "title": Json(tool.title),
          "target": Json("screenshot"),
          "action": Json("run"),
        })
      }),
    ),
  })
}

///|
pub fn encode_tool(tool : UserTool, enabled : Bool) -> Json {
  Json::object({
    "id": Json(tool.global_id()),
    "pluginId": Json(tool.plugin_id),
    "toolId": Json(tool.local_id),
    "target": Json("screenshot"),
    "type": Json("action"),
    "action": Json("run"),
    "title": Json(tool.title),
    "enabled": Json(enabled),
  })
}

///|
pub fn plugin_manifest_validate(manifest_json : String) -> String {
  @protocol.response(() => {
    let manifest = decode_manifest(
      Json::object(parse_object(manifest_json, 65536)),
    )
    Json::object({
      "ok": Json(true),
      "manifest": encode_manifest(manifest),
      "tools": Json::array(manifest.tools.map(tool => encode_tool(tool, true))),
    })
  })
}

///|
pub fn plugin_request_prepare(request_json : String) -> String {
  @protocol.response(() => {
    let request = decode_request(parse_object(request_json, 131072))
    Json::object({
      "ok": Json(true),
      "request": Json::object({
        "apiVersion": Json(1),
        "invocationId": Json(request.invocation_id),
        "toolId": Json(request.tool.local_id),
        "capture": Json::object({
          "width": Json(request.capture.width),
          "height": Json(request.capture.height),
          "format": Json("png"),
          "revision": Json(request.capture.revision),
        }),
      }),
    })
  })
}

///|
pub fn plugin_output_validate(request_json : String) -> String {
  @protocol.response(() => {
    let result = decode_output(parse_object(request_json, 524288))
    Json::object({
      "ok": Json(true),
      "result": Json::object({
        "apiVersion": Json(1),
        "invocationId": Json(result.invocation_id),
        "kind": Json("text"),
        "title": Json(result.title),
        "text": Json(result.text),
      }),
    })
  })
}
