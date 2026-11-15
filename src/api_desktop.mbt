// Stable native entry point; shortcut policy lives in internal/desktop.

///|
#export_name("shortcut_validate")
pub fn shortcut_validate(
  key : Int,
  modifiers : Int,
  other_key : Int,
  other_modifiers : Int,
  second_key : Int,
  second_modifiers : Int,
) -> Int {
  @desktop.shortcut_validate(key, modifiers, other_key, other_modifiers, second_key, second_modifiers)
}

///|
#export_name("shortcut_modifiers_allowed")
pub fn shortcut_modifiers_allowed(modifiers : Int32, global : Int32) -> Int32 {
  @desktop.shortcut_modifiers_allowed(modifiers, global)
}

///|
#export_name("shortcut_bindings_resolve")
pub fn shortcut_bindings_resolve(request_json : String) -> String {
  @desktop.shortcut_bindings_resolve(request_json)
}
