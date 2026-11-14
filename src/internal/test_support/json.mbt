///|
using @json {type Json}

///|
pub fn expect_json(actual : String, expected : String) -> Unit raise {
  assert_true(@json.parse(actual) == @json.parse(expected))
}

///|
pub fn expect_error(actual : String, expected_code : String) -> Unit raise {
  match @json.parse(actual) {
    Object({ "ok": False, "error": Object({ "code": String(code), .. }), .. }) =>
      assert_eq(code, expected_code)
    _ => abort("Expected a structured error: " + actual)
  }
}

///|
pub fn number_result(actual : String, key : String) -> Double raise {
  match @json.parse(actual) {
    Object(fields) =>
      match fields.get(key) {
        Some(Number(value, ..)) => value
        _ => abort("Missing numeric result: " + key)
      }
    _ => abort("Expected an object result")
  }
}

///|
pub fn model_test_result(text : String) -> Json raise {
  let result = @json.parse(text)
  assert_true(result is Object({ "ok": True, .. }))
  result
}

///|
pub fn model_test_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap()
    _ => abort("Expected an object")
  }
}

///|
pub fn model_test_items(value : Json) -> Array[Json] {
  match value {
    Array(items) => items
    _ => abort("Expected an array")
  }
}
