///|
test "typed native image sessions preserve reducer history and Unicode text" {
  let id = image_session_create(640, 480)
  assert_true(id > 0)
  assert_eq(image_session_add(id, 1, 10, 20, 100, 80, 0xf26769, 3), 1)
  assert_eq(image_session_add(id, 2, 150, 100, -100, -50, 0, 3), 1)
  assert_eq(image_session_set_text(id, "月兔 ✂️"), 1)
  assert_eq(image_session_add(id, 3, 20, 30, 180, 40, 0xffffff, 3), 1)
  assert_eq(image_session_count(id), 3)
  assert_eq(image_session_value(id, 0, 5), (0xf26769).to_double())
  assert_eq(image_session_value(id, 1, 3), -100)
  assert_eq(image_session_text(id, 2), "月兔 ✂️")
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 2)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_text(id, 2), "月兔 ✂️")
  assert_eq(image_session_add(id, 4, 0, 0, -1, 20, 0, 3), 0)
  assert_eq(image_session_count(id), 3)
  image_session_dispose(id)
  assert_eq(image_session_add(id, 1, 0, 0, 20, 20, 0, 3), 0)
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_create(0, 480), 0)
}

///|
test "native inline text commits style and Unicode as one undoable edit" {
  let id = image_session_create(640, 480)
  assert_eq(image_session_set_text(id, "第一行\n月兔 ✂️"), 1)
  assert_eq(image_session_add_styled(id, 3, 20, 30, 180, 80, 0xffffff, 3, 36), 1)
  assert_eq(image_session_value(id, 0, 7), 36)
  assert_eq(image_session_set_text(id, "拖拽后\n你好 🌙"), 1)
  assert_eq(image_session_update(id, 0, 40, 50, 240, 120, 0xf26769, 4, 48), 1)
  assert_eq(image_session_text(id, 0), "拖拽后\n你好 🌙")
  assert_eq(image_session_value(id, 0, 1), 40)
  assert_eq(image_session_value(id, 0, 3), 240)
  assert_eq(image_session_value(id, 0, 5), (0xf26769).to_double())
  assert_eq(image_session_value(id, 0, 7), 48)
  // Re-selecting and committing the same text is not another edit.
  assert_eq(image_session_update(id, 0, 40, 50, 240, 120, 0xf26769, 4, 48), 1)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_text(id, 0), "第一行\n月兔 ✂️")
  assert_eq(image_session_value(id, 0, 1), 20)
  assert_eq(image_session_value(id, 0, 3), 180)
  assert_eq(image_session_value(id, 0, 5), (0xffffff).to_double())
  assert_eq(image_session_value(id, 0, 7), 36)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_text(id, 0), "拖拽后\n你好 🌙")
  assert_eq(image_session_remove(id, 0), 1)
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_text(id, 0), "拖拽后\n你好 🌙")
  assert_eq(image_session_value(id, 0, 7), 48)
  image_session_dispose(id)
}

///|
test "native annotation update rejects invalid input without changing history" {
  let id = image_session_create(640, 480)
  assert_eq(image_session_set_text(id, "待编辑"), 1)
  assert_eq(image_session_add_styled(id, 3, 10, 20, 100, 40, 0, 3, 24), 1)
  assert_eq(image_session_update(id, 0, 11, 20, 100, 40, 0, 3, 7), 0)
  assert_eq(image_session_update(id, 0, 11, 20, 100, 40, 0, 3, 129), 0)
  assert_eq(image_session_update(id, 0, 11, 20, 0, 40, 0, 3, 24), 0)
  assert_eq(image_session_update(id, 0, 11, 20, 100, 40, 0x1000000, 3, 24), 0)
  assert_eq(image_session_update(id, -1, 11, 20, 100, 40, 0, 3, 24), 0)
  assert_eq(image_session_remove(id, 1), 0)
  assert_eq(image_session_value(id, 0, 1), 10)
  assert_eq(image_session_value(id, 0, 7), 24)
  // Failed validation cannot turn into an extra undo step.
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_count(id), 1)
  // A styled add is also atomic; undo removes it, not only its style.
  assert_eq(image_session_add_styled(id, 3, 20, 30, 100, 50, 0, 3, 128), 1)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 1)
  image_session_dispose(id)
}

