///|
// Platform hosts translate their native key codes into this shared format:
// ASCII A-Z / 0-9, F1-F24 = 256..279, 0 = disabled.
// Modifier bits: Control 1, Alt 2, Shift 4, Super 8.
// Return values: valid 0, missing modifier 1, duplicate 2, unsupported 3.
pub fn shortcut_validate(
  key : Int,
  modifiers : Int,
  other_key : Int,
  other_modifiers : Int,
  second_key : Int,
  second_modifiers : Int,
) -> Int {
  if modifiers < 0 || modifiers > 15 { return 3 }
  if key == 0 { return if modifiers == 0 { 0 } else { 3 } }
  let function_key = key >= 256 && key <= 279
  if !function_key && !(key >= 65 && key <= 90) && !(key >= 48 && key <= 57) {
    return 3
  }
  // Shift alone still produces ordinary text and must not become a global key.
  if !function_key && (modifiers == 0 || modifiers == 4) { return 1 }
  if (key == other_key && modifiers == other_modifiers) ||
    (key == second_key && modifiers == second_modifiers) {
    return 2
  }
  0
}

///|
// Global recovery actions must remain usable after focus moves to another app.
pub fn shortcut_modifiers_allowed(modifiers : Int, global : Int) -> Int {
  if modifiers < 0 || modifiers > 15 || (global != 0 && (modifiers & 11) == 0) {
    0
  } else {
    1
  }
}
