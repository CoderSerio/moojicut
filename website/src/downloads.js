const versionPattern = /^\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?$/;
const suffixes = {
  macos: "macos-arm64.zip",
  windows: "windows-x64.zip",
  linux: "linux-x64.tar.gz",
};

// The allowlist is bundled with the page, independently of the fetched snapshot.
// A newer GitHub release can replace primary links without inheriting old mirrors.
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
        mirrors[key] = url;
    }
  }
  return { version, downloads: release.downloads, mirrors };
}

export function updateDownloads(document, release, manifest) {
  const validated = validatedRelease(release, manifest);
  if (!validated) return false;
  document.querySelectorAll("[data-mirror]").forEach((link) => {
    const url = validated.mirrors[link.dataset.mirror];
    link.hidden = !url;
    link.removeAttribute("href");
    if (url) link.href = url;
  });
  document.querySelectorAll("[data-download]").forEach((link) => {
    link.href = validated.downloads[link.dataset.download];
  });
  document.querySelectorAll("[data-version]").forEach((label) => {
    label.textContent = validated.version;
  });
  document.querySelectorAll("[data-release-link]").forEach((link) => {
    link.href = `https://github.com/CoderSerio/moojicut/releases/tag/v${validated.version}`;
  });
  return true;
}
