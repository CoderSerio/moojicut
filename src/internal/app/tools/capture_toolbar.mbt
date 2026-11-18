///|
fn capture_entries(
  snapshot : Int32,
) -> Array[@capture.CaptureToolbarContribution]? {
  // A closed/forged integer cannot supply descriptors. Read-only queries copy
  // only normalized executable entries from the verified catalog owner.
  if @catalog.snapshot_layout(snapshot) == "" {
    return None
  }
  let result : Array[@capture.CaptureToolbarContribution] = []
  let count = @catalog.snapshot_count(snapshot, 0)
  if count < 0 || count > 512 {
    return None
  }
  for i in 0..<count {
    result.push({
      id: @catalog.snapshot_text(snapshot, 0, i, 0),
      title: @catalog.snapshot_text(snapshot, 0, i, 2),
      icon: @catalog.snapshot_text(snapshot, 0, i, 3),
      command: @catalog.snapshot_text(snapshot, 0, i, 4),
      payload: @catalog.snapshot_text(snapshot, 0, i, 6),
      reason: @catalog.snapshot_text(snapshot, 0, i, 7),
      slot: @catalog.snapshot_value(snapshot, 0, i, 2),
      kind: @catalog.snapshot_value(snapshot, 0, i, 3),
      interaction: @catalog.snapshot_value(snapshot, 0, i, 5),
      capability: @catalog.snapshot_value(snapshot, 0, i, 7),
      enabled: @catalog.snapshot_value(snapshot, 0, i, 0) == 1,
      available: @catalog.snapshot_value(snapshot, 0, i, 1) == 1,
    })
  }
  Some(result)
}

///|
pub fn capture_toolbar_open(
  image : Int32,
  style : Int32,
  snapshot : Int32,
) -> Int32 {
  match capture_entries(snapshot) {
    Some(entries) => @capture.toolbar_open(image, style, entries)
    None => 0
  }
}

///|
pub fn capture_toolbar_config_prepare(
  handle : Int32,
  snapshot : Int32,
) -> Int32 {
  match capture_entries(snapshot) {
    Some(entries) => @capture.toolbar_config_prepare(handle, entries)
    None => 0
  }
}
