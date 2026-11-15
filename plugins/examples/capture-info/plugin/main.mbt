///|
priv struct Capture {
  width : Int32
  height : Int32
  revision : Double
}

///|
// Edit this function and manifest.json to create your own tools. Both examples
// return text; Mooji Cut's result window supplies the user-operated Copy button.
fn describe(tool_id : String, capture : Capture) -> (String, String)? {
  match tool_id {
    "describe" =>
      Some(
        (
          "截图信息",
          "尺寸：\{capture.width} × \{capture.height} 像素\n格式：PNG\n修订：\{capture.revision}\n\n这里只读取当前截图的元数据，不读取图像内容。",
        ),
      )
    "copy-size" =>
      Some(("查看尺寸", "\{capture.width} × \{capture.height}"))
    _ => None
  }
}

///|
// The app already validates the request. This adapter decodes the fields needed
// by the example and preserves the invocation ID; it is not a second SDK.
fn respond(input : @json.Json) -> @json.Json? {
  match input {
    Object(
      {
        "apiVersion": Number(api_version, ..),
        "invocationId": String(invocation_id),
        "toolId": String(tool_id),
        "capture": Object(
          {
            "width": Number(width, ..),
            "height": Number(height, ..),
            "format": String("png"),
            "revision": Number(revision, ..),
            ..
          }
        ),
        ..
      }
    ) if api_version == 1 &&
      width >= 1 &&
      width <= 32768 &&
      height >= 1 &&
      height <= 32768 => {
      let (title, text) = match
        describe(tool_id, {
          width: width.to_int(),
          height: height.to_int(),
          revision,
        }) {
        Some(result) => result
        None => return None
      }
      Some(
        @json.Json::object({
          "apiVersion": @json.Json(1),
          "invocationId": @json.Json(invocation_id),
          "kind": @json.Json("text"),
          "title": @json.Json(title),
          "text": @json.Json(text),
        }),
      )
    }
    _ => None
  }
}

///|
// Fixed Extism ABI: the exported name is mooji_run, with signature () -> i32.
pub fn mooji_run() -> Int32 {
  let input = @json.parse(
    @host.input_string(),
    max_nesting_depth=16,
    reject_duplicate_keys=true,
  ) catch {
    _ => {
      @host.set_error("Invalid Mooji Cut request JSON")
      return 1
    }
  }
  match respond(input) {
    Some(output) => {
      @host.output_string(output.stringify())
      0
    }
    None => {
      @host.set_error("Unsupported capture-info tool or request")
      1
    }
  }
}
