///|
pub fn contribution() -> @plugin_protocol.ToolContribution {
  {
    id: "builtin.capture.translate",
    plugin_id: "builtin.translation",
    target: "screenshot",
    title: "翻译",
    icon: "translate",
    slot: "tools",
    behavior: "action",
    command: "translate",
    interaction: "invoke",
    annotation_kind: 0,
    default_enabled: true,
    capability: 2,
    requires: "translate",
    payload: @json.Json::object({}),
  }
}
