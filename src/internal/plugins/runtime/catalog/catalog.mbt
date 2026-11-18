///|
priv enum ToolGroup {
  Screenshot
  Recording
  VideoEditing
}

///|
fn ToolGroup::key(self : ToolGroup) -> String {
  match self {
    Screenshot => "screenshot"
    Recording => "recording"
    VideoEditing => "videoEditing"
  }
}

///|
fn ToolGroup::from_key(key : String) -> ToolGroup? {
  match key {
    "screenshot" => Some(Screenshot)
    "recording" => Some(Recording)
    "videoEditing" => Some(VideoEditing)
    _ => None
  }
}

///|
// Unknown identities survive a save/reload, but cannot become executable tools.
priv enum AvailableTool {
  BuiltinTool(@plugin_protocol.ToolContribution)
  PluginTool(@plugin_protocol.UserTool)
  PackageTool(@plugin_protocol.PluginContribution)
}

///|
fn AvailableTool::key(self : AvailableTool) -> String {
  match self {
    BuiltinTool(tool) => tool.id
    PluginTool(tool) => tool.global_id()
    PackageTool(tool) => tool.id()
  }
}

///|
fn AvailableTool::belongs_to(self : AvailableTool, group : ToolGroup) -> Bool {
  match self {
    BuiltinTool(tool) => tool.target == group.key()
    PluginTool(_) | PackageTool(_) => group is Screenshot
  }
}

///|
fn AvailableTool::default_enabled(self : AvailableTool) -> Bool {
  match self {
    BuiltinTool(tool) => tool.default_enabled
    PluginTool(_) | PackageTool(_) => true
  }
}

///|
fn AvailableTool::slot(self : AvailableTool) -> String {
  match self {
    BuiltinTool(tool) => tool.slot
    PluginTool(_) | PackageTool(_) => "tools"
  }
}

///|
fn AvailableTool::group(self : AvailableTool) -> ToolGroup {
  match self {
    BuiltinTool(tool) => ToolGroup::from_key(tool.target).unwrap()
    PluginTool(_) | PackageTool(_) => Screenshot
  }
}

///|
priv struct Catalog {
  builtins : Array[@plugin_protocol.ToolContribution]
  users : Array[AvailableTool]
  manifests : Array[Json]
}

///|
fn Catalog::find(self : Catalog, key : String) -> AvailableTool? {
  for tool in self.builtins {
    if tool.id == key {
      return Some(BuiltinTool(tool))
    }
  }
  for tool in self.users {
    if tool.key() == key {
      return Some(tool)
    }
  }
  None
}

///|
fn Catalog::all(self : Catalog, group : ToolGroup) -> Array[AvailableTool] {
  let result : Array[AvailableTool] = []
  for tool in self.builtins {
    if tool.target == group.key() {
      result.push(BuiltinTool(tool))
    }
  }
  if group is Screenshot {
    for tool in self.users {
      result.push(tool)
    }
  }
  result
}

///|
priv enum SavedId {
  Known(AvailableTool)
  Unknown(String)
}

///|
fn SavedId::key(self : SavedId) -> String {
  match self {
    Known(tool) => tool.key()
    Unknown(key) => key
  }
}

///|
priv struct Entry {
  id : SavedId
  enabled : Bool
}

///|
priv struct Layout {
  screenshot : Array[Entry]
  recording : Array[Entry]
  video_editing : Array[Entry]
}

///|
fn Layout::entries(self : Layout, group : ToolGroup) -> Array[Entry] {
  match group {
    Screenshot => self.screenshot
    Recording => self.recording
    VideoEditing => self.video_editing
  }
}

///|
fn Layout::with_entries(
  self : Layout,
  group : ToolGroup,
  entries : Array[Entry],
) -> Layout {
  match group {
    Screenshot =>
      {
        screenshot: entries,
        recording: self.recording,
        video_editing: self.video_editing,
      }
    Recording =>
      {
        screenshot: self.screenshot,
        recording: entries,
        video_editing: self.video_editing,
      }
    VideoEditing =>
      {
        screenshot: self.screenshot,
        recording: self.recording,
        video_editing: entries,
      }
  }
}

///|
fn default_layout(catalog : Catalog) -> Layout {
  {
    screenshot: catalog
    .all(Screenshot)
    .map(tool => { id: Known(tool), enabled: tool.default_enabled(), }),
    recording: catalog
    .all(Recording)
    .map(tool => { id: Known(tool), enabled: tool.default_enabled(), }),
    video_editing: catalog
    .all(VideoEditing)
    .map(tool => { id: Known(tool), enabled: tool.default_enabled(), }),
  }
}

///|
priv enum Command {
  SetEnabled(AvailableTool, Bool)
  Move(ToolGroup, AvailableTool, AvailableTool?)
}

///|
// Configuration changes only. Feature gates, live gestures, documents and style
// sessions remain owned by their existing core/host components.
fn Layout::apply(self : Layout, command : Command) -> Layout {
  match command {
    SetEnabled(tool, enabled) =>
      self.with_entries(
        tool.group(),
        self
        .entries(tool.group())
        .map(entry => {
          if entry.id.key() == tool.key() {
            { id: entry.id, enabled, }
          } else {
            entry
          }
        }),
      )
    Move(group, tool, before) => {
      if before is Some(other) && other.key() == tool.key() {
        return self
      }
      let remaining : Array[Entry] = []
      let mut moved : Entry? = None
      for entry in self.entries(group) {
        if entry.id.key() == tool.key() {
          moved = Some(entry)
        } else {
          remaining.push(entry)
        }
      }
      // A normalized layout always contains every built-in in its own group.
      let moved = moved.unwrap()
      let next : Array[Entry] = []
      for entry in remaining {
        if before is Some(other) && entry.id.key() == other.key() {
          next.push(moved)
        }
        next.push(entry)
      }
      if before is None {
        next.push(moved)
      }
      self.with_entries(group, next)
    }
  }
}
