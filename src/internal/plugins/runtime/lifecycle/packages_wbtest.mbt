///|
fn fixture_content(version : String) -> PackageContent {
  {
    package_id: "example.capture",
    digest: if version == "1" {
      "1111111111111111111111111111111111111111111111111111111111111111"
    } else {
      "2222222222222222222222222222222222222222222222222222222222222222"
    },
    version,
  }
}

///|
fn fixture_grants() -> Array[ContributionGrant] {
  [
    { id: "user.example.capture/box", effect: "capture.annotations.add", },
    { id: "user.example.capture/info", effect: "result.text", },
  ]
}

///|
fn fixture_install(runtime : Runtime, version : String) -> PackageSnapshot {
  let ticket = runtime
    .prepare_install(
      fixture_content(version),
      runtime.package_generation("example.capture"),
      true,
      fixture_grants(),
    )
    .unwrap()
  ignore(ticket.health_complete(true))
  ignore(ticket.begin_publish())
  ignore(ticket.publish_complete(true))
  runtime.package_snapshot("example.capture").unwrap()
}

///|
fn fixture_configuration(
  runtime : Runtime,
  enabled : Bool,
  grants : Array[ContributionGrant],
) -> PackageSnapshot {
  let ticket = runtime
    .prepare_configuration(
      "example.capture",
      runtime.package_generation("example.capture"),
      enabled,
      grants,
    )
    .unwrap()
  ignore(ticket.begin_publish())
  ignore(ticket.publish_complete(true))
  runtime.package_snapshot("example.capture").unwrap()
}

///|
test "owner snapshots cannot be replayed into a different runtime" {
  let a = Runtime::new()
  let b = Runtime::new()
  let first = fixture_install(a, "1")
  let second = fixture_install(b, "1")
  let owner_a = a.open_owner(1, 0).unwrap()
  let owner_b = b.open_owner(1, 0).unwrap()
  assert_eq(owner_a.generation, owner_b.generation)
  assert_eq(owner_a.session_generation == owner_b.session_generation, false)
  assert_eq(a.owner_current(owner_b), false)
  assert_eq(b.update_owner(owner_a, 1) is None, true)
  assert_eq(b.close_owner(owner_a), false)
  assert_eq(
    b.begin_invocation(
      "example.capture",
      second.generation,
      "user.example.capture/box",
      owner_a,
      "foreign",
    )
    is None,
    true,
  )
  let call = a
    .begin_invocation(
      "example.capture",
      first.generation,
      "user.example.capture/box",
      owner_a,
      "local",
    )
    .unwrap()
  call.cancel()
  assert_eq(call.worker_drained(), true)
  assert_eq(a.quiescent(), true)
  assert_eq(b.owner_current(owner_b), true)
}

///|
test "install health and durable publication are separate barriers and failures preserve the old version" {
  let runtime = Runtime::new()
  let first = runtime
    .prepare_install(fixture_content("1"), 0, true, fixture_grants())
    .unwrap()
  assert_eq(runtime.package_snapshot("example.capture") is None, true)
  assert_eq(first.begin_publish(), false)
  assert_eq(first.publish_complete(true), false)
  assert_eq(first.health_complete(true), true)
  assert_eq(first.health_complete(true), false)
  assert_eq(first.ready(), true)
  assert_eq(first.begin_publish(), true)
  assert_eq(runtime.package_snapshot("example.capture") is None, true)
  assert_eq(first.publish_complete(true), true)
  let installed = runtime.package_snapshot("example.capture").unwrap()
  assert_eq(first.publish_complete(true), false)
  let unhealthy = runtime
    .prepare_install(
      fixture_content("2"),
      installed.generation,
      true,
      fixture_grants(),
    )
    .unwrap()
  assert_eq(unhealthy.health_complete(false), true)
  assert_eq(unhealthy.phase(), Failed)
  assert_eq(unhealthy.begin_publish(), false)
  let unsaved = runtime
    .prepare_install(fixture_content("2"), installed.generation, false, [])
    .unwrap()
  assert_eq(unsaved.health_complete(true), true)
  assert_eq(unsaved.begin_publish(), true)
  assert_eq(
    runtime.prepare_configuration(
      "example.capture",
      installed.generation,
      false,
      [],
    )
    is None,
    true,
  )
  assert_eq(unsaved.publish_complete(false), true)
  assert_eq(runtime.package_snapshot("example.capture"), Some(installed))
  assert_eq(runtime.quiescent(), true)
}

