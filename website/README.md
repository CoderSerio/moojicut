# Mooji Cut website

English-first product website, deployed at https://coderserio.github.io/moojicut/.

## Develop and build

Requires Node 22.12+, npm, and Python 3 for download verification tests. From this directory:

```sh
npm ci
npm run build
npm run dev
```

Open the printed `/moojicut/` address. `npm run build` generates the three static illustration posters and bundles the site into `dist/`. Run the build once before the first dev session to generate posters; repeat it after editing the scenes. `npm test` exercises animation loading and playback lifecycle boundaries. `npm run preview` serves the production bundle.

## Design and motion

`index.html` contains crawlable, no-JavaScript content and direct download links. `style.css` owns the neutral visual system, responsive layouts, full-height sections and native proximity scroll snapping. Small screens, short content areas and reduced-motion settings retain natural scrolling; no wheel events are intercepted.

`src/scenes.jsx` defines original SVG product illustrations. The same scenes generate static posters and animate through the real Remotion Player in `src/motion-player.jsx`. They illustrate supported workflows rather than claim pixel-exact app screenshots. Editing features shown are explicitly labeled as the Mac preview.

React, Remotion and scene code are in a dynamically imported chunk, requested only once a demo intersects the viewport. Each player mounts only when its own demo is visible, pauses offscreen and in hidden tabs, and preserves an explicit user pause. The static poster stays in place while loading or on failure. Reduced motion keeps posters until the visitor explicitly presses Play. `src/motion-controller.js` centralizes and tests that lifecycle policy. Below-fold content uses one-time entrance transitions. Keyboard focus, labeled playback controls, native FAQ disclosures and toolbar switches remain accessible.

Remotion dependencies have their own [Remotion license](https://www.remotion.dev/license); see their package license metadata. This website does not render videos on a server. The app itself remains MIT licensed. The page uses Google Fonts with system font fallbacks.

## Deployment and downloads

The GitHub Pages workflow builds and publishes `dist/` after website changes reach `main`, a release is published, or manual workflow dispatch. It checks out `main`, installs the lockfile, runs lifecycle tests, then builds with Vite's `/moojicut/` base path.

At deploy time, `scripts/sync_releases.py` selects the highest published semantic version (including previews) with all three supported desktop packages. It refreshes `public/releases.json` and HTML fallback links in the deployment checkout, without committing generated changes or exposing the workflow token. Refresh failure stops deployment and leaves the last working site available. Visitors fetch only a same-origin snapshot, not the GitHub API. Primary download links point directly to official GitHub release assets.

`verified-mirrors.json` optionally adds a **Cloudflare mirror** link below a platform’s primary download. Its versioned entries have `{version, origin, downloads: {macos/windows/linux: {sha256, size}}}` under `{schemaVersion: 1, mirrors: [...]}`. A publisher must download each public mirror URL and verify its complete bytes against the GitHub release before adding an entry. The canonical HTTPS Pages/Workers origin has no trailing slash; routes are `/v<version>/moojicut-<version>-<platform suffix>`. Unavailable platforms can be omitted. Empty `mirrors` keeps every mirror link hidden.

The deployment script separately requires an exact match with the GitHub asset’s `sha256:` digest and byte size; missing digests, mismatches, and older mirror versions cannot produce a link. Both the no-JavaScript HTML and runtime snapshot follow this rule. The browser checks the snapshot against the bundled manifest and clears stale mirror links on a release change. This is a manual download alternative: application update feeds and their GitHub/Sparkle verification are unchanged. `npm test` covers checksum/version gating, stale links, and the animation lifecycle without contacting release services.

When platform support changes, update the download requirements and FAQ alongside the release. OS suggestions do not claim to detect CPU architecture. Mobile visitors receive desktop guidance. The tool switches change only the website illustration, not application settings.
