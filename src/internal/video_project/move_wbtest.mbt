///|
test "absolute move preserves gaps linked audio source ranges and one undo" {
  let id = test_session(12000)
  ignore(split_at(id, "v1", 360000))
  let before = clip(id, "v2")
  ignore(edit(id, { "type": "move", "clipId": "v2", "startTicks": 540000 }))
  assert_eq(clip(id, "v1")["startTicks"], Json(0))
  assert_eq(clip(id, "v2")["startTicks"], Json(540000))
  assert_eq(clip(id, "a2")["startTicks"], Json(540000))
  for
    key in ["sourceStartTicks", "sourceEndTicks", "durationTicks", "linkGroup"] {
    assert_eq(clip(id, "v2")[key], before[key])
  }
  assert_eq(duration(id), 1260000)
  // The plan contains only actual clips: neither video nor audio covers gap.
  let plan = @protocol.object_field(current(id), "plan")
  for track in ["video", "audio"] {
    match plan[track] {
      Array(values) =>
        for value in values {
          let c = object(value)
          let start = integer(c, "startTicks", 0, max_ticks)
          let span = integer(c, "durationTicks", 0, max_ticks)
          assert_true(start >= 540000 || start + span <= 360000)
        }
      _ => abort("missing track")
    }
  }
  ignore(edit(id, { "type": "undo" }))
  assert_eq(clip(id, "v2"), before)
  assert_eq(clip(id, "a2")["startTicks"], Json(360000))
  assert_eq(duration(id), 1080000)
  close(id)
}

///|
test "absolute move rejects overlap atomically and leaves detached audio alone" {
  let id = test_session(12000)
  ignore(split_at(id, "v1", 360000))
  expect_failure(
    id,
    { "type": "move", "clipId": "v2", "startTicks": 180000 },
    "overlap",
  )
  expect_failure(
    id,
    {
      "type": "move",
      "clipId": "v2",
      "startTicks": 540000,
      "beforeClipId": Json::null(),
    },
    "invalid_input",
  )
  expect_failure(
    id,
    { "type": "move", "clipId": "v2", "startTicks": -1 },
    "invalid_input",
  )
  expect_failure(
    id,
    { "type": "move", "clipId": "v2", "startTicks": 54432000000 },
    "invalid_input",
  )
  ignore(simple(id, "unlink", "v2"))
  ignore(edit(id, { "type": "move", "clipId": "v2", "startTicks": 540000 }))
  assert_eq(clip(id, "a2")["startTicks"], Json(360000))
  // An independent soundtrack crossing a video gap must not be silenced or
  // silently deleted by closing that gap.
  expect_failure(
    id,
    { "type": "removeGap", "startTicks": 360000, "endTicks": 540000 },
    "ambiguous_ripple",
  )
  ignore(edit(id, { "type": "move", "clipId": "a2", "startTicks": 540001 }))
  assert_eq(clip(id, "a2")["startTicks"], Json(540000))
  ignore(
    edit(id, { "type": "removeGap", "startTicks": 360000, "endTicks": 540000 }),
  )
  assert_eq(clip(id, "v2")["startTicks"], Json(360000))
  assert_eq(clip(id, "a2")["startTicks"], Json(360000))
  close(id)
}
