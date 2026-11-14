///|
test "native preview health check exercises image and video core" {
  assert_eq(preview_core_check(), 1)
}
