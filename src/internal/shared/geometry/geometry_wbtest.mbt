///|
fn expect_values(actual : FixedArray[Double], expected : Array[Double]) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for index in 0..<expected.length() { assert_eq(actual[index], expected[index]) }
}

///|
test "reverse drags normalize without rounding or clamping host coordinates" {
  expect_values(region(250, 160, 40, 30), [40, 30, 210, 130])
  expect_values(region(10.75, -2.25, -3.5, 4.5), [-3.5, -2.25, 14.25, 6.75])
  expect_values(region(10, 20, 10, 20), [10, 20, 0, 0])
}

///|
test "handle positions run clockwise and invalid handles have no position" {
  let expected : Array[Array[Double]] = [
    [40, 30], [80, 30], [120, 30], [120, 60],
    [120, 90], [80, 90], [40, 90], [40, 60],
  ]
  for handle in 0..<8 {
    expect_values(handle_point(40, 30, 80, 60, handle, 0), expected[handle])
    assert_eq(hit_handle(40, 30, 80, 60, expected[handle][0], expected[handle][1], 2, 0), handle)
  }
  expect_values(handle_point(40, 30, 80, 60, -1, 0), [0, 0])
  expect_values(handle_point(40, 30, 80, 60, 8, 0), [0, 0])
}

///|
test "Windows truncates the final odd midpoint toward zero including negative origins" {
  expect_values(handle_point(-5, -7, 3, 5, 1, 0), [-3.5, -7])
  expect_values(handle_point(-5, -7, 3, 5, 1, 1), [-3, -7])
  expect_values(handle_point(-5, -7, 3, 5, 3, 1), [-2, -4])
  expect_values(handle_point(-5, -7, 3, 5, 5, 1), [-3, -2])
  expect_values(handle_point(-5, -7, 3, 5, 7, 1), [-5, -4])
  expect_values(handle_point(2, 3, 3, 5, 1, 1), [3, 3])
  // A subpixel hit makes the midpoint adaptation observable without changing
  // the shared half-open hit boundary.
  assert_eq(hit_handle(-5, -7, 3, 5, -3, -7, 0.25, 1), 1)
  assert_eq(hit_handle(-5, -7, 3, 5, -3, -7, 0.25, 0), -1)
}

///|
test "handle hits use the macOS half-open edges and first-handle priority" {
  for midpoint_mode in [0, 1] {
    assert_eq(hit_handle(0, 0, 100, 100, -6, 0, 6, midpoint_mode), 0)
    assert_eq(hit_handle(0, 0, 100, 100, 0, -6, 6, midpoint_mode), 0)
    assert_eq(hit_handle(0, 0, 100, 100, 6, 0, 6, midpoint_mode), -1)
    assert_eq(hit_handle(0, 0, 100, 100, 0, 6, 6, midpoint_mode), -1)
    assert_eq(hit_handle(0, 0, 100, 100, 50, 50, 6, midpoint_mode), -1)
    assert_eq(hit_handle(0, 0, 4, 4, 2, 2, 6, midpoint_mode), 0)
    assert_eq(hit_handle(0, 0, 100, 100, 0, 0, -1, midpoint_mode), -1)
    assert_eq(hit_handle(0, 0, 100, 100, 0, 0, 0, midpoint_mode), -1)
  }
}

///|
test "directed rectangle containment includes edges while the border keeps AppKit edges" {
  assert_eq(contains(30, 40, -20, -30, 10, 10), 1)
  assert_eq(contains(30, 40, -20, -30, 30, 40), 1)
  assert_eq(contains(30, 40, -20, -30, 9, 20), 0)
  assert_eq(contains(10, 10, 0, 20, 10, 20), 1)
  assert_eq(border_contains(10, 10, 20, 20, 5, 20, 5), 1)
  assert_eq(border_contains(10, 10, 20, 20, 35, 20, 5), 0)
  assert_eq(border_contains(10, 10, 20, 20, 15, 20, 5), 0)
  assert_eq(border_contains(10, 10, 20, 20, 25, 20, 5), 1)
  assert_eq(border_contains(10, 10, 20, 20, 20, 20, 5), 0)
  // A collapsed or negative inset has no interior to subtract.
  assert_eq(border_contains(10, 10, 4, 4, 12, 12, 2), 1)
  assert_eq(border_contains(10, 10, 4, 4, 12, 12, 3), 1)
  assert_eq(border_contains(10, 10, 20, 20, 10, 20, 0), 0)
}

