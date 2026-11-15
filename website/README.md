# Mooji Cut website

English-first, buildless HTML/CSS/JavaScript. The editable website lives entirely in this directory; the Pages deployment workflow lives in `.github/workflows/website.yml`.

Preview locally with `python3 -m http.server 8765 --bind 127.0.0.1 --directory website` from the repository root. No dependencies or build tool are needed. Product illustrations are original SVG/HTML, labeled as illustrations; the app icon and colors use the existing Mooji Cut identity. Fonts use Google Fonts with system fallbacks.

GitHub Pages deploys after website changes reach `main`, a release is published, or manual workflow dispatch. At deploy time, `scripts/sync_releases.py` chooses the highest published semantic version (including previews) with all three supported desktop assets. It refreshes `releases.json` and HTML fallback links in the deployment checkout, without committing generated changes or exposing the workflow token. Failed refreshes stop deployment and leave the last working site available. Visitors fetch only a same-origin snapshot, so downloading does not depend on the GitHub API. Download links point directly to official GitHub release assets.

When platform support or minimum system requirements change, update the platform cards and FAQ in `index.html` alongside the release. Mobile visitors get desktop guidance, not a guessed compatible package. The platform suggestion does not claim to detect CPU architecture.

The page uses semantic tabs, keyboard navigation, accessible switches, visible focus, native FAQ disclosures and reduced-motion support. The timeline illustration plays only after a click and pauses when switching tabs or leaving the page. Toolbar switches affect only the illustration and do not persist app settings.

Public address: https://coderserio.github.io/moojicut/
