///|
test "desktop shortcuts protect typing and reject conflicts across actions" {
  assert_eq(shortcut_validate(49, 5, 50, 5, 88, 5), 0)
  assert_eq(shortcut_validate(49, 5, 49, 5, 88, 5), 2)
  assert_eq(shortcut_validate(88, 5, 49, 5, 88, 5), 2)
  assert_eq(shortcut_validate(49, 1, 49, 5, 88, 5), 0)
  for modifier in [0, 4] {
    assert_eq(shortcut_validate(65, modifier, 0, 0, 0, 0), 1)
  }
  assert_eq(shortcut_validate(0, 0, 0, 0, 0, 0), 0)
  assert_eq(shortcut_validate(0, 1, 0, 0, 0, 0), 3)
  for key in [256, 279] {
    assert_eq(shortcut_validate(key, 0, 0, 0, 0, 0), 0)
  }
  for key in [-1, 47, 58, 97, 255, 280] {
    assert_eq(shortcut_validate(key, 1, 0, 0, 0, 0), 3)
  }
  for modifier in [-1, 16] {
    assert_eq(shortcut_validate(65, modifier, 0, 0, 0, 0), 3)
  }
}

///|
test "native preview health check exercises image and video core" {
  assert_eq(preview_core_check(), 1)
}
