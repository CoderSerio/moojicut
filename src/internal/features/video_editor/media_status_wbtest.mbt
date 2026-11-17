///|
test "asynchronous preview failure invalidates pending success and permits a new plan" {
  let id = fixture()
  let plan = take_effect(id)
  assert_eq(effect_kind(id, plan), 1)
  let generation = effect_generation(id, plan)
  let original_document = text(id, 1)
  let original_revision = number(id, 0)
  assert_true(media_failed(id, generation, "decoder failed"))
  assert_true(!media_failed(id, generation, "late failure"))
  assert_true(retry(id))
  // The old in-flight plan may still report success. It must not make the
  // failed generation ready or prevent preparing this same document again.
  assert_true(ack(id, plan, 0, ""))
  assert_eq(value(id, 2), 0)
  finish_effects(id)
  assert_eq(value(id, 2), 1)
  assert_true(value(id, 6) > generation)
  assert_true(!playback(id, generation, 5000, true))
  // Recovery changes generation/readiness, but must never edit the project.
  assert_eq(text(id, 1), original_document)
  assert_eq(number(id, 0), original_revision)
  assert_eq(number(id, 2), original_revision)
  dispose(id)
}

///|
test "preview failure cannot falsely finish an independent export or release its plan" {
  let id = fixture()
  finish_effects(id)
  ignore(node(id, "export"))
  assert_true(activate(id, "export"))
  let chooser = take_effect(id)
  assert_eq(effect_kind(id, chooser), 6)
  assert_true(ack(id, chooser, 0, "/exports/finished.mp4"))
  let job = take_effect(id)
  assert_eq(effect_kind(id, job), 7)
  let plan = effect_plan(id, job)
  assert_true(media_failed(id, value(id, 6), "preview device disconnected"))
  assert_eq(value(id, 3), 1)
  assert_eq(@project.media_plan_number(plan, 0), 1080000)
  assert_true(!release(id))
  assert_true(ack(id, job, 0, ""))
  assert_eq(value(id, 3), 0)
  assert_eq(@project.media_plan_number(plan, 0), -1)
  dispose(id)
}
