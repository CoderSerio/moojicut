///|
fn update_fixture_asset(version : String, suffix : String) -> Json {
  let name = "moojicut-" + version + "-" + suffix
  Json::object({
    "name": Json(name), "state": Json("uploaded"), "size": Json(1234),
    "digest": Json("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
    "browser_download_url": Json("https://github.com/CoderSerio/moojicut/releases/download/v" + version + "/" + name),
  })
}

///|
fn update_fixture_release(version : String, preview : Bool, draft~ : Bool = false, assets? : Array[Json]) -> Json {
  Json::object({
    "tag_name": Json("v" + version), "draft": Json(draft), "prerelease": Json(preview),
    "published_at": Json("2026-11-15T00:00:00Z"),
    "html_url": Json("https://github.com/CoderSerio/moojicut/releases/tag/v" + version),
    "assets": Json::array(assets.unwrap_or_else(() => [
      update_fixture_asset(version, "windows-x64.zip"),
      update_fixture_asset(version, "linux-x64.tar.gz"),
      update_fixture_asset(version, "macos-arm64.zip"),
    ])),
  })
}

///|
test "update versions use numeric preview ordering and reject unsupported labels" {
  let ordered = ["0.1.0-alpha.9", "0.1.0-alpha.10", "0.1.0-beta.1", "0.1.0-rc.1", "0.1.0", "0.1.1-alpha.1", "1.0.0"]
  for i in 0..<ordered.length() {
    for j in 0..<ordered.length() {
      assert_eq(update_version_compare(ordered[i], ordered[j]), if i < j { -1 } else if i > j { 1 } else { 0 })
    }
  }
  assert_eq(update_version_compare("v0.1.0-alpha.9", "0.1.0-alpha.9"), 0)
  for invalid in ["development", "0.1", "0.01.0", "0.1.0-alpha.0", "0.1.0-alpha.01", "0.1.0-alpha.1/evil", "999999999999.0.0", "-1.0.0"] {
    assert_eq(update_version_compare(invalid, "0.1.0"), 2)
  }
}

///|
test "release selection includes previews only for preview installs and skips drafts" {
  let body = Json::array([
    update_fixture_release("9.0.0", false, draft=true),
    update_fixture_release("0.1.0-alpha.10", true),
    update_fixture_release("0.0.9", false),
    update_fixture_release("0.1.0-alpha.9", true),
  ]).stringify()
  let preview = update_release_create("0.1.0-alpha.9", 1, body)
  assert_eq(update_release_status(preview), 1)
  assert_eq(update_release_text(preview, 0), "0.1.0-alpha.10")
  assert_eq(update_release_size(preview), 1234)
  assert_eq(update_release_text(preview, 2), "moojicut-0.1.0-alpha.10-windows-x64.zip")
  let stable = update_release_create("0.0.8", 2, body)
  assert_eq(update_release_status(stable), 1)
  assert_eq(update_release_text(stable, 0), "0.0.9")
  assert_eq(update_release_text(stable, 2), "moojicut-0.0.9-linux-x64.tar.gz")
  update_release_dispose(preview)
  update_release_dispose(stable)
}

///|
test "equal and older releases never downgrade and each result has independent lifetime" {
  let body = Json::array([update_fixture_release("0.1.0-alpha.9", true)]).stringify()
  let same = update_release_create("0.1.0-alpha.9", 0, body)
  let newer = update_release_create("0.1.0-alpha.10", 0, body)
  let older = update_release_create("0.1.0-alpha.8", 0, body)
  assert_eq(update_release_status(same), 0)
  assert_eq(update_release_status(newer), 0)
  assert_eq(update_release_status(older), 1)
  update_release_dispose(same)
  assert_eq(update_release_status(same), -1)
  assert_eq(update_release_status(older), 1)
  assert_eq(update_release_text(same, 1), "")
  update_release_dispose(same)
  update_release_dispose(newer)
  update_release_dispose(older)
}

///|
test "newer releases without an exact verified platform package are incomplete" {
  for bad in ["foreign", "digest", "oversize", "fraction", "state", "missing", "duplicate"] {
    let asset = match update_fixture_asset("0.1.0-alpha.10", "windows-x64.zip") { Object(a) => a; _ => abort("fixture") }
    match bad {
      "foreign" => asset["browser_download_url"] = Json("https://example.invalid/moojicut.zip")
      "digest" => asset["digest"] = Json("sha256:not-a-hash")
      "oversize" => asset["size"] = Json(1073741825)
      "fraction" => asset["size"] = Json(1234.5)
      "state" => asset["state"] = Json("new")
      _ => ()
    }
    let assets = if bad == "missing" { [] } else if bad == "duplicate" {
      [Json::object(asset), Json::object(asset)]
    } else { [Json::object(asset)] }
    let body = Json::array([update_fixture_release("0.1.0-alpha.10", true, assets~)]).stringify()
    let handle = update_release_create("0.1.0-alpha.9", 1, body)
    assert_eq(update_release_status(handle), 2)
    assert_eq(update_release_text(handle, 1), "")
    update_release_dispose(handle)
  }
}

///|
test "signed macOS feed is discovered as an asset without treating checksum as signature" {
  let version = "0.1.0-alpha.10"
  let feed = Json::object({
    "name": Json("macos.xml"), "state": Json("uploaded"), "size": Json(4096),
    "browser_download_url": Json("https://github.com/CoderSerio/moojicut/releases/download/v" + version + "/macos.xml"),
  })
  let body = Json::array([update_fixture_release(version, true, assets=[update_fixture_asset(version, "macos-arm64.zip"), feed])]).stringify()
  let handle = update_release_create("0.1.0-alpha.9", 0, body)
  assert_eq(update_release_status(handle), 1)
  assert_eq(update_release_text(handle, 4), "https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.10/macos.xml")
  update_release_dispose(handle)
}

///|
test "invalid API replies do not become current-version success and handles stay bounded" {
  for body in ["not json", "{}", "{\"message\":\"API rate limit exceeded\"}", "[{\"draft\":false,\"draft\":true}]", "[null]", "[{}]", "[{\"message\":\"bad payload\"}]"] {
    assert_eq(update_release_create("0.1.0-alpha.9", 0, body), 0)
  }
  assert_eq(update_release_create("development", 0, "[]"), 0)
  assert_eq(update_release_create("0.1.0-alpha.9", 9, "[]"), 0)
  let handles : Array[Int] = []
  for _ in 0..<16 {
    let handle = update_release_create("0.1.0-alpha.9", 0, "[]")
    assert_true(handle > 0)
    handles.push(handle)
  }
  assert_eq(update_release_create("0.1.0-alpha.9", 0, "[]"), 0)
  for handle in handles { update_release_dispose(handle) }
}
