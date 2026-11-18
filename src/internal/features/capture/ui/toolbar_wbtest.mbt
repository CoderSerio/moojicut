///|
fn toolbar_fixture_item(
  id : String,
  slot : Int32,
  enabled : Bool,
) -> ToolbarItem {
  {
    id,
    title: id,
    tooltip: "Hint: " + id,
    icon: "rectangle",
    asset_id: "",
    slot,
    enabled,
    selected: false,
  }
}

///|
fn toolbar_fixture_event(
  state : ToolbarState,
  kind : String,
  x : Double,
  y : Double,
) -> (Bool, String) {
  toolbar_input(
    state,
    Json::object({ "type": Json(kind), "x": Json(x), "y": Json(y) }).stringify(),
  )
}

///|
fn toolbar_fixture_key(state : ToolbarState, key : String) -> (Bool, String) {
  toolbar_input(
    state,
    Json::object({ "type": Json("key"), "key": Json(key) }).stringify(),
  )
}

///|
fn toolbar_fixture_activate(
  state : ToolbarState,
  id : String,
) -> (Bool, String) {
  toolbar_input(
    state,
    Json::object({ "type": Json("activate"), "id": Json(id) }).stringify(),
  )
}

///|
test "toolbar partitions two ordered groups and frame hit AX tooltip share actual bounds" {
  let state = toolbar_new()
  let items = [
    toolbar_fixture_item("rect", 0, true),
    toolbar_fixture_item("pin", 1, true),
    toolbar_fixture_item("ocr", 0, false),
    toolbar_fixture_item("translate", 0, true),
    toolbar_fixture_item("confirm", 1, true),
  ]
  assert_true(toolbar_sync(state, items, 800, 1))
  assert_eq(toolbar_size(state)[0], 143)
  assert_eq(toolbar_size(state)[1], 32)
  let layout = toolbar_layout(state)
  assert_eq(layout.placements.map(p => p.item.id), [
    "rect", "ocr", "translate", "pin", "confirm",
  ])
  assert_true(layout.separator > 80 && layout.separator < 89)
  let frame = @frame.open(toolbar_frame_json(state, false))
  assert_true(frame > 0)
  assert_eq(@frame.semantic_count(frame), 5)
  for index, placement in layout.placements {
    assert_eq(@frame.semantic_text(frame, index, 0), placement.item.id)
    assert_eq(@frame.semantic_text(frame, index, 2), placement.item.tooltip)
    assert_eq(@frame.semantic_number(frame, index, 0), placement.x)
    let point = placement.x + 12
    assert_eq(
      toolbar_fixture_event(state, "pointerDown", point, 16),
      (true, ""),
    )
    let (_, action) = toolbar_fixture_event(state, "pointerUp", point, 16)
    assert_eq(
      action,
      if placement.item.enabled {
        placement.item.id
      } else {
        ""
      },
    )
  }
  assert_eq(@frame.close(frame), 1)
  // Caller mutations do not alias state; disabling tools reduces natural width.
  items[0] = toolbar_fixture_item("replacement", 0, true)
  assert_eq(toolbar_layout(state).placements[0].item.id, "rect")
  assert_true(toolbar_sync(state, [items[1], items[4]], 800, 2))
  assert_eq(toolbar_size(state)[0], 58)
  assert_eq(toolbar_layout(state).separator, -1)
}

///|
test "held toolbar press cannot activate rebuilt moved disabled or cancelled targets" {
  let state = toolbar_new()
  let a = toolbar_fixture_item("a", 0, true)
  let b = toolbar_fixture_item("b", 0, true)
  assert_true(toolbar_sync(state, [a, b], 300, 1))
  ignore(toolbar_fixture_event(state, "pointerDown", 16, 16))
  assert_true(toolbar_sync(state, [a, b], 300, 1)) // Ordinary repaint preserves press.
  assert_eq(toolbar_fixture_event(state, "pointerUp", 16, 16), (true, "a"))
  ignore(toolbar_fixture_event(state, "pointerDown", 16, 16))
  assert_true(toolbar_sync(state, [b, a], 300, 2))
  assert_eq(toolbar_fixture_event(state, "pointerUp", 16, 16), (true, ""))
  ignore(toolbar_fixture_event(state, "pointerDown", 16, 16))
  assert_true(toolbar_sync(state, [b, a], 300, 3)) // Same IDs, changed registry generation.
  assert_eq(toolbar_fixture_event(state, "pointerUp", 16, 16), (true, ""))
  ignore(toolbar_fixture_event(state, "pointerDown", 16, 16))
  assert_true(
    toolbar_sync(state, [toolbar_fixture_item("b", 0, false), a], 300, 3),
  )
  assert_eq(toolbar_fixture_event(state, "pointerUp", 16, 16), (true, ""))
  ignore(toolbar_fixture_event(state, "pointerDown", 42, 16))
  toolbar_cancel(state)
  assert_eq(toolbar_fixture_event(state, "pointerUp", 42, 16), (true, ""))
  ignore(toolbar_fixture_event(state, "pointerDown", 42, 16))
  assert_eq(toolbar_fixture_event(state, "pointerUp", -1, 16), (true, ""))
  let before = toolbar_frame_json(state, true)
  assert_false(toolbar_sync(state, [a, a], 300, 4))
  assert_false(toolbar_sync(state, [a], 0.0 / 0.0, 4))
  assert_eq(toolbar_frame_json(state, true), before)
}

