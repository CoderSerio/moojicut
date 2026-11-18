// Pages advanced-mode entry point: copy this file to dist/_worker.js.
// Only verified, versioned release archives and their exact checksum sidecars
// are uploaded to the private R2 bucket. This public handler never writes,
// lists, proxies GitHub, or buffers a whole archive in Worker memory.
const RELEASE_PATH = /^\/v(\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?)\/(moojicut-\1-(?:macos-arm64\.zip|windows-x64\.zip|linux-x64\.tar\.gz)(?:\.sha256)?)$/;

function empty(request, status, extra = {}) {
  return new Response(null, {
    status,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...extra },
  });
}

function singleRange(value, size) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2]) || size === 0) return null;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    const length = Math.min(suffix, size);
    return { offset: size - length, length };
  }
  const offset = Number(match[1]);
  const end = match[2] ? Number(match[2]) : size - 1;
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(end) || offset >= size || end < offset) return null;
  return { offset, length: Math.min(end, size - 1) - offset + 1 };
}

function unchanged(request, object) {
  const tag = request.headers.get("If-None-Match");
  if (tag !== null) return tag.split(",").some((value) => {
    const normalized = value.trim().replace(/^W\//, "");
    return normalized === "*" || normalized === object.httpEtag;
  });
  const since = request.headers.get("If-Modified-Since");
  return since !== null && Math.floor(object.uploaded.getTime() / 1000) <= Math.floor(Date.parse(since) / 1000);
}

async function download(request, env) {
  if (request.method !== "GET" && request.method !== "HEAD") return empty(request, 405, { Allow: "GET, HEAD" });
  const url = new URL(request.url);
  const path = RELEASE_PATH.exec(url.pathname);
  if (!path) return empty(request, 404);
  const key = url.pathname.slice(1);
  const metadata = await env.RELEASES.head(key);
  if (!metadata) return empty(request, 404);
  const headers = new Headers({
    "Accept-Ranges": "bytes",
    "Content-Type": path[2].endsWith(".sha256") ? "text/plain; charset=utf-8"
      : path[2].endsWith(".zip") ? "application/zip" : "application/gzip",
    "Content-Disposition": `attachment; filename="${path[2]}"`,
    "Content-Length": String(metadata.size),
    "ETag": metadata.httpEtag,
    "Last-Modified": metadata.uploaded.toUTCString(),
    "Cache-Control": "public, max-age=31536000, immutable, no-transform",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Expose-Headers": "Content-Length, Content-Range, ETag",
    "X-Content-Type-Options": "nosniff",
  });
  if (unchanged(request, metadata)) {
    headers.delete("Content-Length");
    return new Response(null, { status: 304, headers });
  }
  if (request.method === "HEAD") return new Response(null, { status: 200, headers });
  let range;
  const requestedRange = request.headers.get("Range");
  const ifRange = request.headers.get("If-Range");
  const rangeMatches = !ifRange || ifRange === metadata.httpEtag ||
    (!ifRange.startsWith('"') && !ifRange.startsWith("W/") &&
      Math.floor(metadata.uploaded.getTime() / 1000) === Math.floor(Date.parse(ifRange) / 1000));
  if (requestedRange && rangeMatches) {
    range = singleRange(requestedRange, metadata.size);
    if (!range) return empty(request, 416, { "Content-Range": `bytes */${metadata.size}`, "Accept-Ranges": "bytes" });
    headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${metadata.size}`);
    headers.set("Content-Length", String(range.length));
  }
  // A concurrent replacement must not mix old metadata with different bytes.
  const object = await env.RELEASES.get(key, { onlyIf: { etagMatches: metadata.etag }, ...(range ? { range } : {}) });
  if (!object || !("body" in object)) return empty(request, 503, { "Retry-After": "5" });
  return new Response(object.body, { status: range ? 206 : 200, headers });
}

export default {
  async fetch(request, env) {
    try {
      return await download(request, env);
    } catch {
      console.error(JSON.stringify({ event: "release_download_failed" }));
      return empty(request, 503, { "Retry-After": "5" });
    }
  },
};
