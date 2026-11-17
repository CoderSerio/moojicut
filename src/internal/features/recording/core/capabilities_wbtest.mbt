///|
fn capability_field(platform : String, field : String) -> Json raise {
  let result = @test_support.model_test_result(recording_capabilities(platform))
  @test_support.model_test_field(result, field)
}

///|
test "static capabilities distinguish implemented backends from runtime permission" {
  for platform in ["macOS", "windows", "linux-x11", "linux-wayland"] {
    assert_eq(capability_field(platform, "supported"), Json(true))
    assert_eq(capability_field(platform, "availability"), Json("unverified"))
    assert_eq(capability_field(platform, "permission"), Json("unknown"))
    assert_eq(capability_field(platform, "requiresHostValidation"), Json(true))
    assert_eq(capability_field(platform, "microphone"), Json(false))
    assert_eq(capability_field(platform, "pause"), Json(false))
  }
  assert_eq(
    capability_field("macOS", "sources"),
    Json(["display", "region", "window"]),
  )
  assert_eq(capability_field("macOS", "systemAudio"), Json(true))
  assert_eq(
    capability_field("windows", "sources"),
    Json(["primary-display", "display", "region"]),
  )
  assert_eq(capability_field("windows", "systemAudio"), Json(false))
  @test_support.expect_error(recording_capabilities("linux"), "invalid_input")
  @test_support.expect_error(recording_capabilities("Windows"), "invalid_input")
}

///|
test "X11 and Wayland have distinct source semantics and retain runtime checks" {
  for
    (platform, code, source) in [
      ("linux-x11", 2, "region"),
      ("linux-wayland", 3, "system-picker"),
    ] {
    assert_eq(capability_field(platform, "supported"), Json(true))
    assert_eq(capability_field(platform, "availability"), Json("unverified"))
    assert_eq(capability_field(platform, "permission"), Json("unknown"))
    let plan = @test_support.model_test_result(
      recording_request_plan(
        "{\"platform\":\"\{platform}\",\"source\":\"\{source}\",\"width\":3840,\"height\":2160,\"systemAudio\":false}",
      ),
    )
    assert_eq(@test_support.model_test_field(plan, "width"), Json(1920))
    assert_eq(@test_support.model_test_field(plan, "height"), Json(1080))
    assert_eq(@test_support.model_test_field(plan, "countdownSeconds"), Json(3))
    assert_eq(
      @test_support.model_test_field(plan, "requiresHostValidation"),
      Json(true),
    )
    assert_eq(native_recording_plan(code, 3840, 2160, 0)[2], 15)
    @test_support.expect_error(
      recording_request_plan(
        "{\"platform\":\"\{platform}\",\"source\":\"window\",\"width\":1920,\"height\":1080,\"systemAudio\":false}",
      ),
      "unsupported_source",
    )
  }
  assert_eq(
    capability_field("linux-x11", "sources"),
    Json(["display", "region"]),
  )
  assert_eq(
    capability_field("linux-wayland", "sources"),
    Json(["system-picker"]),
  )
}

///|
test "strict requests reject unavailable sources audio and pause instead of silently dropping intent" {
  for source in ["window", "camera", "system-picker"] {
    @test_support.expect_error(
      recording_request_plan(
        "{\"platform\":\"windows\",\"source\":\"\{source}\",\"width\":320,\"height\":240,\"systemAudio\":false}",
      ),
      "unsupported_source",
    )
  }
  @test_support.expect_error(
    recording_request_plan(
      "{\"platform\":\"windows\",\"source\":\"primary-display\",\"width\":320,\"height\":240,\"systemAudio\":true}",
    ),
    "unsupported_audio",
  )
  for
    (platform, source) in [("macOS", "window"), ("windows", "primary-display")] {
    @test_support.expect_error(
      recording_request_plan(
        "{\"platform\":\"\{platform}\",\"source\":\"\{source}\",\"width\":320,\"height\":240,\"systemAudio\":false,\"microphone\":true}",
      ),
      "unsupported_audio",
    )
    @test_support.expect_error(
      recording_request_plan(
        "{\"platform\":\"\{platform}\",\"source\":\"\{source}\",\"width\":320,\"height\":240,\"systemAudio\":false,\"pause\":true}",
      ),
      "unsupported_pause",
    )
  }
}

