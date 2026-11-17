///|
fn fixture() -> String {
  (
    #|{"ok":true,"commands":[
    #|{"type":"rect","x":1,"y":2,"width":30,"height":40,"radius":3,"fill":"#12AbEF","stroke":"#000000"},
    #|{"type":"line","x1":5,"y1":6,"x2":7,"y2":8,"lineWidth":2,"color":"#ffffff"},
    #|{"type":"text","x":9,"y":10,"width":80,"height":20,"text":"中文 🎬","size":14,"color":"#222222","weight":"bold","align":"center","valign":"center"}],
    #|"overlayCommands":[],"videoRect":{"x":20,"y":30,"width":640,"height":360},"cursor":"resize-horizontal",
    #|"semantics":[{"id":"gain","role":"slider","label":"音量","tooltip":"调整音量","x":2,"y":3,"width":40,"height":20,"value":0.5,"min":0,"max":1,"step":0.01,"enabled":false,"focused":true},
    #|{"id":"checked","role":"checkbox","label":"启用","tooltip":"","x":0,"y":0,"width":20,"height":20,"value":true},
    #|{"id":"caption","role":"staticText","label":"字幕","x":0,"y":0,"width":20,"height":20,"value":"你好"}]}
  )
}

///|
test "frame getters preserve drawing fields semantic types metadata and owned strings" {
  let h = open(fixture())
  assert_true(h > 0)
  assert_eq(value(h, 0), 1)
  assert_eq(value(h, 1), 1)
  assert_eq(video_rect(h, 2), 640)
  assert_eq(command_count(h, 0), 3)
  assert_eq(command_count(h, 1), 0)
  assert_eq(command_value(h, 0, 0, 0), 1)
  assert_eq(command_value(h, 0, 0, 1), 0x12ABEF)
  assert_eq(command_value(h, 0, 0, 2), 0)
  assert_eq(command_number(h, 0, 0, 4), 3)
  assert_eq(command_number(h, 0, 0, 5), 1)
  assert_eq(command_value(h, 0, 1, 0), 2)
  assert_eq(command_value(h, 0, 1, 1), -1)
  assert_eq(command_number(h, 0, 1, 0), 5)
  assert_eq(command_number(h, 0, 1, 6), 7)
  assert_eq(command_value(h, 0, 2, 4), 2)
  assert_eq(command_value(h, 0, 2, 5), 1)
  assert_eq(command_value(h, 0, 2, 6), 1)
  assert_eq(command_number(h, 0, 2, 8), 14)
  let text = command_text(h, 0, 2)
  assert_eq(text, "中文 🎬")
  assert_eq(semantic_count(h), 3)
  assert_eq(semantic_value(h, 0, 0), 2)
  assert_eq(semantic_value(h, 0, 1), 0)
  assert_eq(semantic_value(h, 0, 2), 1)
  for key in [4, 5, 6] {
    assert_eq(semantic_value(h, 0, key), 1)
  }
  assert_eq(semantic_number(h, 0, 4), 0.5)
  assert_eq(semantic_number(h, 0, 7), 0.01)
  assert_eq(semantic_text(h, 0, 2), "调整音量")
  assert_eq(semantic_value(h, 1, 3), 3)
  assert_eq(semantic_number(h, 1, 4), 1)
  assert_eq(semantic_text(h, 1, 2), "启用")
  assert_eq(semantic_text(h, 2, 2), "字幕")
  assert_eq(semantic_value(h, 2, 3), 2)
  assert_eq(semantic_text(h, 2, 3), "你好")
  assert_eq(close(h), 1)
  assert_eq(text, "中文 🎬")
  assert_eq(close(h), 0)
  assert_eq(command_count(h, 0), -1)
  assert_eq(command_value(h, 0, 0, 0), -1)
  assert_eq(command_number(h, 0, 0, 0), 0)
  assert_eq(command_text(h, 0, 2), "")
  assert_eq(semantic_count(h), -1)
  assert_eq(semantic_value(h, 0, 0), -1)
  assert_eq(semantic_number(h, 0, 0), 0)
  assert_eq(semantic_text(h, 0, 0), "")
}

///|
test "malformed commands and semantics reject the entire frame without affecting a live one" {
  let original = open(fixture())
  let fields = object(@json.parse(fixture()))
  let commands = array(fields, "commands", true)
  let cases : Array[(String, Json)] = [
    ("width", Json(-1)),
    ("x", Json(true)),
    ("height", Json("2")),
    ("fill", Json("#zzzzzz")),
    ("stroke", Json("#000")),
    ("radius", Json(-1)),
    ("lineWidth", Json(5000)),
    ("type", Json("image")),
  ]
  let rect = object(commands[0])
  for (key, invalid) in cases {
    let previous = rect.get(key)
    rect[key] = invalid
    assert_eq(open(Json::object(fields).stringify()), 0)
    match previous {
      Some(value) => rect[key] = value
      None => rect.remove(key)
    }
  }
  let text_command = object(commands[2])
  for
    (key, invalid) in [
      ("size", Json(0)),
      ("text", Json("x".repeat(32769))),
      ("weight", Json("huge")),
      ("align", Json("justify")),
      ("valign", Json("bottom")),
    ] {
    let previous = text_command[key]
    text_command[key] = invalid
    assert_eq(open(Json::object(fields).stringify()), 0)
    text_command[key] = previous
  }
  let nodes = array(fields, "semantics", true)
  let slider = object(nodes[0])
  for
    (key, invalid) in [
      ("id", Json("")),
      ("enabled", Json(1)),
      ("focused", Json("true")),
      ("value", Json("0.5")),
      ("min", Json(2)),
      ("step", Json(0)),
      ("role", Json("script")),
      ("tooltip", Json(false)),
    ] {
    let previous = slider.get(key)
    slider[key] = invalid
    assert_eq(open(Json::object(fields).stringify()), 0)
    match previous {
      Some(value) => slider[key] = value
      None => slider.remove(key)
    }
  }
  nodes.push(nodes[0])
  assert_eq(open(Json::object(fields).stringify()), 0)
  for
    invalid in [
      "", "{", "[]", "{}", "{\"ok\":false,\"commands\":[]}", "{\"ok\":true,\"ok\":true,\"commands\":[]}",
      "{\"ok\":true,\"commands\":[],\"videoRect\":false}", "{\"ok\":true,\"commands\":[],\"cursor\":\"invalid\"}",
      "{\"ok\":true,\"commands\":[],\"semantics\":null}",
    ] {
    assert_eq(open(invalid), 0)
  }
  assert_eq(command_text(original, 0, 2), "中文 🎬")
  assert_eq(command_count(original, 0), 3)
  assert_eq(command_count(original, -1), -1)
  assert_eq(command_value(original, 0, -1, 0), -1)
  assert_eq(command_value(original, 0, 0, 99), -1)
  assert_eq(semantic_text(original, 3, 0), "")
  assert_eq(value(original, 99), -1)
  assert_eq(close(original), 1)
}

