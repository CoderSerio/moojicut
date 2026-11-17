///|
test "share budget lowers bitrate and reserves audio plus mux overhead" {
  let profile = export_profile(
    (
      #|{"durationMs":120000,"width":1920,"height":1080,"preset":"share","hasAudio":true}
    ),
  )
  assert_eq(@test_support.number_result(profile, "maxWidth"), 1280.0)
  assert_eq(@test_support.number_result(profile, "audioBitrateKbps"), 96.0)
  assert_true(@test_support.number_result(profile, "videoBitrateKbps") >= 250.0)
  assert_true(@test_support.number_result(profile, "estimatedBytes") <= 26214400.0)
  assert_true(@json.parse(profile) is Object({ "fitsTarget": True, .. }))
}

///|
test "impossible file budget retains a minimum bitrate and reports failure to fit" {
  let profile = export_profile(
    (
      #|{"durationMs":60000,"width":1920,"height":1080,"preset":"share","hasAudio":true,"targetBytes":1024}
    ),
  )
  assert_eq(@test_support.number_result(profile, "videoBitrateKbps"), 250.0)
  assert_eq(@test_support.number_result(profile, "audioBitrateKbps"), 96.0)
  assert_true(@test_support.number_result(profile, "estimatedBytes") > 1024.0)
  assert_true(@json.parse(profile) is Object({ "fitsTarget": False, .. }))
}

///|
test "quality prioritizes pixels and a silent video reserves no audio budget" {
  let profile = export_profile(
    (
      #|{"durationMs":60000,"width":3840,"height":2160,"preset":"quality","hasAudio":false,"targetBytes":1024}
    ),
  )
  assert_eq(@test_support.number_result(profile, "maxWidth"), 1920.0)
  assert_eq(@test_support.number_result(profile, "audioBitrateKbps"), 0.0)
  assert_eq(@test_support.number_result(profile, "videoBitrateKbps"), 6221.0)
  assert_true(@json.parse(profile) is Object({ "fitsTarget": False, .. }))
}

///|
test "encoder requests require bounded integer dimensions and a known preset" {
  @test_support.expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1e100,"height":1080,"preset":"share","hasAudio":false}
      ),
    ),
    "invalid_input",
  )
  @test_support.expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1920,"height":1080,"preset":"share","hasAudio":false,"targetBytes":0}
      ),
    ),
    "invalid_input",
  )
  @test_support.expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1920,"height":1080,"preset":"fast","hasAudio":false}
      ),
    ),
    "invalid_input",
  )
  @test_support.expect_error(
    export_profile(
      (
        #|{"durationMs":1000,"width":1920,"height":1080,"preset":"share","hasAudio":"false"}
      ),
    ),
    "invalid_input",
  )
}
