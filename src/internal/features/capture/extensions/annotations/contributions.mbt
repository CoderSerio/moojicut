///|
pub fn contributions() -> Array[@plugin_protocol.ToolContribution] {
  [
    ("rectangle", "矩形", "rectangle", 1),
    ("arrow", "箭头", "arrow", 2),
    ("text", "文字", "text", 3),
    ("cover", "遮挡", "redact", 4),
  ].map(item => {
    let (id, title, icon, kind) = item
    {
      id: "builtin.image." + id,
      plugin_id: "builtin.image-editor",
      target: "screenshot",
      title,
      icon,
      slot: "tools",
      behavior: "annotation",
      command: "capture.annotate",
      interaction: "annotation",
      annotation_kind: kind,
      default_enabled: true,
      capability: 0,
      requires: "",
      payload: @json.Json::object({}),
    }
  })
}

///|
pub fn numbered_rectangle_contribution() -> @plugin_protocol.ToolContribution {
  {
    id: "builtin.image.numberedRectangle",
    plugin_id: "builtin.image-editor",
    target: "screenshot",
    title: "编号框",
    icon: "rectangle",
    slot: "tools",
    behavior: "command",
    command: "capture.numberedRectangle",
    interaction: "dragRect",
    annotation_kind: 0,
    default_enabled: false,
    capability: 8,
    requires: "commands",
    payload: @json.Json::object({ "previewKind": @json.Json(1) }),
  }
}
