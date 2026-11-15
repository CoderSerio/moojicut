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
