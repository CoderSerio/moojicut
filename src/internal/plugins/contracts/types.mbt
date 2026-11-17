///|
pub struct UserTool {
  priv plugin_id : String
  priv local_id : String
  priv title : String
}

///|
pub fn UserTool::global_id(self : UserTool) -> String {
  "user." + self.plugin_id + "/" + self.local_id
}

///|
pub fn UserTool::plugin_id(self : UserTool) -> String {
  self.plugin_id
}

///|
pub fn UserTool::tool_id(self : UserTool) -> String {
  self.local_id
}

///|
pub fn UserTool::title(self : UserTool) -> String {
  self.title
}

///|
pub struct Manifest {
  priv plugin_id : String
  priv name : String
  priv version : String
  priv tools : Array[UserTool]
}

///|
pub fn Manifest::plugin_id(self : Manifest) -> String {
  self.plugin_id
}

///|
pub fn Manifest::tools(self : Manifest) -> Array[UserTool] {
  self.tools.copy()
}

///|
priv struct CaptureMetadata {
  width : Int32
  height : Int32
  revision : Double
}

///|
priv struct InvocationRequest {
  invocation_id : String
  tool : UserTool
  capture : CaptureMetadata
}

///|
priv struct TextResult {
  invocation_id : String
  title : String
  text : String
}
