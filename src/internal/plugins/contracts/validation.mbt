///|
using @json {type Json}

///|
using @protocol {type InputError}

///|
pub fn parse_object(
  text : String,
  byte_limit : Int32,
) -> Map[String, Json] raise InputError {
  if text.length() > byte_limit {
    raise InputError("limit_exceeded", "JSON exceeds its UTF-8 byte limit")
  }
  // C callers can supply raw UTF-16 that String iteration/UTF-8 encoding
  // would abort on. Validate code units before either operation.
  let mut index = 0
  while index < text.length() {
    let unit = text[index]
    if unit.is_leading_surrogate() {
      if index + 1 >= text.length() || !text[index + 1].is_trailing_surrogate() {
        raise InputError("invalid_json", "JSON input must contain valid UTF-16")
      }
      index += 2
    } else {
      if unit.is_trailing_surrogate() {
        raise InputError("invalid_json", "JSON input must contain valid UTF-16")
      }
      index += 1
    }
  }
  if @utf8.encode(text).length() > byte_limit {
    raise InputError("limit_exceeded", "JSON exceeds its UTF-8 byte limit")
  }
  let value = @json.parse(
    text,
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ =>
      raise InputError("invalid_json", "Expected JSON without duplicate keys")
  }
  object(value, "invalid_input", "JSON input")
}

///|
fn object(
  value : Json,
  code : String,
  label : String,
) -> Map[String, Json] raise InputError {
  match value {
    Object(fields) => fields
    _ => raise InputError(code, "\{label} must be an object")
  }
}

///|
fn exact_fields(
  fields : Map[String, Json],
  names : Array[String],
  code : String,
) -> Unit raise InputError {
  for key, _ in fields {
    if !names.contains(key) {
      raise InputError(code, "Unsupported field: \{key}")
    }
  }
  for key in names {
    if !fields.contains(key) {
      raise InputError(code, "Missing field: \{key}")
    }
  }
}

///|
fn string(
  fields : Map[String, Json],
  key : String,
  maximum : Int32,
  code : String,
) -> String raise InputError {
  match fields.get(key) {
    Some(String(value)) if value.length() > 0 && value.length() <= maximum =>
      value
    _ => raise InputError(code, "\{key} must contain 1–\{maximum} characters")
  }
}

///|
fn display_string(
  fields : Map[String, Json],
  key : String,
  code : String,
) -> String raise InputError {
  let value = string(fields, key, 80, code)
  if value.trim().length() == 0 {
    raise InputError(code, "\{key} cannot be blank")
  }
  for char in value.iter() {
    if char.to_int() < 32 || char.to_int() == 127 {
      raise InputError(code, "\{key} cannot contain control characters")
    }
  }
  value
}

///|
fn ascii_lower(value : Int32) -> Bool {
  value >= 97 && value <= 122
}

///|
fn ascii_digit(value : Int32) -> Bool {
  value >= 48 && value <= 57
}

///|
pub fn local_key_valid(value : String) -> Bool {
  if value.length() == 0 || !ascii_lower(value[0].to_int()) {
    return false
  }
  for char in value.iter() {
    let c = char.to_int()
    if !ascii_lower(c) && !ascii_digit(c) && c != 45 {
      return false
    }
  }
  value[value.length() - 1].to_int() != 45
}

///|
pub fn plugin_id_valid(value : String) -> Bool {
  if value.has_prefix("builtin") {
    return false
  }
  let segments = value.split(".").to_array()
  if segments.length() < 2 {
    return false
  }
  for segment in segments {
    if !local_key_valid(segment.to_owned()) {
      return false
    }
  }
  true
}

///|
fn version_valid(value : String) -> Bool {
  let parts = value.split(".").to_array()
  if parts.length() != 3 {
    return false
  }
  for part in parts {
    if part.length() == 0 ||
      part.length() > 9 ||
      (part.length() > 1 && part[0].to_int() == 48) {
      return false
    }
    for char in part.iter() {
      if !ascii_digit(char.to_int()) {
        return false
      }
    }
  }
  true
}

///|
fn api_version(fields : Map[String, Json]) -> Unit raise InputError {
  if fields.get("apiVersion") != Some(Json(1)) {
    raise InputError("unsupported_api_version", "Expected plugin API version 1")
  }
}

