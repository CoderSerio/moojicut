///|
using @json {type Json}

///|
using @protocol {type InputError}

///|
// Keys are opaque platform key IDs. The adapter resolves keyboard layouts and
// aliases; policy uses the same Control/Alt/Shift/Super bits as shortcut_validate.
fn binding(value : Json, requires_modifier : Bool) -> Json? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let key = @protocol.integer_field(fields, "keyCode", 0, 65535) catch {
    _ => return None
  }
  let flags = @protocol.integer_field(fields, "modifiers", 0, 15) catch {
    _ => return None
  }
  if shortcut_modifiers_allowed(
      flags.to_int(),
      if requires_modifier {
        1
      } else {
        0
      },
    ) ==
    0 {
    return None
  }
  let label = match fields.get("keyLabel") {
    Some(String(label)) if label.length() > 0 && label.length() <= 16 => label
    _ => return None
  }
  Some(
    Json::object({
      "keyCode": Json(key),
      "modifiers": Json(flags),
      "keyLabel": Json(label),
    }),
  )
}

///|
fn same_binding(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Object(a), Object(b)) =>
      a.get("keyCode") == b.get("keyCode") &&
      a.get("modifiers") == b.get("modifiers")
    _ => false
  }
}

///|
fn action_list(
  fields : Map[String, Json],
  name : String,
) -> Array[String] raise InputError {
  let values = match fields.get(name) {
    Some(Array(values)) if values.length() <= 32 => values
    _ => raise InputError("invalid_input", "Expected a bounded action list")
  }
  let actions : Array[String] = []
  for value in values {
    match value {
      String(id) if id.length() > 0 &&
        id.length() <= 80 &&
        !actions.contains(id) => actions.push(id)
      _ =>
        raise InputError("invalid_input", "Expected unique action identifiers")
    }
  }
  actions
}

///|
// Stateless preference reducer. Missing/invalid saved values fall back to the
// supplied platform defaults; explicit null stays disabled. First action wins
// if old/corrupt preferences contain duplicates. An edit is all-or-nothing.
pub fn shortcut_bindings_resolve(request_json : String) -> String {
  @protocol.response(() => {
    let request = @protocol.request_object(request_json)
    let order = action_list(request, "order")
    let global = action_list(request, "global")
    for action in global {
      if !order.contains(action) {
        raise InputError("invalid_input", "Unknown global action")
      }
    }
    let defaults = @protocol.object_field(request, "defaults")
    let saved = @protocol.object_field(request, "saved")
    let result : Map[String, Json] = Map([])
    let seen : Array[Json] = []
    for action in order {
      let fallback = match defaults.get(action) {
        Some(value) =>
          match binding(value, global.contains(action)) {
            Some(valid) => valid
            None =>
              raise InputError("invalid_input", "Invalid platform default")
          }
        None => raise InputError("invalid_input", "Missing platform default")
      }
      let value = match saved.get(action) {
        Some(Null) => Json::null()
        Some(value) =>
          binding(value, global.contains(action)).unwrap_or(fallback)
        None => fallback
      }
      if value != Json::null() &&
        seen.any(fn(prior) { same_binding(prior, value) }) {
        result[action] = Json::null()
      } else {
        result[action] = value
        if value != Json::null() {
          seen.push(value)
        }
      }
    }
    match request.get("command") {
      Some(Object(command)) => {
        let action = match command.get("action") {
          Some(String(action)) if order.contains(action) => action
          _ => raise InputError("unknown_action", "Unknown shortcut action")
        }
        let value = match command.get("binding") {
          Some(Null) => Json::null()
          Some(value) =>
            match binding(value, global.contains(action)) {
              Some(valid) => valid
              None => raise InputError("invalid_shortcut", "Invalid shortcut")
            }
          None => raise InputError("invalid_shortcut", "Missing shortcut")
        }
        if value != Json::null() {
          for other in order {
            if other != action && same_binding(result[other], value) {
              raise InputError("duplicate", other)
            }
          }
          if global.contains(action) {
            match request.get("external") {
              Some(Object(external)) =>
                for other, candidate in external {
                  if same_binding(candidate, value) {
                    raise InputError("external_duplicate", other)
                  }
                }
              None => ()
              _ =>
                raise InputError("invalid_input", "Invalid external bindings")
            }
          }
        }
        result[action] = value
      }
      None => ()
      _ => raise InputError("invalid_input", "Invalid shortcut command")
    }
    Json::object({ "ok": Json(true), "bindings": Json::object(result) })
  })
}
