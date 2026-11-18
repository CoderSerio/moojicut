///|
fn begin(field_id : String, initial : String, maximum : Int32) -> Int32 {
  open(field_id, initial, maximum, Directed(initial.length(), initial.length()))
}

///|
fn current(token : Int32) -> Snapshot {
  match snapshot(token) {
    Some(value) => value
    None => abort("expected a live field")
  }
}

///|
fn edit(token : Int32, event : Edit) -> Bool {
  let value = current(token)
  apply(token, value.field_id, value.version, event)
}

///|
test "raw intermediate text is preserved and stale callbacks cannot change a draft" {
  let token = begin("stroke.width", "", 100)
  assert_true(token > 0)
  let initial = current(token)
  assert_true(edit(token, Replace(0, 0, "-", Directed(1, 1))))
  assert_true(edit(token, Replace(0, 1, "1.", Directed(2, 0))))
  assert_eq(current(token).raw, "1.")
  assert_eq((current(token).anchor, current(token).focus), (2, 0))
  let before = current(token)
  assert_false(
    apply(token, "stroke.width", initial.version, Select(Directed(0, 0))),
  )
  assert_false(
    apply(token, "other.field", before.version, Select(Directed(0, 0))),
  )
  assert_false(
    apply(-1, "stroke.width", before.version, Select(Directed(0, 0))),
  )
  assert_eq(current(token), before)
  assert_eq(initial.raw, "")
  assert_eq(initial.version, 0)
  assert_true(edit(token, Replace(0, 2, "not a number\n ", Directed(0, 0))))
  assert_eq(current(token).raw, "not a number\n ")
  assert_true(edit(token, Undo))
  assert_eq(current(token).raw, "1.")
  assert_eq((current(token).anchor, current(token).focus), (2, 0))
  assert_true(current(token).version > before.version)
  assert_false(
    apply(token, before.field_id, before.version, Select(Directed(0, 0))),
  )
  assert_true(close(token))
  assert_eq(before.raw, "1.")
  assert_eq(snapshot(token), None)
}

///|
test "UTF16 edits reject split surrogate pairs and malformed native text atomically" {
  let token = begin("caption", "A🌙B", 20)
  let before = current(token)
  assert_eq(before.raw.length(), 4)
  let high_only = "🌙".unsafe_substring(start=0, end=1)
  let low_only = "🌙".unsafe_substring(start=1, end=2)
  for
    event in [
      Select(Directed(2, 2)),
      Select(Directed(-1, 0)),
      Select(Directed(0, 2147483647)),
      Replace(1, 2, "x", Directed(2, 2)),
      Replace(2, 3, "x", Directed(2, 2)),
      Replace(3, 1, "", Directed(0, 0)),
      Replace(0, 2147483647, "", Directed(0, 0)),
      Replace(0, 0, high_only, Directed(0, 0)),
      Replace(0, 0, low_only, Directed(0, 0)),
      Replace(0, 0, "🌙", Directed(1, 1)),
      CompositionStart(1, 2, Directed(1, 2)),
    ] {
    assert_false(edit(token, event))
    assert_eq(current(token), before)
  }
  assert_eq(begin("invalid", high_only, 20), 0)
  assert_eq(begin(low_only, "", 20), 0)
  assert_true(edit(token, Select(Directed(3, 1))))
  assert_true(edit(token, Replace(1, 3, "字\n🌙", Directed(5, 1))))
  assert_eq(current(token).raw, "A字\n🌙B")
  assert_true(edit(token, Undo))
  assert_eq(current(token).raw, "A🌙B")
  assert_eq((current(token).anchor, current(token).focus), (3, 1))
  assert_true(close(token))
}

///|
test "IME composition survives frame reads and cancellation restores text selection and redo" {
  let token = begin("caption", "before", 100)
  assert_true(edit(token, Select(Directed(4, 1))))
  assert_true(edit(token, Replace(1, 4, "X", Directed(2, 2))))
  assert_true(edit(token, Undo))
  let before = current(token)
  assert_true(before.can_redo)
  assert_true(edit(token, CompositionStart(1, 4, Directed(1, 4))))
  assert_true(edit(token, CompositionUpdate("ni", Directed(3, 3))))
  assert_eq(current(token).raw, "bnire")
  let marked = current(token)
  assert_eq(marked.marked, Some((1, 3)))
  assert_false(marked.can_undo)
  assert_false(marked.can_redo)
  // A renderer only reads detached snapshots; refreshes do not replace IME text.
  for _ in 0..<20 {
    assert_eq(current(token), marked)
  }
  for
    event in [
      Undo,
      Redo,
      Replace(1, 3, "x", Directed(2, 2)),
      Select(Directed(0, 0)),
      CompositionStart(1, 3, Directed(1, 3)),
      CompositionUpdate("好", Directed(0, 0)),
      CompositionUpdate("🌙", Directed(2, 2)),
    ] {
    assert_false(edit(token, event))
    assert_eq(current(token), marked)
  }
  assert_true(edit(token, CompositionUpdate("你🌙", Directed(4, 1))))
  assert_eq(current(token).raw, "b你🌙re")
  assert_true(edit(token, Select(Directed(1, 4))))
  assert_true(edit(token, CompositionCancel))
  let cancelled = current(token)
  assert_eq(cancelled.raw, before.raw)
  assert_eq((cancelled.anchor, cancelled.focus), (before.anchor, before.focus))
  assert_eq(cancelled.marked, None)
  assert_true(cancelled.can_redo)
  assert_true(cancelled.version > marked.version)
  assert_false(
    apply(
      token,
      "caption",
      marked.version,
      CompositionUpdate("late", Directed(5, 5)),
    ),
  )
  assert_eq(current(token), cancelled)
  assert_true(edit(token, Redo))
  assert_eq(current(token).raw, "bXre")
  assert_true(close(token))
}

