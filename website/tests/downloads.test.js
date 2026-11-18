import assert from "node:assert/strict";
import test from "node:test";
import { validatedRelease, updateDownloads } from "../src/downloads.js";

const version = "0.1.0-alpha.22";
const origin = "https://mirror-fixture.pages.dev";
const sha256 = "a".repeat(64);
const suffixes = { macos: "macos-arm64.zip", windows: "windows-x64.zip", linux: "linux-x64.tar.gz" };
const manifest = { schemaVersion: 1, mirrors: [{ version, origin, downloads: { macos: { sha256, size: 1234 } } }] };
function release(releaseVersion = version) {
  return {
    version: releaseVersion,
    downloads: Object.fromEntries(Object.entries(suffixes).map(([key, suffix]) => [key,
      `https://github.com/CoderSerio/moojicut/releases/download/v${releaseVersion}/moojicut-${releaseVersion}-${suffix}`])),
    mirrors: { macos: { url: `${origin}/v${releaseVersion}/moojicut-${releaseVersion}-macos-arm64.zip`, sha256, size: 1234 } },
  };
}

test("a matching mirror supplements the exact GitHub download", () => {
  const input = release();
  const checked = validatedRelease(input, manifest);
  assert.equal(checked.downloads.macos, input.downloads.macos);
  assert.equal(checked.mirrors.macos, input.mirrors.macos.url);
  assert.equal(Object.keys(checked.mirrors).length, 1);
  assert.deepEqual(validatedRelease(input, { schemaVersion: 1, mirrors: [] }).mirrors, {});
});

test("snapshot mirror URL, digest, size and version must all match the bundled publication", () => {
  for (const change of [
    { url: "https://untrusted.example/download.zip" },
    { url: `${origin}/v0.1.0-alpha.21/moojicut-0.1.0-alpha.21-macos-arm64.zip` },
    { sha256: "b".repeat(64) }, { size: 1235 }, { size: "1234" },
  ]) {
    const input = release();
    Object.assign(input.mirrors.macos, change);
    assert.deepEqual(validatedRelease(input, manifest).mirrors, {});
  }
  assert.deepEqual(validatedRelease(release("0.1.0-alpha.23"), manifest).mirrors, {});
  const input = release();
  input.downloads.linux = "https://untrusted.example/app.tar.gz";
  assert.equal(validatedRelease(input, manifest), null);
});

test("updating to a newer release removes the old mirror href and keeps primary links working", () => {
  const mirror = { dataset: { mirror: "macos" }, hidden: true, removeAttribute(name) { delete this[name]; } };
  const primary = { dataset: { download: "macos" } };
  const label = {};
  const releaseLink = {};
  const nodes = { "[data-mirror]": [mirror], "[data-download]": [primary], "[data-version]": [label], "[data-release-link]": [releaseLink] };
  const document = { querySelectorAll(selector) { return nodes[selector]; } };
  assert.equal(updateDownloads(document, release(), manifest), true);
  assert.equal(mirror.hidden, false);
  assert.equal(mirror.href, release().mirrors.macos.url);
  const next = release("0.1.0-alpha.23");
  assert.equal(updateDownloads(document, next, manifest), true);
  assert.equal(mirror.hidden, true);
  assert.equal(mirror.href, undefined);
  assert.equal(primary.href, next.downloads.macos);
  assert.equal(label.textContent, next.version);
  assert.equal(releaseLink.href, `https://github.com/CoderSerio/moojicut/releases/tag/v${next.version}`);
});
