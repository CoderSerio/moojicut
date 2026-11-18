///|
priv struct ToolbarConfiguration {
  toolbar : Int32
  generation : Int32
  revision : Double
  style_revision : Int32
  edit : Int32
  edit_version : Int32
  facts : Json
  entries : Array[CaptureToolbarContribution]
  candidate : Int32
  end_tool : Bool
}

///|
let toolbar_configurations : Map[Int32, ToolbarConfiguration] = Map([])

///|
let toolbar_config_owners : Map[Int32, Int32] = Map([])

///|
let toolbar_config_next : Ref[Int32] = Ref(1)

///|
fn toolbar_config_retire(handle : Int32) -> Unit {
  if toolbar_config_owners.get(handle) is Some(ticket) {
    if toolbar_configurations.get(ticket) is Some(c) && c.candidate != 0 {
      ignore(candidate_close(c.candidate))
    }
    toolbar_configurations.remove(ticket)
    toolbar_config_owners.remove(handle)
  }
}

///|
pub fn toolbar_config_prepare(
  handle : Int32,
  entries : Array[CaptureToolbarContribution],
) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  if !toolbar_valid_entries(entries) ||
    // Configuration preflight cannot erase another window's live preview.
    toolbar_plugin_gestures.contains(t.image) ||
    t.effect != 0 ||
    t.blocked ||
    !toolbar_edit_valid(t) ||
    toolbar_config_next.val >= 2147483647 ||
    t.generation >= 2147483646 {
    return 0
  }
  let mut retained = t.active == "host.select"
  let edit = match text_active.get(t.image) {
    Some(id) => id
    None => 0
  }
  let mut edit_retained = edit == 0
  for e in entries {
    if e.enabled && toolbar_available(t, e) {
      if e.id == t.active && e.interaction != 0 {
        retained = true
      }
      if edit != 0 {
        let current = text_edits[edit]
        if (
            current.contribution_command == "" &&
            e.interaction == 1 &&
            e.kind == current.tool
          ) ||
          (
            current.contribution_command != "" &&
            e.interaction == 2 &&
            e.command == current.contribution_command
          ) {
          edit_retained = true
        }
      }
    }
  }
  let end_tool = !retained || !edit_retained
  let candidate = if end_tool { toolbar_prepare(t) } else { 0 }
  if end_tool && candidate == 0 {
    return 0
  }
  toolbar_config_retire(handle)
  let ticket = toolbar_config_next.val
  toolbar_config_next.val += 1
  toolbar_configurations[ticket] = {
    toolbar: handle,
    generation: t.generation,
    revision: image_session_revision(t.image),
    style_revision: editor_style_sessions[t.style].revision,
    edit,
    edit_version: if edit == 0 {
      0
    } else {
      text_edits[edit].version
    },
    facts: t.facts,
    entries: entries.copy(),
    candidate,
    end_tool,
  }
  toolbar_config_owners[handle] = ticket
  ticket
}

///|
pub fn toolbar_config_ready(handle : Int32, ticket : Int32) -> Int32 {
  let t = match toolbar_current(handle) {
    Some(t) => t
    None => return 0
  }
  let c = match toolbar_configurations.get(ticket) {
    Some(c) if c.toolbar == handle => c
    _ => return 0
  }
  if toolbar_config_owners.get(handle) != Some(ticket) ||
    toolbar_plugin_gestures.contains(t.image) ||
    t.effect != 0 ||
    t.blocked ||
    t.generation != c.generation ||
    t.facts != c.facts ||
    image_session_revision(t.image) != c.revision ||
    editor_style_sessions[t.style].revision != c.style_revision {
    return 0
  }
  if c.edit == 0 {
    if text_active.contains(t.image) {
      return 0
    }
  } else {
    match text_current(t.image, c.edit) {
      Some(e) if e.version == c.edit_version && text_error(e) == "" => ()
      _ => return 0
    }
  }
  if c.candidate != 0 && candidate_ready(t.image, c.candidate) == 0 {
    return 0
  }
  1
}

///|
pub fn toolbar_config_commit_many(request : String) -> Int32 {
  let items = match (text_json(request, 65536) catch { _ => return 0 }) {
    Array(items) if items.length() > 0 && items.length() <= 16 => items
    _ => return 0
  }
  let configs : Array[ToolbarConfiguration] = []
  let candidates : Array[TextCandidate] = []
  let seen : Map[Int32, Bool] = Map([])
  let styles : Map[Int32, Bool] = Map([])
  for item in items {
    let m = match item {
      Object(m) => m
      _ => return 0
    }
    let handle = (@protocol.integer_field(m, "toolbar", 1, 2147483646) catch {
      _ => return 0
    }).to_int()
    let ticket = (@protocol.integer_field(m, "candidate", 1, 2147483646) catch {
      _ => return 0
    }).to_int()
    if seen.contains(handle) || toolbar_config_ready(handle, ticket) == 0 {
      return 0
    }
    seen[handle] = true
    let c = toolbar_configurations[ticket]
    if c.candidate != 0 {
      let candidate = text_candidates[c.candidate]
      if candidate.defaults is Some(_) {
        if styles.contains(candidate.style) {
          return 0
        }
        styles[candidate.style] = true
      }
      candidates.push(candidate)
    }
    configs.push(c)
  }
  // A retained edit is a read lease on its defaults bank. Publishing another
  // window's defaults must not silently invalidate that still-live transaction.
  for c in configs {
    if c.candidate == 0 &&
      c.edit != 0 &&
      styles.contains(capture_toolbars[c.toolbar].style) {
      return 0
    }
  }
  // All validation precedes publication. No platform callback or fallible
  // operation is interleaved with document/default/configuration publication.
  for candidate in candidates {
    candidate_publish(candidate)
  }
  for c in configs {
    let t = capture_toolbars[c.toolbar]
    t.entries = c.entries
    if c.end_tool {
      t.active = "host.select"
    }
    t.generation += 1
    @capture_ui.toolbar_cancel(t.ui)
    toolbar_config_retire(c.toolbar)
  }
  1
}

///|
pub fn toolbar_config_close(ticket : Int32) -> Int32 {
  match toolbar_configurations.get(ticket) {
    Some(c) => {
      toolbar_config_retire(c.toolbar)
      1
    }
    None => 0
  }
}
