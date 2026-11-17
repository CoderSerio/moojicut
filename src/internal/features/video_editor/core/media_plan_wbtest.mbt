///|
test "media plan stays immutable through gap edits undo and project close" {
  let id = test_session(12000)
  ignore(split_at(id, "v1", 360000))
  let before = media_plan_open(id)
  assert_true(before > 0)
  ignore(edit(id, { "type": "move", "clipId": "v2", "startTicks": 540000 }))
  let gap = media_plan_open(id)
  assert_true(gap > before)
  assert_eq(media_plan_number(before, 0), 1080000)
  assert_eq(media_plan_number(gap, 0), 1260000)
  for kind in [0, 1] {
    assert_eq(media_plan_clip_number(before, kind, 1, 0), 360000)
    assert_eq(media_plan_clip_number(gap, kind, 1, 0), 540000)
    assert_eq(media_plan_clip_number(gap, kind, 1, 1), 360000)
    assert_eq(media_plan_clip_number(gap, kind, 1, 2), 1080000)
    assert_eq(media_plan_clip_number(gap, kind, 1, 3), 720000)
  }
  ignore(edit(id, { "type": "undo" }))
  close(id)
  assert_eq(media_plan_number(gap, 0), 1260000)
  assert_eq(media_plan_open(id), 0)
  media_plan_close(before)
  media_plan_close(gap)
  media_plan_close(gap)
  assert_eq(media_plan_value(gap, 0), -1)
  assert_eq(media_plan_clip_number(gap, 0, 0, 0), -1)
}

///|
test "media plan projects crop and independent muted tail without invented audio" {
  let id = test_session(4000)
  ignore(simple(id, "unlink", "v1"))
  ignore(edit(id, { "type": "move", "clipId": "a1", "startTicks": 180000 }))
  ignore(edit(id, { "type": "mute", "muted": true }))
  ignore(edit(id, { "type": "crop", "crop": { "x": 10, "y": 20, "width": 500, "height": 300 } }))
  let plan = media_plan_open(id)
  assert_eq(media_plan_value(plan, 0), 1920)
  assert_eq(media_plan_value(plan, 1), 1080)
  assert_eq(media_plan_value(plan, 2), 1)
  assert_eq(media_plan_value(plan, 3), 0)
  assert_eq(media_plan_value(plan, 5), 1)
  assert_eq(media_plan_number(plan, 0), 540000)
  assert_eq(media_plan_number(plan, 1), 4000)
  assert_eq(media_plan_number(plan, 2), 10)
  assert_eq(media_plan_number(plan, 3), 20)
  assert_eq(media_plan_number(plan, 4), 500)
  assert_eq(media_plan_number(plan, 5), 300)
  assert_eq(media_plan_clip_number(plan, 1, 0, 0), -1)
  assert_eq(media_plan_clip_number(plan, 2, 0, 0), -1)
  media_plan_close(plan)
  close(id)
}

///|
test "media plan capacity rejects allocation without recycling a live identity" {
  let id = test_session(4000)
  let handles : Array[Int] = []
  for _ in 0..<64 { handles.push(media_plan_open(id)) }
  assert_true(handles.all(h => h > 0))
  assert_eq(media_plan_open(id), 0)
  media_plan_close(handles[0])
  let replacement = media_plan_open(id)
  assert_true(replacement > handles[63])
  assert_eq(media_plan_number(handles[0], 0), -1)
  for h in handles { media_plan_close(h) }
  media_plan_close(replacement)
  close(id)
}
