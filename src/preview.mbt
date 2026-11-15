///|
using @json {type Json}

///|
// Executed by native preview hosts and their packaged-binary smoke checks.
// Exercise actual editing code across the static-library boundary.
#export_name("preview_core_check")
pub fn preview_core_check() -> Int32 {
  let created = @json.parse(image_create("{\"width\":320,\"height\":200}")) catch {
    _ => return 0
  }
  let document = match created {
    Object({ "ok": True, "document": document, .. }) => document
    _ => return 0
  }
  let text = "Mooji Cut 月兔 ✂️"
  let annotation = Json::object({
    "id": Json("native-check"),
    "type": Json("text"),
    "x": Json(10),
    "y": Json(10),
    "width": Json(250),
    "height": Json(40),
    "text": Json(text),
    "fontSize": Json(18),
    "color": Json("#F26769"),
    "stroke": Json(3),
    "opacity": Json(1),
  })
  let request = Json::object({
    "document": document,
    "expectedRevision": Json(0),
    "command": Json::object({
      "type": Json("add"),
      "annotations": Json::array([annotation]),
    }),
  })
  let applied = @json.parse(image_apply(request.stringify())) catch {
    _ => return 0
  }
  let image_ok = match applied {
    Object(
      {
        "ok": True,
        "document": Object(
          {
            "revision": Number(1, ..),
            "annotations": Array([Object({ "text": String(value), .. })]),
            ..
          }
        ),
        ..
      }
    ) => value == text
    _ => false
  }
  let plan = @json.parse(
    edit_plan(
      "{\"durationMs\":10000,\"trim\":{\"startMs\":1000,\"endMs\":9000},\"cut\":{\"startMs\":3000,\"endMs\":5000}}",
    ),
  ) catch {
    _ => return 0
  }
  let video_ok = plan
    is Object({ "ok": True, "outputDurationMs": Number(6000, ..), .. })
  if image_ok && video_ok {
    1
  } else {
    0
  }
}