///|
test "capability plan and existing host ABIs share exact encoding policy" {
  for
    (platform, code, source, audio) in [
      ("macOS", 0, "region", true),
      ("macOS", 0, "window", false),
      ("macOS", 0, "display", true),
      ("windows", 1, "primary-display", false),
      ("windows", 1, "region", false),
      ("linux-x11", 2, "region", false),
      ("linux-wayland", 3, "system-picker", false),
    ] {
    for (width, height) in [(5120, 2880), (2880, 5120), (901, 1601), (2, 32768)] {
      let request = "{\"platform\":\"\{platform}\",\"source\":\"\{source}\",\"width\":\{width},\"height\":\{height},\"systemAudio\":\{audio}}"
      let result = @test_support.model_test_result(
        recording_request_plan(request),
      )
      let values = native_recording_plan(
        code,
        width,
        height,
        if audio {
          1
        } else {
          0
        },
      )
      let legacy = @test_support.model_test_result(recording_plan(request))
      for
        field in [
          "width", "height", "framesPerSecond", "systemAudio", "microphone", "countdownSeconds",
        ] {
        assert_eq(
          @test_support.model_test_field(result, field),
          @test_support.model_test_field(legacy, field),
        )
      }
      assert_eq(
        @test_support.model_test_field(result, "width"),
        Json(values[0]),
      )
      assert_eq(
        @test_support.model_test_field(result, "height"),
        Json(values[1]),
      )
      assert_eq(
        @test_support.model_test_field(result, "permission"),
        Json("unknown"),
      )
      assert_eq(
        @test_support.model_test_field(result, "availability"),
        Json("unverified"),
      )
      assert_eq(
        @test_support.model_test_field(result, "requiresHostValidation"),
        Json(true),
      )
      assert_eq(
        @test_support.model_test_field(result, "inputCoordinateSpace"),
        Json("source-pixels"),
      )
      let limits = capability_field(platform, "limits")
      assert_eq(
        @test_support.model_test_field(result, "framesPerSecond"),
        @test_support.model_test_field(limits, "framesPerSecond"),
      )
      assert_eq(
        @test_support.model_test_field(result, "countdownSeconds"),
        @test_support.model_test_field(limits, "countdownSeconds"),
      )
    }
  }
}

///|
test "strict planning rejects fabricated permissions and malformed capability requests" {
  for
    extra in [
      ",\"permission\":\"granted\"", ",\"microphone\":null", ",\"pause\":1", ",\"framesPerSecond\":60",
    ] {
    @test_support.expect_error(
      recording_request_plan(
        "{\"platform\":\"macOS\",\"source\":\"region\",\"width\":320,\"height\":240,\"systemAudio\":true\{extra}}",
      ),
      "invalid_input",
    )
  }
  for
    input in [
      "{}", "{\"platform\":\"macOS\",\"source\":\"region\",\"width\":1,\"height\":240,\"systemAudio\":false}",
      "{\"platform\":\"macOS\",\"source\":\"region\",\"width\":320.5,\"height\":240,\"systemAudio\":false}",
      "{\"platform\":\"macOS\",\"source\":\"region\",\"width\":320,\"height\":240,\"systemAudio\":0}",
      "{\"platform\":\"macOS\",\"source\":\"region\",\"width\":320,\"height\":240}",
      "{\"platform\":\"macOS\",\"source\":null,\"width\":320,\"height\":240,\"systemAudio\":false}",
    ] {
    @test_support.expect_error(recording_request_plan(input), "invalid_input")
  }
}
