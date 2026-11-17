///|
test "trim exports an exclusive source interval starting at output zero" {
  @test_support.expect_json(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":1000,"endMs":9000}}
      ),
    ),
    (
      #|{"ok":true,"segments":[{"sourceStartMs":1000,"sourceEndMs":9000,"outputStartMs":0,"outputEndMs":8000}],"outputDurationMs":8000}
    ),
  )
}

///|
test "removing the middle joins both retained intervals without a timeline gap" {
  @test_support.expect_json(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":1000,"endMs":9000},"cut":{"startMs":3000,"endMs":5000}}
      ),
    ),
    (
      #|{"ok":true,"segments":[{"sourceStartMs":1000,"sourceEndMs":3000,"outputStartMs":0,"outputEndMs":2000},{"sourceStartMs":5000,"sourceEndMs":9000,"outputStartMs":2000,"outputEndMs":6000}],"outputDurationMs":6000}
    ),
  )
}

///|
test "a cut is intersected with the trim instead of extending its bounds" {
  @test_support.expect_json(
    edit_plan(
      (
        #|{"durationMs":10000,"trim":{"startMs":2000,"endMs":8000},"cut":{"startMs":0,"endMs":3000}}
      ),
    ),
    (
      #|{"ok":true,"segments":[{"sourceStartMs":3000,"sourceEndMs":8000,"outputStartMs":0,"outputEndMs":5000}],"outputDurationMs":5000}
    ),
  )
  assert_eq(
    @test_support.number_result(
      edit_plan(
        (
          #|{"durationMs":10000,"trim":{"startMs":2000,"endMs":8000},"cut":{"startMs":8000,"endMs":9000}}
        ),
      ),
      "outputDurationMs",
    ),
    6000.0,
  )
}

///|
test "invalid and empty edits never produce an exportable timeline" {
  @test_support.expect_error(
    edit_plan(
      (
        #|{"durationMs":1000,"trim":{"startMs":0,"endMs":1000},"cut":{"startMs":0,"endMs":1000}}
      ),
    ),
    "empty_output",
  )
  @test_support.expect_error(
    edit_plan(
      (
        #|{"durationMs":1000,"trim":{"startMs":900,"endMs":100}}
      ),
    ),
    "invalid_range",
  )
  @test_support.expect_error(
    edit_plan(
      (
        #|{"durationMs":1000,"trim":{"startMs":0,"endMs":1001}}
      ),
    ),
    "invalid_input",
  )
}

///|
test "fractional and enormous numbers are rejected before numeric conversion" {
  for value in ["1.5", "1e100", "-1", "9007199254740992", "null", "\"1000\""] {
    @test_support.expect_error(
      edit_plan(
        "{\"durationMs\":\{value},\"trim\":{\"startMs\":0,\"endMs\":1}}",
      ),
      "invalid_input",
    )
  }
  @test_support.expect_error(edit_plan("{\"durationMs\":NaN}"), "invalid_json")
  @test_support.expect_error(edit_plan("{\"durationMs\":Infinity}"), "invalid_json")
  // Overflowed JSON exponents must also return an error, regardless of whether
  // the parser rejects them or produces a non-finite number.
  let overflowed = @json.parse(edit_plan("{\"durationMs\":1e999}"))
  assert_true(overflowed is Object({ "ok": False, .. }))
}

///|
test "requests reject malformed JSON duplicate keys and wrong root types" {
  @test_support.expect_error(edit_plan("{"), "invalid_json")
  @test_support.expect_error(edit_plan("[]"), "invalid_input")
  @test_support.expect_error(
    edit_plan("{\"durationMs\":1000,\"durationMs\":2000}"),
    "invalid_json",
  )
  @test_support.expect_error(edit_plan("{}"), "invalid_input")
}