///|
test "composition confirmation is one draft undo step with final selection and multiline text" {
  let token = begin("caption", "A B", 100)
  assert_true(edit(token, Select(Directed(2, 1))))
  let initial = current(token)
  assert_true(edit(token, CompositionStart(1, 2, Directed(1, 2))))
  assert_true(edit(token, CompositionUpdate("n", Directed(2, 2))))
  assert_true(edit(token, CompositionUpdate("nihao", Directed(6, 6))))
  assert_true(edit(token, CompositionCommit("你好\n🌙", Directed(7, 0))))
  let confirmed = current(token)
  assert_eq(confirmed.raw, "A你好\n🌙B")
  assert_eq(confirmed.marked, None)
  assert_true(edit(token, Undo))
  assert_eq(current(token).raw, initial.raw)
  assert_eq((current(token).anchor, current(token).focus), (2, 1))
  assert_false(current(token).can_undo)
  assert_true(current(token).version > confirmed.version)
  assert_true(edit(token, Redo))
  assert_eq(current(token).raw, confirmed.raw)
  assert_eq((current(token).anchor, current(token).focus), (7, 0))
  let before = current(token)
  assert_false(edit(token, CompositionCommit("late", Directed(0, 0))))
  assert_false(edit(token, CompositionCancel))
  assert_false(edit(token, CompositionUpdate("late", Directed(0, 0))))
  assert_eq(current(token), before)
  assert_true(close(token))
}

///|
test "selection and no-op composition preserve redo while a new edit replaces that branch" {
  let token = begin("caption", "a", 100)
  assert_true(edit(token, Replace(1, 1, "b", Directed(2, 2))))
  assert_true(edit(token, Undo))
  assert_true(edit(token, Select(Directed(0, 1))))
  assert_true(edit(token, Replace(0, 1, "a", Directed(1, 0))))
  assert_true(edit(token, CompositionStart(0, 1, Directed(0, 1))))
  assert_true(edit(token, CompositionUpdate("temporary", Directed(9, 9))))
  assert_true(edit(token, CompositionCommit("a", Directed(0, 0))))
  assert_false(current(token).can_undo)
  assert_true(current(token).can_redo)
  assert_true(edit(token, Redo))
  assert_eq(current(token).raw, "ab")
  assert_true(edit(token, Undo))
  assert_eq((current(token).anchor, current(token).focus), (0, 0))
  assert_true(edit(token, Replace(0, 1, "c", Directed(1, 1))))
  assert_false(current(token).can_redo)
  assert_false(edit(token, Redo))
  assert_true(close(token))
}

///|
test "field lifecycle invalidates old edits and keeps independent owners and snapshots" {
  let first = begin("same.field", "first", 100)
  let retained = current(first)
  assert_true(edit(first, CompositionStart(0, 5, Directed(0, 5))))
  assert_true(close(first))
  assert_false(close(first))
  let handles : Array[Int32] = []
  for _ in 0..<64 {
    let token = begin("same.field", "second", 100)
    assert_true(token > first)
    handles.push(token)
  }
  assert_eq(begin("overflow", "", 100), 0)
  assert_true(edit(handles[0], Replace(0, 6, "changed", Directed(7, 7))))
  assert_eq(current(handles[1]).raw, "second")
  assert_false(
    apply(
      first,
      "same.field",
      retained.version,
      Replace(0, 5, "late", Directed(0, 0)),
    ),
  )
  assert_eq(retained.raw, "first")
  for token in handles {
    assert_true(close(token))
  }
  assert_eq(snapshot(first), None)
  let reopened = begin("same.field", "", 100)
  assert_true(reopened > handles[63])
  assert_true(close(reopened))
}