///|
test "concurrent installs recheck CAS and removal keeps a tombstone against absent ABA" {
  let runtime = Runtime::new()
  let a = runtime
    .prepare_install(fixture_content("1"), 0, true, fixture_grants())
    .unwrap()
  let b = runtime
    .prepare_install(fixture_content("2"), 0, true, fixture_grants())
    .unwrap()
  assert_eq(a.health_complete(true), true)
  assert_eq(b.health_complete(true), true)
  assert_eq(b.begin_publish(), true)
  assert_eq(a.begin_publish(), false)
  assert_eq(b.publish_complete(true), true)
  assert_eq(a.ready(), false)
  a.cancel()
  let before = runtime.package_generation("example.capture")
  let remove = runtime.prepare_remove("example.capture", before).unwrap()
  assert_eq(remove.begin_publish(), true)
  assert_eq(remove.publish_complete(true), true)
  assert_eq(runtime.package_snapshot("example.capture") is None, true)
  assert_eq(
    runtime.prepare_install(fixture_content("1"), 0, true, fixture_grants())
    is None,
    true,
  )
  assert_eq(runtime.package_generation("example.capture") > before, true)
  assert_eq(
    runtime.content_in_use("example.capture", fixture_content("2").digest),
    false,
  )
  assert_eq(runtime.quiescent(), true)
}

///|
test "health completion after a different saved configuration is stale and grants are copied" {
  let runtime = Runtime::new()
  let old = fixture_install(runtime, "1")
  let grants = fixture_grants()
  let update = runtime
    .prepare_install(fixture_content("2"), old.generation, true, grants)
    .unwrap()
  grants.clear()
  let current = fixture_configuration(runtime, false, fixture_grants())
  assert_eq(update.health_complete(true), true)
  assert_eq(update.phase(), Failed)
  assert_eq(runtime.package_snapshot("example.capture"), Some(current))
  let fresh_grants = fixture_grants()
  let fresh = runtime
    .prepare_install(
      fixture_content("2"),
      current.generation,
      true,
      fresh_grants,
    )
    .unwrap()
  fresh_grants.clear()
  ignore(fresh.health_complete(true))
  ignore(fresh.begin_publish())
  ignore(fresh.publish_complete(true))
  let owner = runtime.open_owner(1, 0).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      runtime.package_generation("example.capture"),
      "user.example.capture/box",
      owner,
      "copied",
    )
    .unwrap()
  assert_eq(call.allowed_effect(), "capture.annotations.add")
  call.cancel()
  ignore(call.worker_drained())
}

///|
test "result requires real drain and completes once with the granted effect" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(7, 42).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/box",
      owner,
      "request-1",
    )
    .unwrap()
  assert_eq(call.prepare_result("capture.annotations.add") is None, true)
  assert_eq(call.phase(), Running)
  assert_eq(runtime.quiescent(), false)
  assert_eq(call.worker_drained(), true)
  assert_eq(call.worker_drained(), false)
  assert_eq(runtime.quiescent(), false) // parsed/application result is still unresolved
  let result = call.prepare_result("capture.annotations.add").unwrap()
  assert_eq(result.ready(), true)
  assert_eq(call.prepare_result("capture.annotations.add") is None, true)
  assert_eq(result.commit(), true)
  assert_eq(result.commit(), false)
  assert_eq(result.abort(), false)
  assert_eq(runtime.quiescent(), true)
  assert_eq(
    runtime.begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/box",
      owner,
      "request-1",
    )
    is None,
    true,
  )
  let wrong = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      owner,
      "wrong-effect",
    )
    .unwrap()
  ignore(wrong.worker_drained())
  assert_eq(wrong.prepare_result("capture.annotations.add") is None, true)
  assert_eq(wrong.phase(), Rejected)
  assert_eq(wrong.prepare_result("result.text") is None, true)
}

///|
test "disabled then reenabled same digest does not revive a late result or release its worker early" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(1, 0).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/box",
      owner,
      "old",
    )
    .unwrap()
  let disabled = fixture_configuration(runtime, false, fixture_grants())
  assert_eq(call.needs_cancel(), true)
  assert_eq(call.phase(), Cancelling)
  assert_eq(runtime.quiescent(), false)
  assert_eq(
    runtime.begin_invocation(
      "example.capture",
      disabled.generation,
      "user.example.capture/box",
      owner,
      "disabled",
    )
    is None,
    true,
  )
  let enabled = fixture_configuration(runtime, true, fixture_grants())
  assert_eq(enabled.content, installed.content)
  ignore(call.worker_drained())
  assert_eq(call.prepare_result("capture.annotations.add") is None, true)
  assert_eq(call.phase(), Cancelled)
  let fresh = runtime
    .begin_invocation(
      "example.capture",
      enabled.generation,
      "user.example.capture/box",
      owner,
      "fresh",
    )
    .unwrap()
  ignore(fresh.worker_drained())
  assert_eq(
    fresh.prepare_result("capture.annotations.add").unwrap().commit(),
    true,
  )
}

