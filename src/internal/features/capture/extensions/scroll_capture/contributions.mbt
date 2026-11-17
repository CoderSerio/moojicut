///|
pub fn contribution() -> @plugin_protocol.ToolContribution {
  {
    id: "builtin.capture.scroll",
    plugin_id: "builtin.scroll",
    target: "screenshot",
    title: "滚动截图",
    icon: "scroll",
    slot: "tools",
    behavior: "action",
    command: "scroll",
    interaction: "invoke",
    annotation_kind: 0,
    default_enabled: false,
    capability: 4,
    requires: "scroll",
    payload: @json.Json::object({}),
  }
}
