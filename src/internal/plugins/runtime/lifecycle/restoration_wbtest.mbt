///|
test "startup restore validates the whole set and seals even an empty bootstrap" {
  let runtime = Runtime::new()
  let valid : RestoredPackage = {
    content: fixture_content("1"),
    desired_enabled: true,
    grants: fixture_grants(),
  }
  let invalid : RestoredPackage = {
    content: { package_id: "invalid", digest: "bad", version: "1", },
    desired_enabled: false,
    grants: [],
  }
  assert_false(runtime.restore_packages([valid, invalid]))
  assert_true(runtime.package_snapshot("example.capture") is None)
  assert_false(runtime.restore_packages([valid, valid]))
  assert_true(runtime.restore_packages([valid]))
  valid.grants.clear()
  let installed = runtime.package_snapshot("example.capture").unwrap()
  let owner = runtime.open_owner(1, 0).unwrap()
  let call = runtime
    .begin_invocation(
      "example.capture",
      installed.generation,
      "user.example.capture/info",
      owner,
      "restored",
    )
    .unwrap()
  call.cancel()
  ignore(call.worker_drained())
  assert_false(runtime.restore_packages([]))
  let empty = Runtime::new()
  assert_true(empty.restore_packages([]))
  assert_false(empty.restore_packages([valid]))
  assert_true(
    empty.prepare_install(fixture_content("1"), 0, true, []) is Some(_),
  )
  let previously_used = Runtime::new()
  let ticket = previously_used
    .prepare_install(fixture_content("1"), 0, true, [])
    .unwrap()
  ticket.cancel()
  ignore(ticket.health_complete(false))
  assert_true(previously_used.quiescent())
  assert_false(previously_used.restore_packages([]))
  let closed = Runtime::new()
  closed.begin_close()
  assert_false(closed.restore_packages([]))
}
