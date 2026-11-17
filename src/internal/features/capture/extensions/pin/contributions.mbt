///|
pub fn contribution() -> @plugin_protocol.ToolContribution {
  {
    id: "builtin.image.pin",
    plugin_id: "builtin.pin",
    target: "screenshot",
    title: "贴图",
    icon: "pin",
    slot: "finish",
    behavior: "action",
    command: "pin",
    interaction: "invoke",
    annotation_kind: 0,
    default_enabled: true,
    capability: 0,
    requires: "",
    payload: @json.Json::object({}),
  }
}
