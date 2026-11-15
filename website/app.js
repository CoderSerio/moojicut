import { createMotionController } from "./src/motion-controller.js";

const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
const hasObserver = "IntersectionObserver" in window;
if (hasObserver && !reduced.matches) {
  const reveal = new IntersectionObserver(
    (entries) => {
      entries.forEach(({ target, isIntersecting }) => {
        if (!isIntersecting) return;
        target.classList.add("is-visible");
        reveal.unobserve(target);
      });
    },
    { threshold: 0.06 },
  );
  document.querySelectorAll("[data-reveal]").forEach((element) => {
    // Above-the-fold content stays visible even if JS stops during enhancement.
    if (element.getBoundingClientRect().top < window.innerHeight) return;
    element.classList.add("reveal-pending");
    reveal.observe(element);
  });
}

let motionModule;
const loadMotion = () => (motionModule ??= import("./src/motion-player.jsx"));
const controllers = new Map();
document.querySelectorAll("[data-motion]").forEach((element) => {
  const button = element.querySelector(".motion-toggle");
  const kind = element.dataset.motion;
  const controller = createMotionController({
    load: loadMotion,
    mount: (module, callbacks) =>
      module.mountPlayer(
        element.querySelector(".motion-mount"),
        kind,
        callbacks,
      ),
    onReady: () => element.classList.add("ready"),
    onError: () => {
      element.classList.remove("ready");
      button.hidden = true;
    },
    onState: (playing) => {
      const action = playing ? "Pause" : "Play";
      button.setAttribute(
        "aria-label",
        `${action} ${kind === "edit" ? "editor" : kind} animation`,
      );
      button.title = `${action} animation`;
      button
        .querySelector("use")
        .setAttribute("href", playing ? "#i-pause" : "#i-play");
    },
  });
  controller.setHidden(document.hidden);
  controller.setReduced(reduced.matches);
  button.hidden = !hasObserver;
  button.addEventListener("click", () => controller.toggle());
  controllers.set(element, controller);
});
if (hasObserver) {
  const motionObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach(({ target, isIntersecting, intersectionRatio }) => {
        controllers
          .get(target)
          .setVisible(isIntersecting && intersectionRatio >= 0.12);
      });
    },
    { threshold: [0, 0.12] },
  );
  controllers.forEach((_, element) => motionObserver.observe(element));
  const sectionObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        document.querySelectorAll(".section-nav a").forEach((link) => {
          if (link.hash === `#${entry.target.id}`)
            link.setAttribute("aria-current", "location");
          else link.removeAttribute("aria-current");
        });
      }
    },
    { rootMargin: "-30% 0px -60% 0px", threshold: 0 },
  );
  document
    .querySelectorAll("main > section")
    .forEach((element) => sectionObserver.observe(element));
}
document.addEventListener("visibilitychange", () =>
  controllers.forEach((controller) => controller.setHidden(document.hidden)),
);
reduced.addEventListener("change", () =>
  controllers.forEach((controller) => controller.setReduced(reduced.matches)),
);

const toolButtons = document.querySelectorAll("[data-tool]");
toolButtons.forEach((button) =>
  button.addEventListener("click", () => {
    const show = button.getAttribute("aria-checked") !== "true";
    button.setAttribute("aria-checked", String(show));
    document
      .querySelector(`[data-preview-tool="${button.dataset.tool}"]`)
      .toggleAttribute("hidden", !show);
    const total = [...toolButtons].filter(
      (item) => item.getAttribute("aria-checked") === "true",
    ).length;
    document.querySelector(".stage-caption").textContent =
      `${total} optional ${total === 1 ? "tool" : "tools"} shown. Your toolbar, your way.`;
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
    `Looks like you’re on ${name}. Check the system and chip requirements below.`;
} else if (mobile)
  document.querySelector("#platform-hint").textContent =
    "Made for your desktop. Open this page on your computer to download.";
// Same-origin snapshot; the HTML also contains working no-JavaScript download links.
fetch(`${import.meta.env.BASE_URL}releases.json`, { cache: "no-cache" })
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
