///|
using @json {type Json}

///|
pub(all) suberror InputError {
  InputError(String, String)
}

///|
pub fn response(body : () -> Json raise InputError) -> String {
  let value = body() catch {
    InputError(code, message) =>
      Json::object({
        "ok": Json(false),
        "error": Json::object({ "code": Json(code), "message": Json(message) }),
      })
  }
  value.stringify()
}

///|
pub fn request_object(text : String) -> Map[String, Json] raise InputError {
  if text.length() > 65536 {
    raise InputError("invalid_input", "Request is too large")
  }
  let parsed = @json.parse(
    text,
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise InputError("invalid_json", "Expected a valid JSON object")
  }
  match parsed {
    Object(fields) => fields
    _ => raise InputError("invalid_input", "Expected a JSON object")
  }
}

///|
pub fn object_field(
  fields : Map[String, Json],
  key : String,
) -> Map[String, Json] raise InputError {
  match fields.get(key) {
    Some(Object(value)) => value
    _ => raise InputError("invalid_input", "\{key} must be an object")
  }
}

///|
// Keep values as bounded integral doubles across the host ABI. No unchecked
// float-to-Int32 conversion can wrap a large or non-finite caller input.
pub fn integer_field(
  fields : Map[String, Json],
  key : String,
  minimum : Double,
  maximum : Double,
) -> Double raise InputError {
  match fields.get(key) {
    Some(Number(value, ..)) => {
      if !(value >= minimum && value <= maximum && @double.floor(value) == value) {
        raise InputError(
          "invalid_input",
          "\{key} must be an integer between \{minimum} and \{maximum}",
        )
      }
      value
    }
    _ => raise InputError("invalid_input", "\{key} must be a number")
  }
}

///|
pub fn smaller(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
pub fn larger(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}