///|
test "caller text limit applies to replacement and composition without imposing value policy" {
  assert_eq(begin("", "", 100), 0)
  assert_eq(begin("x".repeat(257), "", 100), 0)
  assert_eq(begin("x", "", 0), 0)
  assert_eq(begin("x", "", 32769), 0)
  assert_eq(begin("x", "12345", 4), 0)
  let token = begin("bounded", "A🌙", 4)
  assert_true(edit(token, Replace(3, 3, "B", Directed(4, 4))))
  let full = current(token)
  assert_false(edit(token, Replace(4, 4, "!", Directed(5, 5))))
  assert_eq(current(token), full)
  assert_true(edit(token, CompositionStart(1, 3, Directed(1, 3))))
  let before = current(token)
  assert_false(edit(token, CompositionUpdate("abc", Directed(4, 4))))
  assert_false(edit(token, CompositionCommit("abc", Directed(4, 4))))
  assert_eq(current(token), before)
  assert_true(edit(token, CompositionUpdate("", Directed(1, 1))))
  assert_eq(current(token).marked, Some((1, 1)))
  assert_true(edit(token, CompositionCommit("🌙", Directed(3, 3))))
  assert_eq(current(token).raw, "A🌙B")
  assert_true(close(token))
}

///|
test "bounded draft history retains recent changes and versions never wrap" {
  let token = begin("history", "", 100)
  for i in 0..<40 {
    assert_true(edit(token, Replace(i, i, "x", Directed(i + 1, i + 1))))
  }
  for _ in 0..<32 {
    assert_true(edit(token, Undo))
  }
  assert_eq(current(token).raw.length(), 8)
  let oldest = current(token)
  assert_false(edit(token, Undo))
  assert_eq(current(token), oldest)
  for _ in 0..<32 {
    assert_true(edit(token, Redo))
  }
  assert_eq(current(token).raw.length(), 40)
  assert_true(close(token))
  let large = begin("history.large", "a".repeat(32768), 32768)
  for _ in 0..<10 {
    assert_true(edit(large, Replace(0, 1, "b", Directed(1, 1))))
    assert_true(edit(large, Replace(0, 1, "a", Directed(1, 1))))
  }
  for _ in 0..<4 {
    assert_true(edit(large, Undo))
  }
  assert_false(edit(large, Undo))
  assert_true(edit(large, Redo))
  assert_true(close(large))
  let exhausted = begin("version", "", 10)
  fields[exhausted].version = 2147483646
  assert_true(edit(exhausted, Select(Directed(0, 0))))
  let maximum = current(exhausted)
  assert_eq(maximum.version, 2147483647)
  assert_false(edit(exhausted, Replace(0, 0, "x", Directed(1, 1))))
  assert_eq(current(exhausted), maximum)
  assert_true(close(exhausted))
}

///|
test "native selection uncertainty survives composition history and snapshot refresh" {
  // Win EDIT exposes ordered EM_GETSEL bounds but not selection direction.
  let token = open("caption", "A🌙B", 100, Undirected(1, 3))
  assert_true(token > 0)
  let before = current(token)
  assert_true(before.selection_known)
  assert_false(before.direction_known)
  assert_eq((before.anchor, before.focus), (1, 3))
  for invalid in [Undirected(3, 1), Undirected(1, 2), Directed(2, 3)] {
    assert_false(edit(token, Select(invalid)))
    assert_eq(current(token), before)
    assert_eq(open("bad.range", "A🌙B", 100, invalid), 0)
  }
  // GTK preedit text may arrive with no observable preedit caret. Zero below
  // is only a placeholder: bridges must consult selection_known before using it.
  assert_true(edit(token, CompositionStart(1, 3, Unknown)))
  assert_true(edit(token, CompositionUpdate("ni", Unknown)))
  let composing = current(token)
  assert_eq(composing.raw, "AniB")
  assert_eq(composing.marked, Some((1, 3)))
  assert_false(composing.selection_known)
  assert_false(composing.direction_known)
  assert_eq((composing.anchor, composing.focus), (0, 0))
  assert_eq(current(token), composing)
  assert_true(edit(token, CompositionCancel))
  assert_eq(current(token).raw, before.raw)
  assert_eq((current(token).anchor, current(token).focus), (1, 3))
  assert_true(current(token).selection_known)
  assert_false(current(token).direction_known)
  assert_true(edit(token, CompositionStart(1, 3, Unknown)))
  assert_true(edit(token, CompositionCommit("你", Unknown)))
  let committed = current(token)
  assert_false(committed.selection_known)
  assert_true(edit(token, Undo))
  assert_true(current(token).selection_known)
  assert_false(current(token).direction_known)
  assert_eq((current(token).anchor, current(token).focus), (1, 3))
  assert_true(edit(token, Redo))
  assert_eq(current(token).raw, "A你B")
  assert_false(current(token).selection_known)
  assert_false(current(token).direction_known)
  assert_true(edit(token, Select(Directed(2, 1))))
  assert_true(current(token).selection_known)
  assert_true(current(token).direction_known)
  assert_eq((current(token).anchor, current(token).focus), (2, 1))
  assert_true(close(token))
  let unknown = open("unknown.initial", "🌙", 10, Unknown)
  assert_true(unknown > token)
  assert_false(current(unknown).selection_known)
  assert_true(edit(unknown, Replace(0, 2, "字", Unknown)))
  assert_true(edit(unknown, Undo))
  assert_false(current(unknown).selection_known)
  assert_true(close(unknown))
}
