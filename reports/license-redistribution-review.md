# License and Redistribution Review

## Status

Phase 1 classification is preliminary. It identifies issues and the metadata work needed before artifacts are copied into `vendor/`; it is not legal advice or release approval.

Upstream Hermes declares MIT and includes `upstream/hermes-agent/LICENSE`. Bundled subtrees also contain separate license/notice files, including Apache-2.0 material in `plugins/security-guidance` and licenses in several skills/plugins. Those notices must survive source filtering and release packaging.

## Dependency classes

| Class | Evidence | Preliminary status | Required action |
|---|---|---|---|
| Hermes source | Root MIT license | Redistributable with notice | Preserve copyright/license and document upstream commit/patches. |
| Python artifacts | `uv.lock` has names, versions, URLs and hashes but no license fields | Unknown per artifact | Capture wheel/sdist metadata and license files for every selected distribution; resolve `LicenseRef`/missing cases. |
| npm artifacts | Lockfiles include license strings for most entries | Mostly permissive, with exceptions | Extract package license files, not only SPDX labels; resolve missing/custom/copyleft entries below. |
| Rust crates | No Cargo lock | Unknown/unresolved | Generate reviewed lock only if Tauri is selected; collect crate licenses. |
| Nix closure | Source pins exist; closure does not | Unknown as a redistributable aggregate | Use Nix license metadata plus source/license files for every exported path. |
| OS packages/base images | Debian/Node/uv images and apt packages | Redistributable subject to package-specific notices/source obligations | Prefer base-image archive/SBOM or documented host prerequisites; preserve Debian copyright/source-offer obligations. |
| Browsers/Electron | Chromium, Playwright, Electron plus codecs and third-party notices | Redistributable with extensive notices; codec/patent review may apply | Bundle official notices/license inventory and exact platform payloads. |
| Models/weights | Hugging Face, wake-word, whisper and user-selected models | License varies by model; some gated or usage-restricted | Never assume package license covers weights. Manifest/review each model separately or require user-supplied local path. |
| External services | Honcho, MCP/provider APIs, cloud browsers, messaging | Not redistributed as software | Ship configuration only; terms of service and credentials remain user responsibility. |
| External plugins/skills | Catalog points to third-party repositories | Not in base bundle | Do not vendor without per-repository license/provenance review. |

## npm findings

The root lock has 1,420 non-root package/workspace entries, 15 without a license field. Recorded licenses are predominantly MIT/ISC/Apache/BSD. Findings needing action:

- `gsap@3.15.0` records a custom “Standard no charge” license rather than an OSI SPDX license. It is a direct dependency of the `web` workspace and an optional peer of `@nous-research/ui`; it is not declared directly by `apps/desktop`. For the approved Windows desktop profile, construct the minimum desktop workspace closure and prove whether GSAP is present in the packaged output. Do not redistribute its tarball unless its terms are approved; if it is unnecessary for desktop, exclude it from that profile rather than vendoring the entire root workspace indiscriminately.
- `@vscode/codicons` and `caniuse-lite` record CC-BY-4.0; attribution is required.
- `lightningcss` platform packages are MPL-2.0; retain license/source notices and respect file-level copyleft.
- `dompurify` offers MPL-2.0 OR Apache-2.0; record the selected compliance path.
- The WhatsApp lock includes `libsignal@6.0.0` as GPL-3.0 and sharp/libvips platform packages under LGPL-3.0-or-later combinations. Treat the WhatsApp bridge as a separate optional distribution component pending copyleft/source-offer review.
- Missing lockfile license metadata includes workspaces plus `khroma`, Photon packages, `qrcode-terminal`, and several website packages. Inspect package contents/registry metadata rather than classifying them as prohibited.

## Python/native and binary concerns

- Native wheels may bundle OpenSSL, libheif/codecs, ONNX Runtime, CTranslate2, audio libraries, libolm or other third-party code. Wheel `METADATA` alone is insufficient; inspect embedded notices and shared libraries.
- `pvporcupine` and other SDKs tied to cloud/premium services may have non-standard terms. Review before including the `wake` profile.
- ffmpeg redistribution depends on the chosen build configuration and codecs. A distro package cannot be copied blindly; either select a reviewed build or make ffmpeg a host prerequisite.
- Git, ripgrep, uv, Node/npm, s6-overlay, SQLite, Chromium/Electron, CUA, iron-proxy, `bws`, Camofox and Lightpanda each need their own license/provenance row.
- The remote CUA installer and dynamic Node/uv installers are also supply-chain blockers even if their resulting binaries are legally redistributable.

## Bundled content and catalogs

The upstream tree contains multiple nested license files, but many plugin/skill/catalog entries contain only metadata or links. Bundling a catalog record is not permission to bundle the referenced repository, logo, README image, model or service content. Remote images in plugin catalog records should either remain remote metadata or be reviewed separately before mirroring.

## Phase 2 license gate

For every artifact selected for vendoring, record: package/artifact identity, exact version/revision, upstream URL, SHA-256, declared SPDX expression, license-file paths, copyright/notice paths, redistribution classification, source-offer requirement, reviewer and notes. `unknown` is acceptable during collection but blocks release. Non-redistributable or unresolved artifacts must move to `reports/redistribution-exceptions.md` with an external prerequisite and clear failure mode.
