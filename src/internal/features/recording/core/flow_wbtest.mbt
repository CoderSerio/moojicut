///|
test "countdown uses monotonic elapsed time and starts the backend only once" {
  let id = recording_flow_open()
  assert_true(id > 0)
  assert_eq(recording_flow_event(id, 1, 100), 1)
  assert_eq(recording_flow_event(id, 2, 500), 0)
  assert_eq(recording_flow_value(id, 1), 3)
  assert_eq(recording_flow_event(id, 3, 1499), 0)
  assert_eq(recording_flow_value(id, 1), 3)
  assert_eq(recording_flow_event(id, 3, 1500), 0)
  assert_eq(recording_flow_value(id, 1), 2)
  assert_eq(recording_flow_event(id, 3, 3499), 0)
  assert_eq(recording_flow_value(id, 1), 1)
  assert_eq(recording_flow_event(id, 3, 3500), 2)
  assert_eq(recording_flow_event(id, 3, 6000), 0)
  assert_eq(recording_flow_event(id, 2, 6000), -1)
  assert_eq(recording_flow_value(id, 0), 3)
  assert_eq(recording_flow_event(id, 4, 6001), 0)
  assert_eq(recording_flow_event(id, 3, 7001), 0)
  assert_eq(recording_flow_value(id, 2), 1000)
  assert_eq(recording_flow_event(id, 6, 7002), -1)
  assert_eq(recording_flow_event(id, 5, 7501), 3)
  assert_eq(recording_flow_close(id), 0)
  assert_eq(recording_flow_event(id, 3, 9500), 0)
  assert_eq(recording_flow_value(id, 2), 1500)
  assert_eq(recording_flow_event(id, 6, 9501), 5)
  assert_eq(recording_flow_event(id, 6, 9502), -1)
  assert_eq(recording_flow_close(id), 1)
}

///|
test "cancel cannot finish before the native source is released" {
  for selected in [false, true] {
    let id = recording_flow_open()
    assert_eq(recording_flow_event(id, 1, 0), 1)
    if selected {
      assert_eq(recording_flow_event(id, 2, 100), 0)
    }
    assert_eq(recording_flow_event(id, 8, 200), 4)
    assert_eq(recording_flow_value(id, 0), 5)
    assert_eq(recording_flow_value(id, 3), 1)
    assert_eq(recording_flow_close(id), 0)
    assert_eq(recording_flow_event(id, 2, 250), -1)
    assert_eq(recording_flow_event(id, 3, 5000), 0)
    assert_eq(recording_flow_event(id, 4, 5000), -1)
    assert_eq(recording_flow_event(id, 6, 5000), 0)
    assert_eq(recording_flow_value(id, 0), 8)
    assert_eq(recording_flow_value(id, 3), 0)
    assert_eq(recording_flow_close(id), 1)
  }
}

///|
test "stop during asynchronous start drains and late callbacks cannot restart it" {
  let id = recording_flow_open()
  assert_eq(recording_flow_event(id, 1, 0), 1)
  assert_eq(recording_flow_event(id, 2, 0), 0)
  assert_eq(recording_flow_event(id, 3, 5000), 2)
  assert_eq(recording_flow_event(id, 5, 5001), 3)
  assert_eq(recording_flow_event(id, 4, 5002), -1)
  assert_eq(recording_flow_event(id, 5, 5003), -1)
  assert_eq(recording_flow_value(id, 0), 5)
  assert_eq(recording_flow_event(id, 7, 5004), 0)
  assert_eq(recording_flow_value(id, 0), 7)
  assert_eq(recording_flow_event(id, 6, 5005), -1)
  assert_eq(recording_flow_close(id), 1)
  let next = recording_flow_open()
  assert_true(next > id)
  assert_eq(recording_flow_event(id, 4, 6000), -1)
  assert_eq(recording_flow_value(next, 0), 0)
  assert_eq(recording_flow_close(next), 1)
}

///|
test "invalid events and clocks do not mutate the live session" {
  let id = recording_flow_open()
  assert_eq(recording_flow_event(id, 1, 100), 1)
  for now in [-1.0, 99.0, 0.0 / 0.0, 1.0 / 0.0, 1.0e16] {
    assert_eq(recording_flow_event(id, 2, now), -1)
    assert_eq(recording_flow_value(id, 0), 1)
  }
  assert_eq(recording_flow_event(id, 999, 1.0e12), -1)
  assert_eq(recording_flow_event(id, 2, 100), 0)
  assert_eq(recording_flow_event(id, 8, 100), 4)
  assert_eq(recording_flow_event(id, 6, 100), 0)
  assert_eq(recording_flow_close(id), 1)
  assert_eq(recording_flow_close(id), 1)
  assert_eq(recording_flow_value(id, 0), -1)
}