///|
test "frame limits fail closed and handles remain independent and never reused" {
  let empty = "{\"ok\":true,\"commands\":[]}"
  let first = open(empty)
  assert_true(first > 0)
  assert_eq(value(first, 1), 0)
  assert_eq(video_rect(first, 0), 0)
  assert_eq(close(first), 1)
  let handles : Array[Int32] = []
  for _ in 0..<64 {
    let h = open(empty)
    assert_true(h > first)
    handles.push(h)
  }
  assert_eq(open(empty), 0)
  for h in handles {
    assert_eq(close(h), 1)
  }
  assert_eq(open(" ".repeat(4194305)), 0)
  let commands : Array[Json] = []
  let command = Json::object({
    "type": Json("rect"),
    "x": Json(0),
    "y": Json(0),
    "width": Json(1),
    "height": Json(1),
  })
  for _ in 0..<32768 {
    commands.push(command)
  }
  let fields = { "ok": Json(true), "commands": Json::array(commands) }
  let maximum = open(Json::object(fields).stringify())
  assert_true(maximum > first)
  assert_eq(command_count(maximum, 0), 32768)
  fields["overlayCommands"] = Json::array([command])
  assert_eq(open(Json::object(fields).stringify()), 0)
  assert_eq(command_count(maximum, 1), 0)
  assert_eq(close(maximum), 1)
  assert_eq(
    open(
      "{\"ok\":true,\"commands\":[],\"metadata\":" +
      "[".repeat(34) +
      "0" +
      "]".repeat(34) +
      "}",
    ),
    0,
  )
  let nodes : Array[Json] = []
  for i in 0..<16384 {
    nodes.push(
      Json::object({
        "id": Json("node-\{i}"),
        "x": Json(0),
        "y": Json(0),
        "width": Json(1),
        "height": Json(1),
      }),
    )
  }
  let semantic_frame = {
    "ok": Json(true),
    "commands": Json::array([]),
    "semantics": Json::array(nodes),
  }
  let maximum = open(Json::object(semantic_frame).stringify())
  assert_true(maximum > first)
  assert_eq(semantic_count(maximum), 16384)
  nodes.push(
    Json::object({
      "id": Json("overflow"),
      "x": Json(0),
      "y": Json(0),
      "width": Json(1),
      "height": Json(1),
    }),
  )
  assert_eq(open(Json::object(semantic_frame).stringify()), 0)
  assert_eq(close(maximum), 1)
}

///|
test "generic input encoder safely carries Unicode and rejects malformed input" {
  for
    (kind, name) in [
      (1, "pointerDown"),
      (2, "pointerMove"),
      (3, "pointerUp"),
      (4, "cancel"),
      (5, "scroll"),
    ] {
    let fields = object(@json.parse(input_event(kind, 1, 2, 3, -4, 7, "")))
    assert_eq(fields["type"], Json(name))
    if kind == 5 {
      assert_eq(fields["deltaY"], Json(-4))
      assert_eq(fields["mod"], Json(true))
      assert_eq(fields["shift"], Json(true))
      assert_eq(fields["precise"], Json(true))
    }
  }
  let id = "按钮\"\\\n🎬"
  assert_eq(
    object(@json.parse(input_event(7, 0, 0, 0, 0, 0, id)))["id"],
    Json(id),
  )
  assert_eq(
    object(@json.parse(input_event(6, 0, 0, 0, 0, 3, "ArrowLeft")))["mod"],
    Json(true),
  )
  assert_eq(
    object(@json.parse(input_event(8, 0, 0, 0, 0, 0, "light")))["mode"],
    Json("light"),
  )
  for kind in [0, 9, -1] {
    assert_eq(input_event(kind, 0, 0, 0, 0, 0, ""), "")
  }
  for flags in [-1, 8, 16] {
    assert_eq(input_event(1, 0, 0, 0, 0, flags, ""), "")
  }
  for n in [1.0 / 0.0, 0.0 / 0.0, 1000001.0] {
    assert_eq(input_event(1, n, 0, 0, 0, 0, ""), "")
  }
  for
    (kind, text) in [
      (1, "unexpected"),
      (6, ""),
      (7, "a".repeat(257)),
      (8, "blue"),
    ] {
    assert_eq(input_event(kind, 0, 0, 0, 0, 0, text), "")
  }
}