///|
test "native viewport baseline and resize share annotation undo history" {
  let id = image_session_create_viewport(1200, 800, 100, 80, 400, 300)
  assert_true(id > 0)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_viewport_value(id, 0), 100)
  assert_eq(image_session_viewport_value(id, 1), 80)
  assert_eq(image_session_viewport_value(id, 2), 400)
  assert_eq(image_session_viewport_value(id, 3), 300)
  assert_eq(image_session_add(id, 2, 200, 160, -50, -40, 0, 3), 1)
  assert_eq(image_session_update(id, 0, 220, 180, -70, -60, 0, 3, 24), 1)
  let annotation = native_image_annotation(id, 0).unwrap()
  assert_eq(image_number(annotation, "x2", 0), 150)
  assert_eq(image_number(annotation, "y2", 0), 120)
  assert_eq(image_session_crop(id, 110, 90, 350, 250), 1)
  assert_eq(image_session_viewport_value(id, 2), 350)
  // Invalid or unchanged regions cannot consume undo or translate annotations.
  assert_eq(image_session_crop(id, 110, 90, 350, 250), 1)
  assert_eq(image_session_crop(id, 110, 90, 1200, 250), 0)
  assert_eq(image_session_value(id, 0, 1), 220)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_viewport_value(id, 2), 400)
  assert_eq(image_session_value(id, 0, 1), 220)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_value(id, 0, 1), 200)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_value(id, 0, 1), 220)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_viewport_value(id, 2), 350)
  image_session_dispose(id)
  assert_eq(image_session_create_viewport(1200, 800, -1, 80, 400, 300), 0)
  assert_eq(image_session_create_viewport(1200, 800, 100, 80, 1101, 300), 0)
  assert_eq(image_session_crop(id, 0, 0, 20, 20), 0)
  assert_eq(image_session_viewport_value(id, 0), 0)
}

///|
test "native RGBA cover edits preserve opacity across history and legacy geometry updates" {
  let id = image_session_create(640, 480)
  assert_eq(image_session_add_rgba(id, 4, 10, 20, 100, 80, 0x225577, 4, 24, 0.35), 1)
  assert_eq(image_session_value(id, 0, 5), (0x225577).to_double())
  assert_eq(image_session_value(id, 0, 8), 0.35)
  // Older hosts can move a translucent object without turning it opaque.
  assert_eq(image_session_update(id, 0, 30, 40, 120, 90, 0xf26769, 4, 24), 1)
  assert_eq(image_session_value(id, 0, 8), 0.35)
  assert_eq(image_session_update_rgba(id, 0, 30, 40, 120, 90, 0xf26769, 4, 24, 0.35), 1)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_value(id, 0, 1), 10)
  assert_eq(image_session_value(id, 0, 5), (0x225577).to_double())
  assert_eq(image_session_value(id, 0, 8), 0.35)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_value(id, 0, 1), 30)
  // Opacity alone is an undoable style edit, including a fully clear cover.
  assert_eq(image_session_update_rgba(id, 0, 30, 40, 120, 90, 0xf26769, 4, 24, 0), 1)
  assert_eq(image_session_value(id, 0, 8), 0)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_value(id, 0, 8), 0.35)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_value(id, 0, 8), 0)
  image_session_dispose(id)
}

///|
test "native RGBA text changes commit content and alpha together" {
  let id = image_session_create(640, 480)
  assert_eq(image_session_set_text(id, "月亮 🌙\n第一行"), 1)
  assert_eq(image_session_add_rgba(id, 3, 10, 20, 200, 80, 0xffffff, 3, 24, 0.5), 1)
  assert_eq(image_session_set_text(id, "半透明文字 ✂️"), 1)
  assert_eq(image_session_update_rgba(id, 0, 20, 30, 220, 90, 0x225577, 4, 32, 0.75), 1)
  assert_eq(image_session_text(id, 0), "半透明文字 ✂️")
  assert_eq(image_session_value(id, 0, 8), 0.75)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_text(id, 0), "月亮 🌙\n第一行")
  assert_eq(image_session_value(id, 0, 7), 24)
  assert_eq(image_session_value(id, 0, 8), 0.5)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_text(id, 0), "半透明文字 ✂️")
  assert_eq(image_session_value(id, 0, 8), 0.75)
  image_session_dispose(id)
}

///|
test "native RGBA rejects nonfinite and out of range alpha without history changes" {
  let id = image_session_create(640, 480)
  let invalid : Array[Double] = [-0.01, 1.01, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0]
  for opacity in invalid {
    assert_eq(image_session_add_rgba(id, 1, 10, 20, 100, 80, 0, 4, 24, opacity), 0)
  }
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_add_rgba(id, 2, 50, 60, -20, 30, 0, 4, 24, 0), 1)
  assert_eq(image_session_value(id, 0, 8), 0)
  for opacity in invalid {
    assert_eq(image_session_update_rgba(id, 0, 60, 70, -20, 30, 0, 4, 24, opacity), 0)
  }
  assert_eq(image_session_value(id, 0, 1), 50)
  assert_eq(image_session_undo(id), 1)
  assert_eq(image_session_count(id), 0)
  assert_eq(image_session_redo(id), 1)
  assert_eq(image_session_value(id, 0, 8), 0)
  assert_eq(image_session_add_styled(id, 1, 10, 20, 100, 80, 0, 4, 24), 1)
  assert_eq(image_session_value(id, 1, 8), 1)
  image_session_dispose(id)
  assert_eq(image_session_value(id, 0, 8), 0)
}
