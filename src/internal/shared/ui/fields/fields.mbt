///|
/// Observed or explicitly requested selection. Native bridges must not invent
/// direction or caret offsets when their input API does not expose them.
/// Undirected contains ordered range bounds; Directed preserves anchor/focus.
/// Unknown offsets in a Snapshot are placeholders and must not set native caret.
pub(all) enum Selection {
  Directed(Int32, Int32)
  Undirected(Int32, Int32)
  Unknown
}

///|
/// Ephemeral text only: no numeric parsing, whitespace policy or document undo.
/// Every position is a UTF-16 code-unit offset; range ends are exclusive.
/// Replace(start, end, text, selection) gives the replacement range in the
/// old draft and the desired selection in the resulting draft. Select uses
/// absolute offsets. CompositionStart(start, end, selection) marks a range in
/// the current draft; Update/Commit(text, selection) use absolute selection
/// offsets in the resulting draft, not inside `text`. Unknown is retained.
/// Replace is one draft undo step. While composing, Replace/Undo/Redo reject;
/// Select is confined to the marked range. CompositionUpdate replaces that
/// range and keeps selection inside it. CompositionCommit replaces the marked
/// range with final text and confirms composition into the draft, NOT into a
/// document. All updates in one composition form at most one draft undo step.
/// CompositionCancel restores the complete pre-composition text and selection.
pub(all) enum Edit {
  Replace(Int32, Int32, String, Selection)
  Select(Selection)
  CompositionStart(Int32, Int32, Selection)
  CompositionUpdate(String, Selection)
  CompositionCommit(String, Selection)
  CompositionCancel
  Undo
  Redo
}

///|
/// Detached immutable view. Reading it (including a frame refresh) never
/// updates the draft. Retained snapshots survive subsequent edits and close.
/// anchor/focus preserve selection direction; marked is (start, exclusive end).
/// When selection_known=false, anchor/focus are zero placeholders. When only
/// direction_known=false, anchor/focus are ordered bounds, not a direction.
/// can_undo/can_redo are false while composing, even if history exists.
#derive(Eq, Debug)
pub struct Snapshot {
  field_id : String
  token : Int32
  version : Int32
  raw : String
  anchor : Int32
  focus : Int32
  selection_known : Bool
  direction_known : Bool
  marked : (Int32, Int32)?
  can_undo : Bool
  can_redo : Bool
}

///|
pub extend Snapshot with Eq::{equal, not_equal}

///|
pub extend Snapshot with @debug.Debug::{to_repr}

///|
priv struct TextState {
  raw : String
  selection : Selection
}

///|
priv struct Composition {
  before : TextState
  start : Int32
  end : Int32
}

///|
priv struct Field {
  field_id : String
  maximum : Int32
  mut version : Int32
  mut state : TextState
  mut composition : Composition?
  undo : Array[TextState]
  redo : Array[TextState]
}

///|
let fields : Map[Int32, Field] = Map([])

///|
let next_token : Ref[Int32] = Ref(1)

///|
fn high(unit : UInt16) -> Bool {
  unit >= 0xd800 && unit <= 0xdbff
}

///|
fn low(unit : UInt16) -> Bool {
  unit >= 0xdc00 && unit <= 0xdfff
}

///|
// Do not use a code-point iterator: untrusted native strings may contain a lone
// surrogate, which must reject instead of aborting during decoding.

///|
/// Pure bounded UTF-16 validation for bridges and frame decoders. Rejects lone
/// surrogates without using a code-point iterator that could abort on them.
pub fn valid_text(text : String, maximum : Int32) -> Bool {
  if text.length() > maximum {
    return false
  }
  let units = text.code_units()
  let mut i = 0
  while i < units.length() {
    if high(units[i]) {
      if i + 1 == units.length() || !low(units[i + 1]) {
        return false
      }
      i += 2
    } else {
      if low(units[i]) {
        return false
      }
      i += 1
    }
  }
  true
}

///|
/// Pure offset check for already validated UTF-16 text. Call valid_text first
/// for untrusted strings; a valid boundary never splits a surrogate pair.
pub fn boundary(text : String, offset : Int32) -> Bool {
  if offset < 0 || offset > text.length() {
    return false
  }
  offset == 0 || offset == text.length() || !low(text.code_units()[offset])
}

///|
fn valid_range(text : String, start : Int32, end : Int32) -> Bool {
  start <= end && boundary(text, start) && boundary(text, end)
}

///|
fn valid_selection(text : String, selection : Selection) -> Bool {
  match selection {
    Directed(anchor, focus) => boundary(text, anchor) && boundary(text, focus)
    Undirected(start, end) => valid_range(text, start, end)
    Unknown => true
  }
}

///|
fn selection_within(selection : Selection, start : Int32, end : Int32) -> Bool {
  match selection {
    Directed(a, f) | Undirected(a, f) =>
      a >= start && a <= end && f >= start && f <= end
    Unknown => true
  }
}

///|
fn replace_state(
  field : Field,
  start : Int32,
  end : Int32,
  text : String,
  selection : Selection,
) -> TextState? {
  let raw = field.state.raw
  if !valid_range(raw, start, end) || !valid_text(text, field.maximum) {
    return None
  }
  // All lengths are now bounded before doing arithmetic or allocation.
  if raw.length() - (end - start) + text.length() > field.maximum {
    return None
  }
  let changed = raw[:start].to_owned() + text + raw[end:].to_owned()
  if !valid_selection(changed, selection) {
    return None
  }
  Some({ raw: changed, selection, })
}

