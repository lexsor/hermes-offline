# Browser and Runtime Inventory

## Surfaces

| Surface | Version/source | Behavior | Offline concern |
|---|---|---|---|
| Playwright | `@playwright/test`/`playwright`/`playwright-core` 1.62.1 in root lock | Docker and installers run `playwright install ... chromium`; browser bytes are downloaded outside npm | Must vendor the exact Playwright browser revision and Linux dependency set. |
| Chromium headless shell | revision selected by Playwright 1.62.1 | Docker stores it under `/opt/hermes/.playwright`; host installers use default Playwright cache | Revision/checksum is not represented in the repository manifests. |
| Electron | 40.10.2 | Desktop npm postinstall fetches Electron; runtime embeds Chromium | **Required for the approved Windows x64 desktop profile.** Vendor the exact Windows archive and notices (including Chromium notices); never fetch it during offline install or first launch. |
| `agent-browser` | unpinned, lazily invoked via npx | Default browser tool can resolve/install package on first use and install its browser | A critical hidden online fallback. Pin/cache it or disable the tool. |
| Camofox | `@askjo/camofox-browser@^1.5.2` | Installer can install a Hermes-managed server; `CAMOFOX_URL` can target a local server | Prefer external configured local service; exact-pin if bundled. |
| Lightpanda | external binary/service | Selected engine can be probed/spawned and may fall back to Chrome | Treat as external and do not auto-download. |
| System Chrome/Chromium/Edge/Brave | host discovered | CDP/browser-connect features may use a host installation | Document as an alternative prerequisite; do not silently switch engines in a deterministic profile. |
| Python Playwright plugin use | Google Meet and optional skills | Code tells users to `pip install playwright` and install Chromium | Not present in the main Python lock; exclude or add an explicit feature closure. |

## Install-time network paths

- `Dockerfile:199-203` performs npm install and `npx playwright install --with-deps chromium --only-shell`.
- `scripts/install.sh:2557-2834` runs Playwright install variants, including best-effort paths.
- `scripts/install.ps1:3722-3811` runs `npx --yes playwright install chromium`.
- `tools/browser_tool_install.py` falls back to `npx agent-browser` and can warm its cache.
- `hermes_cli/tools_config_post_setup.py` can install Chromium through agent-browser and install Camofox.
- Electron postinstall downloads platform packages unless supplied an offline mirror/cache.

## Required artifacts for an optional later Linux browser profile

1. Exact `agent-browser` npm package and full npm closure, or a decision to use Playwright directly.
2. The Playwright 1.62.1 Chromium/headless-shell archive for Linux x86_64 and its upstream checksum/provenance.
3. Required Debian shared libraries (as host prerequisites, vendored packages, or an image layer).
4. A fixed cache path configured by `PLAYWRIGHT_BROWSERS_PATH`.
5. A verification probe that starts the browser with networking disabled and confirms the executable revision.
6. Notices/licenses for Chromium, Playwright and bundled codecs/libraries.

The approved `windows-x64-desktop` profile needs the Electron 40.10.2 archive, native optional npm packages, electron-builder's NSIS/MSI and resource-editing payloads, and platform notices. Electron's embedded Chromium satisfies the desktop shell only; it does not automatically include or enable Hermes' general browser-automation feature.

## Offline behavior

When the browser feature is included, a missing package, browser executable or shared library must name the expected local artifact and stop. When it is excluded, discovery must report “browser feature not included in this bundle” and must not try npx, Playwright CDN, apt, a mirror, or a system-package install. Cloud browser providers remain explicit external services and are not evidence of local offline browser support.
