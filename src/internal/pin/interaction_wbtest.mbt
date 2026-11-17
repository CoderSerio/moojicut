///|
test "fine wheel deltas compose and reverse without losing precision" {
  let quarter = scroll_scale(1, 0.25)
  assert_true(quarter > 1 && quarter < 1.1)
  near(scroll_scale(scroll_scale(scroll_scale(quarter, 0.25), 0.25), 0.25), 1.1)
  near(scroll_scale(quarter, -0.25), 1)
  near(scroll_scale(1, 0), 1)
  near(scroll_scale(1, 0.0 / 0.0), 0)
}

///|
test "edge hits leave a movable center even on small pins" {
  assert_eq(hit_handle(240, 160, 120, 80, 6), 0)
  assert_eq(hit_handle(240, 160, 2, 2, 6), 5)
  assert_eq(hit_handle(240, 160, 239, 159, 6), 10)
  assert_eq(hit_handle(240, 160, 120, 159, 6), 8)
  assert_eq(hit_handle(12, 8, 6, 4, 6), 0)
  assert_eq(hit_handle(240, 160, -1, 2, 6), 0)
}

///|
test "edge resize keeps aspect and opposite anchors on all platforms" {
  for platform in [1, 2, 3] {
    let right = resize_frame(
      platform, -600, 100, 240, 160, 1, 2, 60, 99, -1000, 0, 2000, 1000,
    )
    near(right[0], -600)
    near(right[1], 80)
    near(right[2], 300)
    near(right[3], 200)
    let corner = resize_frame(
      platform, -600, 100, 240, 160, 1, 5, -60, -40, -1000, 0, 2000, 1000,
    )
    near(corner[0] + corner[2], -360)
    near(corner[1] + corner[3], 260)
    near(corner[4], 1.25)
    let crossed = resize_frame(
      platform, 100, 100, 240, 160, 1, 10, -1000, -1000, 0, 0, 2000, 1000,
    )
    near(crossed[4], 0.1)
    near(crossed[2] / crossed[3], 1.5)
    let limited = resize_frame(
      platform, 100, 100, 240, 160, 1, 10, 10000, 10000, 0, 0, 1000, 600,
    )
    assert_true(
      limited[0] >= 0 &&
      limited[1] >= 0 &&
      limited[0] + limited[2] <= 1000 &&
      limited[1] + limited[3] <= 600,
    )
    near(limited[2] / limited[3], 1.5)
  }
  near(resize_frame(1, 0, 0, 240, 160, 1, 0, 5, 5, 0, 0, 1000, 1000)[4], 0)
  near(resize_frame(1, 0, 0, 240, 160, 1, 3, 5, 5, 0, 0, 1000, 1000)[4], 0)
  near(
    resize_frame(1, 0, 0, 240, 160, 1, 2, 1.0 / 0.0, 0, 0, 0, 1000, 1000)[4],
    0,
  )
}
