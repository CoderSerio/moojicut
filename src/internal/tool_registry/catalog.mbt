///|
// Stable identity is independent of presentation order and the legacy style ABI.
priv enum ToolId {
  Rectangle
  Arrow
  Text
  Cover
  Pin
}

///|
priv enum ToolBehavior {
  Annotation(Int32)
  PinAction
}

///|
priv enum ToolGroup {
  Screenshot
  Recording
  VideoEditing
}

///|
fn ToolId::key(self : ToolId) -> String {
  match self {
    Rectangle => "builtin.image.rectangle"
    Arrow => "builtin.image.arrow"
    Text => "builtin.image.text"
    Cover => "builtin.image.cover"
    Pin => "builtin.image.pin"
  }
}

///|
fn ToolId::from_key(key : String) -> ToolId? {
  match key {
    "builtin.image.rectangle" => Some(Rectangle)
    "builtin.image.arrow" => Some(Arrow)
    "builtin.image.text" => Some(Text)
    "builtin.image.cover" => Some(Cover)
    "builtin.image.pin" => Some(Pin)
    _ => None
  }
}

///|
fn ToolId::behavior(self : ToolId) -> ToolBehavior {
  match self {
    Rectangle => Annotation(1)
    Arrow => Annotation(2)
    Text => Annotation(3)
    Cover => Annotation(4)
    Pin => PinAction
  }
}

///|
fn ToolId::plugin_id(self : ToolId) -> String {
  match self {
    Pin => "builtin.pin"
    _ => "builtin.image-editor"
  }
}

///|
fn ToolId::title(self : ToolId) -> String {
  match self {
    Rectangle => "矩形"
    Arrow => "箭头"
    Text => "文字"
    Cover => "遮挡"
    Pin => "贴图"
  }
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
fn catalog(group : ToolGroup) -> Array[ToolId] {
  match group {
    Screenshot => [Rectangle, Arrow, Text, Cover, Pin]
    _ => []
  }
}

///|
fn ToolId::belongs_to(_self : ToolId, group : ToolGroup) -> Bool {
  group is Screenshot
}

///|
// Unknown identities survive a save/reload, but cannot become executable tools.
priv enum AvailableTool {
  BuiltinTool(ToolId)
  PluginTool(@plugin_protocol.UserTool)
}

///|
fn AvailableTool::key(self : AvailableTool) -> String {
  match self {
    BuiltinTool(tool) => tool.key()
    PluginTool(tool) => tool.global_id()
  }
}

///|
fn AvailableTool::belongs_to(self : AvailableTool, group : ToolGroup) -> Bool {
  match self {
    BuiltinTool(tool) => tool.belongs_to(group)
    PluginTool(_) => group is Screenshot
  }
}

///|
priv struct Catalog {
  users : Array[@plugin_protocol.UserTool]
}

///|
fn Catalog::find(self : Catalog, key : String) -> AvailableTool? {
  if ToolId::from_key(key) is Some(tool) {
    return Some(BuiltinTool(tool))
  }
  for tool in self.users {
    if tool.global_id() == key {
      return Some(PluginTool(tool))
    }
  }
  None
}

///|
fn Catalog::all(self : Catalog, group : ToolGroup) -> Array[AvailableTool] {
  let result = catalog(group).map(tool => BuiltinTool(tool))
  if group is Screenshot {
    for tool in self.users {
      result.push(PluginTool(tool))
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
    .map(tool => { id: Known(tool), enabled: true, }),
    recording: [],
    video_editing: [],
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
        Screenshot,
        self.screenshot.map(entry => {
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