///|
// Per lane: <=32 snapshots and <=131072 UTF-16 code units. Trim the oldest
// entries, retaining the most recent undo/redo even for a maximum-sized field.
fn remember(history : Array[TextState], state : TextState) -> Unit {
  history.push(state)
  let mut size = 0
  for item in history {
    size += item.raw.length()
  }
  while history.length() > 32 || size > 131072 {
    size -= history[0].raw.length()
    ignore(history.remove(0))
  }
}

///|
fn accept_text(field : Field, before : TextState, after : TextState) -> Unit {
  if before.raw != after.raw {
    remember(field.undo, before)
    field.redo.clear()
  }
  field.state = after
}

///|
/// Begin an independent field edit with explicit initial selection metadata.
/// Returns a positive,
/// never-reused edit token, or 0 on invalid input/exhaustion. field_id is a
/// nonempty valid UTF-16 string <=256 units; maximum is supplied by the caller,
/// 1..32768 units. Empty/raw intermediate values are allowed. At most 64 live
/// edits. Same field ID may exist in different owners; token disambiguates it.
/// Each undo/redo lane retains at most 32 states and 131072 UTF-16 units,
/// discarding the oldest states first. These bounds concern draft resources,
/// not the owner's document history or domain value validation.
/// There is deliberately no frame-sync/set-value method: reopen explicitly to
/// replace an edit, retiring its old token. Calls belong to the owning UI thread.
pub fn open(
  field_id : String,
  initial : String,
  maximum : Int32,
  selection : Selection,
) -> Int32 {
  if maximum < 1 ||
    maximum > 32768 ||
    field_id.is_empty() ||
    !valid_text(field_id, 256) ||
    !valid_text(initial, maximum) ||
    !valid_selection(initial, selection) ||
    fields.length() >= 64 ||
    next_token.val >= 2147483647 {
    return 0
  }
  let token = next_token.val
  next_token.val += 1
  fields[token] = {
    field_id,
    maximum,
    version: 0,
    state: { raw: initial, selection, },
    composition: None,
    undo: [],
    redo: [],
  }
  token
}

///|
pub fn snapshot(token : Int32) -> Snapshot? {
  let field = match fields.get(token) {
    Some(f) => f
    None => return None
  }
  let (anchor, focus) = match field.state.selection {
    Directed(a, f) | Undirected(a, f) => (a, f)
    Unknown => (0, 0)
  }
  Some({
    field_id: field.field_id,
    token,
    version: field.version,
    raw: field.state.raw,
    anchor,
    focus,
    selection_known: !(field.state.selection is Unknown),
    direction_known: field.state.selection is Directed(_, _),
    marked: field.composition.map(c => (c.start, c.end)),
    can_undo: field.composition is None && !field.undo.is_empty(),
    can_redo: field.composition is None && !field.redo.is_empty(),
  })
}

///|
/// Apply only to the exact field/token/version. Rejection is atomic, including
/// history and composition. Every accepted event advances version, even a
/// text/selection no-op; versions never rewind through undo or composition
/// cancellation. Empty undo/redo and version exhaustion reject. Selection-only
/// changes and unchanged text do not add undo steps or destroy redo.
pub fn apply(
  token : Int32,
  field_id : String,
  version : Int32,
  edit : Edit,
) -> Bool {
  let field = match fields.get(token) {
    Some(f) => f
    None => return false
  }
  if field.field_id != field_id ||
    field.version != version ||
    version >= 2147483647 {
    return false
  }
  match edit {
    Replace(start, end, text, selection) => {
      if field.composition is Some(_) {
        return false
      }
      let next = match replace_state(field, start, end, text, selection) {
        Some(next) => next
        None => return false
      }
      accept_text(field, field.state, next)
    }
    Select(selection) => {
      if !valid_selection(field.state.raw, selection) {
        return false
      }
      if field.composition is Some(c) {
        if !selection_within(selection, c.start, c.end) {
          return false
        }
      }
      field.state = { raw: field.state.raw, selection, }
    }
    CompositionStart(start, end, selection) => {
      if field.composition is Some(_) ||
        !valid_range(field.state.raw, start, end) ||
        !valid_selection(field.state.raw, selection) ||
        !selection_within(selection, start, end) {
        return false
      }
      field.composition = Some({ before: field.state, start, end, })
      field.state = { raw: field.state.raw, selection, }
    }
    CompositionUpdate(text, selection) => {
      let c = match field.composition {
        Some(c) => c
        None => return false
      }
      let next = match replace_state(field, c.start, c.end, text, selection) {
        Some(next) => next
        None => return false
      }
      let end = c.start + text.length()
      if !selection_within(selection, c.start, end) {
        return false
      }
      field.state = next
      field.composition = Some({ before: c.before, start: c.start, end, })
    }
    CompositionCommit(text, selection) => {
      let c = match field.composition {
        Some(c) => c
        None => return false
      }
      let next = match replace_state(field, c.start, c.end, text, selection) {
        Some(next) => next
        None => return false
      }
      accept_text(field, c.before, next)
      field.composition = None
    }
    CompositionCancel => {
      let c = match field.composition {
        Some(c) => c
        None => return false
      }
      field.state = c.before
      field.composition = None
    }
    Undo | Redo as action => {
      if field.composition is Some(_) {
        return false
      }
      let from = if action is Undo { field.undo } else { field.redo }
      let to = if action is Undo { field.redo } else { field.undo }
      let previous = match from.pop() {
        Some(value) => value
        None => return false
      }
      remember(to, field.state)
      field.state = previous
    }
  }
  field.version += 1
  true
}

///|
/// Retire the edit and discard all ephemeral state, including active composition.
/// This does not commit or cancel any owner document. Returns false if retired.
pub fn close(token : Int32) -> Bool {
  if !fields.contains(token) {
    return false
  }
  fields.remove(token)
  true
}
