import assert from "node:assert/strict";
import test from "node:test";
import { availableDownload, detectPlatform, validatedRelease, updateDownloads } from "../src/downloads.js";

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

test("a matching mirror is eligible for the exact GitHub download", () => {
  const input = release();
  const checked = validatedRelease(input, manifest);
  assert.equal(checked.downloads.macos, input.downloads.macos);
  assert.deepEqual(checked.mirrors.macos, { url: input.mirrors.macos.url, size: 1234 });
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

test("the primary link prefers the mirror and clears the fallback for an unmirrored release", () => {
  const primary = { dataset: { download: "macos" } };
  const label = {};
  const releaseLink = {};
  const nodes = { "[data-download]": [primary], "[data-version]": [label], "[data-release-link]": [releaseLink] };
  const document = { querySelectorAll(selector) { return nodes[selector]; } };
  assert.equal(updateDownloads(document, release(), manifest), true);
  assert.equal(primary.href, release().mirrors.macos.url);
  assert.equal(primary.dataset.fallback, release().downloads.macos);
  assert.equal(primary.dataset.mirrorSize, "1234");
  const next = release("0.1.0-alpha.23");
  assert.equal(updateDownloads(document, next, manifest), true);
  assert.equal(primary.href, next.downloads.macos);
  assert.deepEqual(primary.dataset, { download: "macos" });
  assert.equal(label.textContent, next.version);
  assert.equal(releaseLink.href, `https://github.com/CoderSerio/moojicut/releases/tag/v${next.version}`);
});

test("platform recommendations use desktop hints and keep mobile and Chromebooks neutral", () => {
  const cases = [
    [{ userAgentData: { platform: "Windows" } }, "windows"],
    [{ userAgentData: { platform: "Windows" }, userAgent: "Mozilla/5.0 (Macintosh)" }, "windows"],
    [{ userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }, "windows"],
    [{ platform: "Win32" }, "windows"],
    [{ userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", platform: "MacIntel" }, "macos"],
    [{ userAgent: "Mozilla/5.0 (X11; Linux x86_64)" }, "linux"],
    [{ userAgent: "Mozilla/5.0 (Linux; Android 16)" }, "mobile"],
    [{ userAgent: "Mozilla/5.0 (Macintosh)", platform: "MacIntel", maxTouchPoints: 5 }, "mobile"],
    [{ userAgent: "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0)", platform: "Linux x86_64" }, null],
    [{ userAgentData: { platform: "Chrome OS" }, platform: "Linux x86_64" }, null],
    [{}, null],
  ];
  for (const [browser, expected] of cases) assert.equal(detectPlatform(browser), expected);
});

test("the preflight selects a reachable mirror with the right length and otherwise uses GitHub", async () => {
  const { downloads, mirrors } = release();
  const { url, size } = mirrors.macos;
  const choose = (request) => availableDownload(url, downloads.macos, String(size), request);
  const response = (status, length) => new Response(null, {
    status,
    headers: { "Content-Length": String(length) },
  });
  assert.equal(await choose((target, options) => {
    assert.equal(target, url);
    assert.equal(options.method, "HEAD");
    assert.ok(options.signal instanceof AbortSignal);
    return response(200, size);
  }), url);
  for (const invalid of [response(503, size), response(200, size + 1), new Response(null)]) {
    assert.equal(await choose(() => invalid), downloads.macos);
  }
  assert.equal(await choose(() => { throw new TypeError("network error"); }), downloads.macos);
});
