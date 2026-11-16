///|
test "editor tool capabilities expose the shared style domains" {
  assert_eq(editor_style_property_mask(0), 0)
  assert_eq(editor_style_property_mask(1), 23)
  assert_eq(editor_style_property_mask(2), 7)
  assert_eq(editor_style_property_mask(3), 11)
  assert_eq(editor_style_property_mask(4), 51)
  assert_eq(editor_style_property_mask(-1), 0)
  assert_eq(editor_style_property_mask(5), 0)
  let domains : Array[(Double, Double, Double, Double)] = [
    (0, 16777215, 1, (0xf26769).to_double()),
    (0, 1, 0.01, 1),
    (1, 96, 1, 4),
    (8, 128, 1, 32),
  ]
  for property in 0..<4 {
    let (minimum, maximum, step, initial) = domains[property]
    assert_eq(editor_style_min(property), minimum)
    assert_eq(editor_style_max(property), maximum)
    assert_eq(editor_style_step(property), step)
    assert_eq(editor_style_default(property), initial)
  }
  for property in [-1, 6, 2147483647] {
    assert_eq(editor_style_min(property), 0)
    assert_eq(editor_style_max(property), 0)
    assert_eq(editor_style_step(property), 0)
    assert_eq(editor_style_default(property), 0)
  }
}

///|
test "editor styles are isolated per tool and per editor" {
  let first = editor_style_create()
  let second = editor_style_create()
  assert_true(first > 0 && second > 0 && first != second)
  for tool in 0..<5 {
    assert_eq(editor_style_get(first, tool, 0), if tool == 4 { (0x111111).to_double() } else { editor_style_default(0) })
    assert_eq(editor_style_get(first, tool, 1), 1)
    assert_eq(editor_style_get(first, tool, 2), 4)
    assert_eq(editor_style_get(first, tool, 3), 32)
  }
  assert_eq(editor_style_set(first, 1, 0, 0x225577), 1)
  assert_eq(editor_style_set(first, 1, 1, 0.35), 1)
  assert_eq(editor_style_set(first, 1, 2, 12), 1)
  assert_eq(editor_style_set(first, 3, 3, 48), 1)
  assert_eq(editor_style_get(first, 1, 0), (0x225577).to_double())
  assert_eq(editor_style_get(first, 1, 1), 0.35)
  assert_eq(editor_style_get(first, 1, 2), 12)
  assert_eq(editor_style_get(first, 2, 0), editor_style_default(0))
  assert_eq(editor_style_get(first, 2, 1), 1)
  assert_eq(editor_style_get(first, 2, 2), 4)
  assert_eq(editor_style_get(first, 3, 3), 48)
  assert_eq(editor_style_get(second, 1, 0), editor_style_default(0))
  assert_eq(editor_style_get(second, 1, 1), 1)
  assert_eq(editor_style_get(second, 1, 2), 4)
  assert_eq(editor_style_get(second, 3, 3), 32)
  // Complete reads include defaults for fields that this tool cannot change.
  assert_eq(editor_style_set(first, 1, 3, 24), 0)
  assert_eq(editor_style_set(first, 3, 2, 8), 0)
  assert_eq(editor_style_set(first, 4, 2, 8), 0)
  assert_eq(editor_style_set(first, 4, 3, 24), 0)
  assert_eq(editor_style_get(first, 1, 3), 32)
  assert_eq(editor_style_get(first, 3, 2), 4)
  assert_eq(editor_style_get(first, 4, 2), 4)
  assert_eq(editor_style_set(first, 4, 0, 0xffffff), 1)
  assert_eq(editor_style_get(second, 4, 0), (0x111111).to_double())
  for property in 0..<4 {
    assert_eq(editor_style_set(first, 0, property, editor_style_min(property)), 0)
    assert_eq(editor_style_get(first, 0, property), editor_style_default(property))
  }
  editor_style_dispose(first)
  editor_style_dispose(second)
}

///|
test "editor style updates reject invalid numbers atomically and allow domain boundaries" {
  let handle = editor_style_create()
  let tools = [1, 1, 1, 3]
  for property in 0..<4 {
    let tool = tools[property]
    let original = editor_style_get(handle, tool, property)
    for value in [editor_style_min(property) - 0.1, editor_style_max(property) + 0.1,
                  0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0] {
      assert_eq(editor_style_set(handle, tool, property, value), 0)
      assert_eq(editor_style_get(handle, tool, property), original)
    }
    assert_eq(editor_style_set(handle, tool, property, editor_style_min(property)), 1)
    assert_eq(editor_style_get(handle, tool, property), editor_style_min(property))
    assert_eq(editor_style_set(handle, tool, property, editor_style_max(property)), 1)
    assert_eq(editor_style_get(handle, tool, property), editor_style_max(property))
  }
  assert_eq(editor_style_set(handle, 1, 0, 65535.5), 0)
  assert_eq(editor_style_get(handle, 1, 0), 16777215)
  // A UI step must not turn into a new restriction on existing document values.
  assert_eq(editor_style_set(handle, 1, 1, 0.123), 1)
  assert_eq(editor_style_set(handle, 1, 2, 2.5), 1)
  assert_eq(editor_style_set(handle, 3, 3, 31.25), 1)
  assert_eq(editor_style_get(handle, 1, 1), 0.123)
  assert_eq(editor_style_get(handle, 1, 2), 2.5)
  assert_eq(editor_style_get(handle, 3, 3), 31.25)
  editor_style_dispose(handle)
}

///|
test "disposed and invalid style handles cannot access another editor" {
  let old = editor_style_create()
  editor_style_dispose(old)
  editor_style_dispose(old)
  editor_style_dispose(0)
  let current = editor_style_create()
  assert_true(current != old)
  for handle in [old, 0, -1] {
    assert_eq(editor_style_get(handle, 1, 0), 0)
    assert_eq(editor_style_set(handle, 1, 0, 0), 0)
  }
  for tool in [-1, 5, 2147483647] {
    assert_eq(editor_style_get(current, tool, 0), 0)
    assert_eq(editor_style_set(current, tool, 0, 0), 0)
  }
  for property in [-1, 6, 2147483647] {
    assert_eq(editor_style_get(current, 1, property), 0)
    assert_eq(editor_style_set(current, 1, property, 0), 0)
  }
  assert_eq(editor_style_get(current, 1, 0), editor_style_default(0))
  editor_style_dispose(current)
}
