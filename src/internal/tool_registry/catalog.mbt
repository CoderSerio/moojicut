///|
// Stable identity is independent of presentation order and the legacy style ABI.
priv enum ToolId {
  Rectangle
  Arrow
  Text
  Cover
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
  }
}

///|
fn ToolId::from_key(key : String) -> ToolId? {
  match key {
    "builtin.image.rectangle" => Some(Rectangle)
    "builtin.image.arrow" => Some(Arrow)
    "builtin.image.text" => Some(Text)
    "builtin.image.cover" => Some(Cover)
    _ => None
  }
}

///|
fn ToolId::kind(self : ToolId) -> Int32 {
  match self {
    Rectangle => 1
    Arrow => 2
    Text => 3
    Cover => 4
  }
}

///|
fn ToolId::title(self : ToolId) -> String {
  match self {
    Rectangle => "矩形"
    Arrow => "箭头"
    Text => "文字"
    Cover => "遮挡"
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
    Screenshot => [Rectangle, Arrow, Text, Cover]
    _ => []
  }
}

///|
fn ToolId::belongs_to(_self : ToolId, group : ToolGroup) -> Bool {
  group is Screenshot
}

///|
// Unknown identities survive a save/reload, but cannot become executable tools.
priv enum SavedId {
  Builtin(ToolId)
  Unknown(String)
}

///|
fn SavedId::key(self : SavedId) -> String {
  match self {
    Builtin(tool) => tool.key()
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
fn default_layout() -> Layout {
  {
    screenshot: catalog(Screenshot).map(tool => {
      id: Builtin(tool),
      enabled: true,
    }),
    recording: [],
    video_editing: [],
  }
}

///|
priv enum Command {
  SetEnabled(ToolId, Bool)
  Move(ToolGroup, ToolId, ToolId?)
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
