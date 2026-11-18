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

At deploy time, `scripts/sync_releases.py` selects the highest published semantic version (including previews) with all three supported desktop packages. It refreshes `public/releases.json` and the HTML download links in the deployment checkout. A failed refresh leaves the last working deployment live. Visitors fetch the same-origin snapshot to refresh the links.

`verified-mirrors.json` lets each platform’s download button use a verified Cloudflare mirror. Its versioned entries have `{version, origin, downloads: {macos/windows/linux: {sha256, size}}}` under `{schemaVersion: 1, mirrors: [...]}`. A publisher must download each public mirror URL and verify its complete bytes against the GitHub release before adding an entry. The canonical HTTPS Pages/Workers origin has no trailing slash. Routes follow `/v<version>/moojicut-<version>-<platform suffix>`. Omit platforms that have yet to be mirrored.

The build requires an exact match with the GitHub asset’s SHA-256 digest and file size. HTML links and the runtime snapshot both point to GitHub when the build has no verified mirror for that release and platform. A normal click on a mirrored download makes a HEAD request from the visitor’s browser and uses the same GitHub release asset if the mirror fails, reports the wrong size, or times out after 1.5 seconds. Static links also work without JavaScript. The current updater still uses GitHub and Sparkle. See the [download mirror notes](download-mirror/README.md) for the beta delivery plan. `npm test` covers platform detection, mirror selection, and the animation lifecycle using local fixtures.

When platform support changes, update the download requirements and FAQ alongside the release. OS suggestions do not claim to detect CPU architecture. Mobile visitors receive desktop guidance. The tool switches change only the website illustration, not application settings.
