import assert from "node:assert/strict";
import test from "node:test";
import worker from "./worker.mjs";

const name = "moojicut-0.1.0-alpha.22-windows-x64.zip";
const key = `v0.1.0-alpha.22/${name}`;
const bytes = Uint8Array.from({ length: 1027 }, (_, index) => index % 251);
const uploaded = new Date("2026-11-18T10:00:00.123Z");
const metadata = { size: bytes.length, etag: "test-etag", httpEtag: '"test-etag"', uploaded };

function bucketFixture(overrides = {}) {
  const calls = [];
  return {
    calls,
    env: { RELEASES: {
      async head(path) { calls.push(["head", path]); return path === key ? metadata : null; },
      async get(path, options) {
        calls.push(["get", path, options]);
        assert.equal(options.onlyIf.etagMatches, metadata.etag);
        const body = options.range ? bytes.slice(options.range.offset, options.range.offset + options.range.length) : bytes;
        return { ...metadata, body: new Response(body).body };
      },
      ...overrides,
    } },
  };
}
function request(fixture, init = {}, path = key) {
  return worker.fetch(new Request(`https://moojicut-downloads.pages.dev/${path}`, init), fixture.env);
}

test("full GET streams exact bytes with immutable attachment metadata", async () => {
  const fixture = bucketFixture();
  const response = await request(fixture);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-length"), String(bytes.length));
  assert.equal(response.headers.get("content-disposition"), `attachment; filename="${name}"`);
  assert.match(response.headers.get("cache-control"), /immutable/);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
});

test("HEAD does not fetch a body and ignores Range", async () => {
  const fixture = bucketFixture();
  const response = await request(fixture, { method: "HEAD", headers: { Range: "bytes=1-3" } });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-length"), String(bytes.length));
  assert.equal((await response.arrayBuffer()).byteLength, 0);
  assert.deepEqual(fixture.calls.map(([method]) => method), ["head"]);
});

test("single bounded, open-ended and suffix ranges preserve byte boundaries", async () => {
  for (const [range, start, end] of [["bytes=3-7", 3, 8], ["bytes=1000-", 1000, bytes.length], ["bytes=-9", bytes.length - 9, bytes.length]]) {
    const response = await request(bucketFixture(), { headers: { Range: range } });
    assert.equal(response.status, 206);
    assert.equal(response.headers.get("content-range"), `bytes ${start}-${end - 1}/${bytes.length}`);
    assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes.slice(start, end));
  }
});

test("invalid and unsatisfiable ranges do not fetch object bytes", async () => {
  for (const range of ["bytes=-0", "bytes=7-3", "bytes=9000-", "bytes=0-1,4-5", "bytes=9007199254740992-"]) {
    const fixture = bucketFixture();
    const response = await request(fixture, { headers: { Range: range } });
    assert.equal(response.status, 416);
    assert.equal(response.headers.get("content-range"), `bytes */${bytes.length}`);
    assert.equal(fixture.calls.length, 1);
  }
});

test("If-Range requires the exact strong ETag or Last-Modified date", async () => {
  const exactDate = uploaded.toUTCString();
  for (const value of [metadata.httpEtag, exactDate]) {
    const response = await request(bucketFixture(), { headers: { Range: "bytes=3-7", "If-Range": value } });
    assert.equal(response.status, 206);
    assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes.slice(3, 8));
  }
  for (const value of ['"older"', `W/${metadata.httpEtag}`, "bad date",
    new Date(uploaded.getTime() - 86400000).toUTCString(), new Date(uploaded.getTime() + 86400000).toUTCString()]) {
    const response = await request(bucketFixture(), { headers: { Range: "bytes=3-7", "If-Range": value } });
    assert.equal(response.status, 200);
    assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
  }
});

test("conditional GET uses weak ETag comparison and If-Modified-Since ordering", async () => {
  for (const headers of [{ "If-None-Match": `W/${metadata.httpEtag}` },
    { "If-Modified-Since": new Date(uploaded.getTime() + 86400000).toUTCString() }]) {
    const fixture = bucketFixture();
    const response = await request(fixture, { headers });
    assert.equal(response.status, 304);
    assert.equal((await response.arrayBuffer()).byteLength, 0);
    assert.equal(fixture.calls.length, 1);
  }
});

test("write methods, directory listing, arbitrary keys and mismatched versions are refused", async () => {
  const fixture = bucketFixture();
  assert.equal((await request(fixture, { method: "POST" })).status, 405);
  for (const path of ["", "v0.1.0-alpha.22/", `${key}.js`, "private.json", key.replace("/moojicut-0.1.0-alpha.22", "/moojicut-0.1.0-alpha.23")])
    assert.equal((await request(fixture, {}, path)).status, 404);
  assert.equal(fixture.calls.length, 0);
});

test("a changed R2 object cannot combine new bytes with old metadata", async () => {
  const fixture = bucketFixture({ async get() { return metadata; } });
  const response = await request(fixture);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal((await response.arrayBuffer()).byteLength, 0);
});

test("update index is short-lived and stale snapshots make clients fall back", async () => {
  const path = "updates/releases.json";
  const fresh = { ...metadata, uploaded: new Date() };
  const fixture = bucketFixture({ async head(key) { return key === path ? fresh : null; } });
  const response = await request(fixture, {}, path);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^application\/json/);
  assert.match(response.headers.get("cache-control"), /max-age=60/);
  assert.doesNotMatch(response.headers.get("cache-control"), /immutable/);
  const stale = bucketFixture({ async head() { return { ...fresh, uploaded: new Date(0) }; } });
  assert.equal((await request(stale, {}, path)).status, 503);
  assert.equal(stale.calls.length, 0);
});

test("versioned Sparkle appcast is served as immutable XML", async () => {
  const path = "v0.1.0-alpha.22/macos.xml";
  const fixture = bucketFixture({ async head(key) { return key === path ? metadata : null; } });
  const response = await request(fixture, {}, path);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^application\/xml/);
  assert.match(response.headers.get("cache-control"), /immutable/);
  assert.deepEqual(new Uint8Array(await response.arrayBuffer()), bytes);
});