///|
test "all eight resize handles follow the macOS fixed-edge geometry" {
  let expected : Array[Array[Double]] = [
    [50, 35, 70, 55], [40, 35, 80, 55], [40, 35, 90, 55], [40, 30, 90, 60],
    [40, 30, 90, 65], [40, 30, 80, 65], [50, 30, 70, 65], [50, 30, 70, 60],
  ]
  for handle in 0..<8 {
    expect_values(transform(40, 30, 80, 60, 70, 45, 80, 50, handle,
      20, 10, 300, 190, 2), expected[handle])
  }
  expect_values(transform(40, 30, 80, 60, 0, 0, 1000, 1000, 8,
    20, 10, 300, 190, 2), [40, 30, 80, 60])
}

///|
test "minimum edges stop crossing and nonzero bounds constrain movement and growth" {
  expect_values(transform(40, 30, 80, 60, 40, 30, 300, 190, 0,
    20, 10, 300, 190, 2), [118, 88, 2, 2])
  expect_values(transform(40, 30, 80, 60, 40, 30, 300, 190, 0,
    20, 10, 300, 190, 8), [112, 82, 8, 8])
  expect_values(transform(40, 30, 80, 60, 0, 0, -100, -100, -1,
    20, 10, 300, 190, 8), [20, 10, 80, 60])
  expect_values(transform(40, 30, 80, 60, 0, 0, 1000, 1000, -1,
    20, 10, 300, 190, 8), [240, 140, 80, 60])
  expect_values(transform(40, 30, 80, 60, 0, 0, 1000, 1000, 4,
    20, 10, 300, 190, 8), [40, 30, 280, 170])
  // Transform does not clamp the pointer again; hosts define pointer conversion.
  expect_values(transform(40, 30, 80, 60, 5, 5, -100, -100, -1,
    0, 0, 320, 200, 2), [0, 0, 80, 60])
}

///|
test "small regions keep the macOS clamp ordering when the minimum exceeds available space" {
  // A region may be smaller than an annotation's requested minimum. Leading
  // edges use min(high,max(low,value)); trailing edges use max(low,min(value,high)).
  for delta in [-20.0, 0.0, 20.0] {
    expect_values(transform(10, 20, 4, 4, 0, 0, delta, delta, 0,
      10, 20, 5, 5, 8), [6, 16, 8, 8])
    expect_values(transform(10, 20, 4, 4, 0, 0, delta, delta, 4,
      10, 20, 5, 5, 8), [10, 20, 8, 8])
  }
  // Moving an oversized rectangle retains the leading bound, matching macOS.
  expect_values(transform(10, 20, 20, 20, 0, 0, 0, 0, -1,
    10, 20, 10, 10, 8), [10, 20, 20, 20])
}

///|
test "directed arrow movement preserves endpoint order inside nonzero bounds" {
  expect_values(transform(350, 250, -320, -200, 200, 100, -200, -200, -1,
    20, 30, 640, 400, 8, directed=true), [340, 230, -320, -200])
  expect_values(transform(350, 250, -320, -200, 0, 0, 1000, 1000, -1,
    20, 30, 640, 400, 8, directed=true), [660, 430, -320, -200])
  expect_values(transform(100, 250, 80, -200, 0, 0, -1000, -1000, -2,
    20, 30, 640, 400, 8, directed=true), [20, 230, 80, -200])
}

///|
test "negative rectangles retain macOS movement unless directed endpoints are requested" {
  // The raw macOS rectangle keeps its original arithmetic; the same values
  // representing an arrow instead constrain both endpoints explicitly.
  expect_values(transform(100, 90, -40, -30, 0, 0, 640, 400, -2,
    0, 0, 640, 400, 2), [680, 430, -40, -30])
  expect_values(transform(100, 90, -40, -30, 0, 0, 640, 400, -2,
    0, 0, 640, 400, 2, directed=true), [640, 400, -40, -30])
  expect_values(transform(100, 90, -40, -30, 0, 0, -1000, -1000, -2,
    0, 0, 640, 400, 2), [0, 0, -40, -30])
  expect_values(transform(100, 90, -40, -30, 0, 0, -1000, -1000, -2,
    0, 0, 640, 400, 2, directed=true), [40, 30, -40, -30])
}

///|
test "fractional handle edges retain native rectangle arithmetic" {
  let center = 9.0 / 37.0
  let native_maximum = (center - 4) + 8
  // Foundation includes this point: center + 4 rounds below the native edge.
  assert_eq(hit_handle(center, 20, 100, 60, center + 4, 20, 4, 0), 0)
  assert_eq(hit_handle(center, 20, 100, 60, native_maximum, 20, 4, 0), -1)
}
