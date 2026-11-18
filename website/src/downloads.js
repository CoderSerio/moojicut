const versionPattern = /^\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?$/;
const suffixes = {
  macos: "macos-arm64.zip",
  windows: "windows-x64.zip",
  linux: "linux-x64.tar.gz",
};

// The allowlist is bundled with the page, independently of the fetched snapshot.
// A newer release can replace the links without inheriting old mirrors.
export function validatedRelease(release, manifest) {
  if (!release || typeof release.version !== "string" || !versionPattern.test(release.version))
    return null;
  const version = release.version;
  const base = `https://github.com/CoderSerio/moojicut/releases/download/v${version}/`;
  const names = Object.fromEntries(
    Object.entries(suffixes).map(([key, suffix]) => [key, `moojicut-${version}-${suffix}`]),
  );
  if (!Object.keys(names).every((key) => release.downloads?.[key] === base + names[key]))
    return null;

  const mirrors = {};
  const entries = manifest?.schemaVersion === 1 && Array.isArray(manifest.mirrors)
    ? manifest.mirrors.filter((entry) => entry.version === version) : [];
  const trusted = entries.length === 1 ? entries[0] : null;
  // No arbitrary URLs from releases.json: the published allowlist fixes the origin,
  // exact filename, checksum and length for this specific release.
  if (trusted && /^https:\/\/(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:pages|workers)\.dev$/.test(trusted.origin)) {
    for (const key of Object.keys(names)) {
      const expected = trusted.downloads?.[key];
      const actual = release.mirrors?.[key];
      const url = `${trusted.origin}/v${version}/${names[key]}`;
      if (expected && /^[a-f0-9]{64}$/.test(expected.sha256)
        && Number.isSafeInteger(expected.size) && expected.size > 0
        && actual?.url === url && actual.sha256 === expected.sha256 && actual.size === expected.size)
        mirrors[key] = { url, size: expected.size };
    }
  }
  return { version, downloads: release.downloads, mirrors };
}

export function updateDownloads(document, release, manifest) {
  const validated = validatedRelease(release, manifest);
  if (!validated) return false;
  document.querySelectorAll("[data-download]").forEach((link) => {
    const platform = link.dataset.download;
    const github = validated.downloads[platform];
    const mirror = validated.mirrors[platform];
    link.href = mirror?.url ?? github;
    if (mirror) {
      link.dataset.fallback = github;
      link.dataset.mirrorSize = String(mirror.size);
    } else {
      delete link.dataset.fallback;
      delete link.dataset.mirrorSize;
    }
  });
  document.querySelectorAll("[data-version]").forEach((label) => {
    label.textContent = validated.version;
  });
  document.querySelectorAll("[data-release-link]").forEach((link) => {
    link.href = `https://github.com/CoderSerio/moojicut/releases/tag/v${validated.version}`;
  });
  return true;
}

export function detectPlatform({ userAgent = "", userAgentData, platform = "", maxTouchPoints = 0 }) {
  const hint = userAgentData?.platform;
  if (userAgentData?.mobile || /Android|iPhone|iPad|iPod/i.test(userAgent)
      || (platform === "MacIntel" && maxTouchPoints > 1)) return "mobile";
  if (hint === "Chrome OS" || /\bCrOS\b/i.test(userAgent)) return null;
  if (hint === "Windows") return "windows";
  if (hint === "macOS") return "macos";
  if (hint === "Linux") return "linux";
  if (/Windows NT/i.test(userAgent) || /^Win/i.test(platform)) return "windows";
  if (/Macintosh|Mac OS X/i.test(userAgent) || /^Mac/i.test(platform)) return "macos";
  if (/Linux|X11/i.test(userAgent) || /^Linux/i.test(platform)) return "linux";
  return null;
}

export function recommendPlatform(document, platform) {
  const names = { macos: "Mac", windows: "Windows", linux: "Linux" };
  document.querySelectorAll("[data-platform]").forEach((card) => {
    card.classList.toggle("suggested", card.dataset.platform === platform);
  });
  if (!platform) return;
  document.querySelector("#platform-hint").textContent = platform === "mobile"
    ? "Open this page on your computer to get Mooji Cut."
    : `${names[platform]} is the recommended download for this device.`;
}

export async function availableDownload(mirror, fallback, size, request = fetch) {
  try {
    // Check the visitor's connection before handing control to the browser.
    const response = await request(mirror, {
      method: "HEAD",
      credentials: "omit",
      redirect: "error",
      cache: "no-store",
      signal: AbortSignal.timeout(1500),
    });
    if (response.status === 200 && response.headers.get("Content-Length") === size) return mirror;
  } catch {
    // A blocked origin, timeout, or offline mirror all use the same fallback.
  }
  return fallback;
}

export function enableDownloadFallback(document, navigate) {
  document.querySelectorAll("[data-download]").forEach((link) => {
    let pending = false;
    link.addEventListener("click", async (event) => {
      const { fallback, mirrorSize } = link.dataset;
      if (!fallback || event.defaultPrevented || event.button !== 0
          || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      if (pending) return;
      pending = true;
      try {
        navigate(await availableDownload(link.href, fallback, mirrorSize));
      } finally {
        pending = false;
      }
    });
  });
}