///|
test "overflow keeps finish actions reachable and keyboard reveals every enabled tool" {
  let state = toolbar_new()
  let items : Array[ToolbarItem] = []
  for i in 0..<32 {
    items.push(toolbar_fixture_item("plugin-\{i}", 0, i != 5))
  }
  for id in ["pin", "cancel", "confirm"] {
    items.push(toolbar_fixture_item(id, 1, true))
  }
  assert_true(toolbar_sync(state, items, 260, 1))
  let first = toolbar_layout(state)
  assert_true(first.pages > 1)
  assert_eq(first.pageable, 32)
  assert_eq(toolbar_fixture_activate(state, "plugin-31"), (true, "")) // Invisible AX cannot activate.
  assert_eq(toolbar_fixture_activate(state, "confirm"), (true, "confirm"))
  ignore(toolbar_fixture_key(state, "Home"))
  for i in 0..<32 {
    if i == 5 {
      continue
    }
    if i > 0 {
      ignore(toolbar_fixture_key(state, "ArrowRight"))
    }
    assert_eq(toolbar_fixture_key(state, "Enter"), (true, "plugin-\{i}"))
    let layout = toolbar_layout(state)
    assert_true(layout.placements.any(p => p.item.id == "confirm"))
    assert_true(layout.placements.any(p => p.item.id == "plugin-\{i}"))
    for p in layout.placements {
      assert_true(p.x >= 0 && p.x + 24 <= layout.width)
    }
  }
  // Ultra-narrow surfaces still have truthful non-overlapping scaled targets.
  assert_true(toolbar_sync(state, items, 32, 2))
  let narrow = toolbar_layout(state)
  assert_eq(toolbar_size(state)[0], 32)
  assert_eq(narrow.pageable, items.length())
  ignore(toolbar_fixture_key(state, "End"))
  assert_eq(toolbar_fixture_key(state, "Enter"), (true, "confirm"))
  let frame = @frame.open(toolbar_frame_json(state, true))
  assert_true(frame > 0)
  for p in toolbar_layout(state).placements {
    assert_true(p.x * narrow.scale >= 0 && (p.x + 24) * narrow.scale <= 32)
  }
  assert_eq(@frame.close(frame), 1)
  // Increasing the display width never expands the product beyond its compact
  // cap; exact breakpoint widths retain disjoint, clickable paging targets.
  for width in [32.0, 86, 117, 169, 260, 900] {
    assert_true(toolbar_sync(state, items, width, 3))
    ignore(toolbar_fixture_key(state, "Home"))
    assert_true(toolbar_size(state)[0] <= 384)
    let seen : Map[String, Bool] = Map([])
    for _ in 0..<64 {
      let layout = toolbar_layout(state)
      for i, p in layout.placements {
        if !p.item.id.has_prefix("__toolbar.") {
          seen[p.item.id] = true
        }
        for j in (i + 1)..<layout.placements.length() {
          let q = layout.placements[j]
          assert_true(p.x + 24 <= q.x || q.x + 24 <= p.x)
        }
      }
      if !layout.placements.any(p => {
          p.item.id == "__toolbar.next" && p.item.enabled
        }) {
        break
      }
      ignore(toolbar_fixture_activate(state, "__toolbar.next"))
    }
    assert_eq(seen.length(), items.length())
  }
  let before = toolbar_frame_json(state, false)
  assert_eq(
    toolbar_input(
      state, "{\"type\":\"scroll\",\"x\":800,\"y\":16,\"deltaY\":-1}",
    ),
    (false, ""),
  )
  assert_eq(toolbar_frame_json(state, false), before)
}

///|
test "canonical icons distinguish mosaic shades light dark selection and real assets" {
  let mosaic = @icons.commands("mosaic", 0, 0, 24, 0xffffff, 0)
  assert_eq(mosaic.length(), 4)
  let shades : Map[String, Bool] = Map([])
  for tile in mosaic {
    if at(tile, "fill") is String(s) {
      shades[s] = true
    }
  }
  assert_eq(shades.length(), 4)
  assert_eq(
    @icons.commands("missing", 0, 0, 24, 0, 0xffffff),
    @icons.commands("plugin", 0, 0, 24, 0, 0xffffff),
  )
  let state = toolbar_new()
  let vector = toolbar_fixture_item("tool", 0, true)
  assert_true(toolbar_sync(state, [vector], 300, 1))
  let light = toolbar_frame_json(state, false)
  let dark = toolbar_frame_json(state, true)
  assert_true(light.contains("#252525"))
  assert_true(dark.contains("#f5f5f5"))
  let asset : ToolbarItem = { ..vector, asset_id: "plugin-icon-0", }
  assert_true(toolbar_sync(state, [asset], 300, 2))
  let decoded = @json.parse(toolbar_frame_json(state, false)) catch {
    _ => abort("bad frame")
  }
  assert_eq(at(decoded, "commands").array_length(), 2) // Chrome + asset, no puzzle under transparent PNG.
  if at(decoded, "commands") is Array(commands) {
    assert_eq(at(commands[1], "assetId"), Json("plugin-icon-0"))
  }
  let frame = @frame.open(toolbar_frame_json(state, false))
  assert_true(frame > 0)
  assert_eq(@frame.close(frame), 1)
}