///|
test "removing a sibling grant does not invalidate an unrelated contribution" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(1, 0).unwrap()
  let box = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/box",
      owner,
      "box",
    )
    .unwrap()
  let info = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      owner,
      "info",
    )
    .unwrap()
  ignore(
    fixture_configuration(runtime, true, [
      { id: "user.example.capture/info", effect: "result.text", },
    ]),
  )
  assert_eq(box.needs_cancel(), true)
  assert_eq(info.needs_cancel(), false)
  ignore(info.worker_drained())
  assert_eq(info.prepare_result("result.text").unwrap().commit(), true)
  ignore(box.worker_drained())
  assert_eq(runtime.quiescent(), true)
}

///|
test "retired content stays leased until old process drains and even same digest reinstall renews identity" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(1, 0).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/box",
      owner,
      "upgrade",
    )
    .unwrap()
  ignore(fixture_install(runtime, "2"))
  assert_eq(
    runtime.content_in_use("example.capture", installed.content.digest),
    true,
  )
  assert_eq(call.needs_cancel(), true)
  ignore(call.worker_drained())
  assert_eq(
    runtime.content_in_use("example.capture", installed.content.digest),
    false,
  )
  let current = runtime.package_snapshot("example.capture").unwrap()
  let completed_worker = runtime
    .begin_invocation(
      "example.capture",
      current.generation,
      "user.example.capture/info",
      owner,
      "ready-old",
    )
    .unwrap()
  ignore(completed_worker.worker_drained())
  let result = completed_worker.prepare_result("result.text").unwrap()
  let reinstalled = fixture_install(runtime, "2")
  assert_eq(reinstalled.content, current.content)
  assert_eq(reinstalled.install_generation != current.install_generation, true)
  assert_eq(result.ready(), false)
  assert_eq(result.commit(), false)
}

///|
test "owner revision and recycled owner IDs cannot adopt prior results" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(1, 9007199254740990).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      owner,
      "one",
    )
    .unwrap()
  let changed = runtime.update_owner(owner, 0).unwrap()
  assert_eq(call.needs_cancel(), true)
  assert_eq(runtime.update_owner(owner, 1) is None, true)
  assert_eq(runtime.close_owner(owner), false)
  assert_eq(
    runtime.begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      changed,
      "one",
    )
    is None,
    true,
  )
  assert_eq(runtime.close_owner(changed), true)
  let replacement = runtime.open_owner(1, 0).unwrap()
  let fresh = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      replacement,
      "one",
    )
    .unwrap()
  ignore(call.worker_drained())
  assert_eq(call.prepare_result("result.text") is None, true)
  ignore(fresh.worker_drained())
  let result = fresh.prepare_result("result.text").unwrap()
  ignore(runtime.update_owner(replacement, 0))
  assert_eq(result.commit(), false)
  assert_eq(runtime.open_owner(2, 0.5) is None, true)
  assert_eq(runtime.open_owner(2, 0.0 / 0.0) is None, true)
}

///|
test "close waits for checker, publishing IO and process ACK without accepting late effects" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(1, 0).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/box",
      owner,
      "closing",
    )
    .unwrap()
  let health = runtime
    .prepare_install(
      fixture_content("2"),
      installed.generation,
      true,
      fixture_grants(),
    )
    .unwrap()
  let publishing = runtime
    .prepare_configuration("example.capture", installed.generation, false, [])
    .unwrap()
  assert_eq(publishing.begin_publish(), true)
  runtime.begin_close()
  runtime.begin_close()
  assert_eq(runtime.is_closing(), true)
  assert_eq(runtime.quiescent(), false)
  assert_eq(health.needs_cancel(), true)
  assert_eq(call.needs_cancel(), true)
  assert_eq(runtime.open_owner(2, 0) is None, true)
  assert_eq(health.health_complete(true), true)
  assert_eq(health.phase(), Cancelled)
  assert_eq(runtime.quiescent(), false)
  ignore(call.worker_drained())
  assert_eq(call.prepare_result("capture.annotations.add") is None, true)
  assert_eq(runtime.quiescent(), false)
  assert_eq(publishing.publish_complete(true), true)
  assert_eq(
    runtime.package_snapshot("example.capture").unwrap().desired_enabled,
    false,
  )
  assert_eq(runtime.quiescent(), true)
}

///|
test "failed configuration leaves in-flight grants and prepared results unchanged" {
  let runtime = Runtime::new()
  let installed = fixture_install(runtime, "1")
  let owner = runtime.open_owner(1, 3).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      owner,
      "retained",
    )
    .unwrap()
  ignore(call.worker_drained())
  let result = call.prepare_result("result.text").unwrap()
  let disabling = runtime
    .prepare_configuration("example.capture", installed.generation, false, [])
    .unwrap()
  assert_eq(disabling.begin_publish(), true)
  assert_eq(disabling.publish_complete(false), true)
  assert_eq(runtime.package_snapshot("example.capture"), Some(installed))
  assert_eq(result.commit(), true)
}