///|
pub fn decode_manifest(value : Json) -> Manifest raise InputError {
  let fields = object(value, "invalid_manifest", "Manifest")
  exact_fields(
    fields,
    [
      "apiVersion", "pluginId", "name", "version", "entry", "runtime", "capabilities",
      "tools",
    ],
    "invalid_manifest",
  )
  api_version(fields)
  let plugin_id = string(fields, "pluginId", 96, "invalid_manifest")
  if !plugin_id_valid(plugin_id) {
    raise InputError(
      "invalid_manifest", "pluginId must be a lowercase reverse-domain ID outside the builtin namespace",
    )
  }
  let name = display_string(fields, "name", "invalid_manifest")
  let version = string(fields, "version", 29, "invalid_manifest")
  if !version_valid(version) {
    raise InputError(
      "invalid_manifest", "version must be X.Y.Z without leading zeros or suffixes",
    )
  }
  if fields.get("entry") != Some(Json("plugin.wasm")) ||
    fields.get("runtime") != Some(Json("extism-1")) {
    raise InputError(
      "invalid_manifest", "Expected entry plugin.wasm and runtime extism-1",
    )
  }
  let capabilities = match fields.get("capabilities") {
    Some(Array(items)) => items
    _ => raise InputError("invalid_manifest", "capabilities must be an array")
  }
  if capabilities.length() != 2 ||
    !capabilities.contains(Json("capture.metadata")) ||
    !capabilities.contains(Json("result.text")) {
    raise InputError(
      "unsupported_capability", "Exactly capture.metadata and result.text are required",
    )
  }
  let declared = match fields.get("tools") {
    Some(Array(items)) if items.length() > 0 && items.length() <= 16 => items
    _ =>
      raise InputError(
        "invalid_manifest", "A package must declare 1–16 tools",
      )
  }
  let tools : Array[UserTool] = []
  let seen : Map[String, Bool] = Map([])
  for item in declared {
    let fields = object(item, "invalid_manifest", "Tool")
    exact_fields(
      fields,
      ["toolId", "title", "target", "action"],
      "invalid_manifest",
    )
    let local_id = string(fields, "toolId", 48, "invalid_manifest")
    if !local_key_valid(local_id) || seen.contains(local_id) {
      raise InputError(
        "invalid_manifest", "Tool IDs must be unique lowercase local keys",
      )
    }
    if fields.get("target") != Some(Json("screenshot")) ||
      fields.get("action") != Some(Json("run")) {
      raise InputError(
        "invalid_manifest", "Only screenshot/run tools are supported",
      )
    }
    tools.push({
      plugin_id,
      local_id,
      title: display_string(fields, "title", "invalid_manifest"),
    })
    seen[local_id] = true
  }
  { plugin_id, name, version, tools, }
}

///|
fn invocation_id(fields : Map[String, Json]) -> String raise InputError {
  let value = string(fields, "invocationId", 128, "invalid_request")
  for index in 0..<value.length() {
    let code = value[index].to_int()
    if code < 33 || code > 126 {
      raise InputError(
        "invalid_request", "invocationId must be printable ASCII without spaces",
      )
    }
  }
  value
}

///|
fn integer(
  fields : Map[String, Json],
  key : String,
  minimum : Double,
  maximum : Double,
) -> Double raise InputError {
  match fields.get(key) {
    Some(Number(value, ..)) if value >= minimum &&
      value <= maximum &&
      @double.floor(value) == value => value
    _ => raise InputError("invalid_request", "Invalid capture \{key}")
  }
}

///|
fn decode_request(
  fields : Map[String, Json],
) -> InvocationRequest raise InputError {
  exact_fields(
    fields,
    ["manifest", "toolId", "invocationId", "capture"],
    "invalid_request",
  )
  let manifest = decode_manifest(fields["manifest"])
  let global_id = string(fields, "toolId", 150, "invalid_request")
  let mut selected : UserTool? = None
  for tool in manifest.tools {
    if tool.global_id() == global_id {
      selected = Some(tool)
      break
    }
  }
  let tool = match selected {
    Some(tool) => tool
    None =>
      raise InputError("unknown_tool", "Tool does not belong to this package")
  }
  let capture = object(fields["capture"], "invalid_request", "capture")
  exact_fields(
    capture,
    ["width", "height", "format", "revision"],
    "invalid_request",
  )
  if capture.get("format") != Some(Json("png")) {
    raise InputError(
      "invalid_request", "Only PNG capture metadata is supported",
    )
  }
  {
    invocation_id: invocation_id(fields),
    tool,
    capture: {
      width: integer(capture, "width", 1, 32768).to_int(),
      height: integer(capture, "height", 1, 32768).to_int(),
      revision: integer(capture, "revision", 0, 9007199254740990),
    },
  }
}

///|
fn decode_output(fields : Map[String, Json]) -> TextResult raise InputError {
  exact_fields(fields, ["invocationId", "output"], "invalid_output")
  let expected = invocation_id(fields)
  let output = object(fields["output"], "invalid_output", "Plugin output")
  exact_fields(
    output,
    ["apiVersion", "invocationId", "kind", "title", "text"],
    "invalid_output",
  )
  api_version(output)
  let actual = invocation_id(output)
  if actual != expected {
    raise InputError(
      "invocation_mismatch", "Output belongs to a different invocation",
    )
  }
  if output.get("kind") != Some(Json("text")) {
    raise InputError("invalid_output", "Only text results are supported")
  }
  let text = string(output, "text", 32768, "invalid_output")
  if @utf8.encode(text).length() > 32768 {
    raise InputError("limit_exceeded", "Result text exceeds 32 KiB UTF-8")
  }
  if @utf8.encode(Json::object(output).stringify()).length() > 262144 {
    raise InputError("limit_exceeded", "Result JSON exceeds 256 KiB UTF-8")
  }
  {
    invocation_id: actual,
    title: display_string(output, "title", "invalid_output"),
    text,
  }
}
