const tabs = [...document.querySelectorAll('[role="tab"]')];
const panels = [...document.querySelectorAll('[role="tabpanel"]')];
const hints = {
  capture: "Capture → annotate → copy",
  pin: "Keep a reference close",
  record: "Split → reorder → export",
};
let frame = null,
  start = 0,
  elapsed = 0;
const play = document.querySelector("#demo-play");
const playhead = document.querySelector(".playhead");
const time = document.querySelector("#demo-time");
function stopPreview() {
  cancelAnimationFrame(frame);
  frame = null;
  play.setAttribute("aria-label", "Play illustrative timeline");
  play.innerHTML = '<svg class="icon"><use href="#i-play"/></svg>';
}
function selectTab(tab, focus = false) {
  stopPreview();
  tabs.forEach((item) => {
    const active = item === tab;
    item.setAttribute("aria-selected", String(active));
    item.tabIndex = active ? 0 : -1;
  });
  panels.forEach((panel) => {
    panel.hidden = panel.id !== tab.getAttribute("aria-controls");
  });
  document.querySelector("#demo-hint").textContent = hints[tab.dataset.mode];
  if (focus) tab.focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    const next =
      event.key === "ArrowRight"
        ? (index + 1) % tabs.length
        : event.key === "ArrowLeft"
          ? (index + tabs.length - 1) % tabs.length
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? tabs.length - 1
              : null;
    if (next !== null) {
      event.preventDefault();
      selectTab(tabs[next], true);
    }
  });
});
play.addEventListener("click", () => {
  if (frame !== null) {
    stopPreview();
    return;
  }
  if (elapsed >= 12000) elapsed = 0;
  start = performance.now() - elapsed;
  play.setAttribute("aria-label", "Pause illustrative timeline");
  play.textContent = "Ⅱ";
  function tick(now) {
    elapsed = Math.min(now - start, 12000);
    playhead.style.left = `${elapsed / 120}%`;
    time.textContent = `00:${String(Math.floor(elapsed / 1000)).padStart(2, "0")} / 00:12`;
    if (elapsed >= 12000) stopPreview();
    else frame = requestAnimationFrame(tick);
  }
  frame = requestAnimationFrame(tick);
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopPreview();
});
document.querySelectorAll("[data-tool]").forEach((button) =>
  button.addEventListener("click", () => {
    const show = button.getAttribute("aria-checked") !== "true";
    button.setAttribute("aria-checked", String(show));
    document
      .querySelector(`[data-preview-tool="${button.dataset.tool}"]`)
      .toggleAttribute("hidden", !show);
  }),
);
const agent = navigator.userAgent;
const mobile =
  /Android|iPhone|iPad|iPod/i.test(agent) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const platform = mobile
  ? null
  : /Windows/i.test(agent)
    ? "windows"
    : /Macintosh|Mac OS X/i.test(agent)
      ? "macos"
      : /Linux|X11/i.test(agent)
        ? "linux"
        : null;
if (platform) {
  document
    .querySelector(`[data-platform="${platform}"]`)
    .classList.add("suggested");
  const name = { macos: "Mac", windows: "Windows", linux: "Linux" }[platform];
  document.querySelector("#platform-hint").textContent =
    `Looks like you’re on ${name}. Check the requirements below to choose the right download.`;
} else if (mobile)
  document.querySelector("#platform-hint").textContent =
    "Mooji Cut is a desktop app. Open this page on your computer to download.";
// A same-origin snapshot keeps downloading independent of GitHub API rate limits.
// The HTML links remain usable with JavaScript disabled or the snapshot unavailable.
fetch("releases.json", { cache: "no-cache" })
  .then((response) => {
    if (!response.ok) throw new Error("No release snapshot");
    return response.json();
  })
  .then((release) => {
    if (!/^\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?$/.test(release.version))
      return;
    const base = `https://github.com/CoderSerio/moojicut/releases/download/v${release.version}/`;
    const suffixes = {
      macos: "macos-arm64.zip",
      windows: "windows-x64.zip",
      linux: "linux-x64.tar.gz",
    };
    if (
      !Object.keys(suffixes).every(
        (key) =>
          release.downloads?.[key] ===
          `${base}moojicut-${release.version}-${suffixes[key]}`,
      )
    )
      return;
    document.querySelectorAll("[data-download]").forEach((link) => {
      link.href = release.downloads[link.dataset.download];
    });
    document.querySelectorAll("[data-version]").forEach((label) => {
      label.textContent = release.version;
    });
    document.querySelectorAll("[data-release-link]").forEach((link) => {
      link.href = `https://github.com/CoderSerio/moojicut/releases/tag/v${release.version}`;
    });
  })
  .catch(() => {});
