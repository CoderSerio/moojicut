///|
// Fixture contributions are supplied by the caller, just like app composition.
fn fixture_contributions() -> Array[@plugin_protocol.ToolContribution] {
  let tools : Array[@plugin_protocol.ToolContribution] = []
  for
    (id, title, kind) in [
      ("rectangle", "矩形", 1),
      ("arrow", "箭头", 2),
      ("text", "文字", 3),
      ("cover", "遮挡", 4),
      ("pin", "贴图", 0),
    ] {
    tools.push({
      id: "builtin.image." + id,
      plugin_id: if kind == 0 {
        "builtin.pin"
      } else {
        "builtin.image-editor"
      },
      target: "screenshot",
      title,
      icon: id,
      slot: if kind == 0 {
        "finish"
      } else {
        "tools"
      },
      behavior: if kind == 0 {
        "action"
      } else {
        "annotation"
      },
      command: if kind == 0 {
        "pin"
      } else {
        "capture.annotate"
      },
      interaction: if kind == 0 {
        "invoke"
      } else {
        "annotation"
      },
      annotation_kind: kind,
      default_enabled: true,
      capability: 0,
      requires: "",
      payload: Json::object({}),
    })
  }
  tools
}

///|
fn tool_registry_normalize(saved : String) -> String {
  normalize(fixture_contributions(), saved)
}

///|
fn tool_registry_update(request : String) -> String {
  update_catalog(fixture_contributions(), request)
}

///|
fn tool_registry_resolve(request : String) -> String {
  resolve_catalog(fixture_contributions(), request)
}
