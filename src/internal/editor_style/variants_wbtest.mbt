///|
test "shape and mosaic defaults are per tool and visibility follows the selected variant" {
  let id = editor_style_create()
  assert_eq(editor_style_set(id, 1, 4, 1), 1)
  assert_eq(editor_style_set(id, 4, 4, 2), 1)
  assert_eq(editor_style_set(id, 4, 5, 24), 1)
  assert_eq(editor_style_get(id, 1, 4), 1)
  assert_eq(editor_style_get(id, 4, 4), 2)
  assert_eq(editor_style_get(id, 4, 5), 24)
  assert_eq(editor_style_set(id, 1, 4, 2), 0)
  assert_eq(editor_style_set(id, 2, 4, 1), 0)
  assert_eq(editor_style_set(id, 4, 5, 4.5), 0)
  assert_eq(editor_style_visible_mask(1, 1), 23)
  assert_eq(editor_style_visible_mask(4, 1), 19)
  assert_eq(editor_style_visible_mask(4, 2), 48)
  editor_style_dispose(id)
}
