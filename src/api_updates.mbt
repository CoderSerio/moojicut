// Native ABI entry points. Release parsing, selection, and handles live in
// internal/updates. Inputs remain caller-owned; returned strings are owned.

///|
#export_name("update_version_compare")
pub fn update_version_compare(left : String, right : String) -> Int {
  @updates.update_version_compare(left, right)
}

///|
#export_name("update_release_create")
pub fn update_release_create(current : String, platform : Int, body : String) -> Int {
  @updates.update_release_create(current, platform, body)
}

///|
#export_name("update_release_status")
pub fn update_release_status(handle : Int) -> Int {
  @updates.update_release_status(handle)
}

///|
#export_name("update_release_text")
pub fn update_release_text(handle : Int, field : Int) -> String {
  @updates.update_release_text(handle, field)
}

///|
#export_name("update_release_size")
pub fn update_release_size(handle : Int) -> Int {
  @updates.update_release_size(handle)
}

///|
#export_name("update_release_dispose")
pub fn update_release_dispose(handle : Int) -> Unit {
  @updates.update_release_dispose(handle)
}
