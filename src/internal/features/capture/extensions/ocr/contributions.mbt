///|
pub fn contribution() -> @plugin_protocol.ToolContribution {
  {
    id: "builtin.capture.ocr",
    plugin_id: "builtin.ocr",
    target: "screenshot",
    title: "识别文字",
    icon: "ocr",
    slot: "tools",
    behavior: "action",
    command: "ocr",
    interaction: "invoke",
    annotation_kind: 0,
    default_enabled: true,
    capability: 1,
    requires: "ocr",
    payload: @json.Json::object({}),
  }
}
