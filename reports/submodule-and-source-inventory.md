# Submodule and Source Inventory

## Upstream import

- Repository: `https://github.com/NousResearch/hermes-agent.git`
- Commit: `bc655bfb40ff7414bbec9dd179b17cf41e2f60ba`
- Commit date: `2026-09-21T14:41:52Z`
- Tree: `8196c19ca3510d2bd1297c41c72059742379780d`
- Local state: detached checkout at `upstream/hermes-agent/`
- Git submodules: none (`git submodule status` produced no entries)
- Upstream patches/source modifications: none

`manifests/upstream.lock` is the durable pin. The nested `.git` directory is retained during review so the no-modification assertion is independently checkable. Before making a distributable parent-repository commit, import the same tree without nested VCS metadata or use a reviewed subtree workflow; do not use an online-required submodule.

## Locked source graphs

| Source graph | Status | Notes |
|---|---|---|
| Python | Locked | `uv.lock` has 258 registry packages with URLs/hashes and one editable root. Platform selection still required. |
| Root npm workspaces | Locked | Lockfile v3, 1,421 entries; non-registry entries are local workspace links. |
| Photon sidecar | Locked | Standalone lockfile v3, 111 entries. |
| WhatsApp bridge | Locked | Standalone lockfile v3, 167 entries. |
| Website | Locked | Standalone lockfile v3, 1,390 entries; build-only. |
| Rust/Tauri | **Not locked** | `Cargo.toml` exists but no `Cargo.lock`; broad major-version requirements. |
| Nix | Locked references only | Seven GitHub inputs are commit/NAR-hash pinned; the fetched source/store closure is absent. |

Nix inputs are `nixpkgs`, `flake-parts`, Home Manager, uv2nix, pyproject-nix, pyproject build-system packages, and npm-lockfile-fix. Their exact revisions and NAR hashes are in `flake.lock`.

## Catalog/source acquisition surfaces

- Plugin catalog: 223 YAML files, of which 222 are real entries and one is `removed.yaml`. Every real entry has a repository and 40-character SHA; 221 use GitHub and one GitLab. Install performs a clone/checkout of that pin and may install declared dependencies. These sources are optional and are not part of the base bundle.
- Bundled plugins: 105 manifests under `plugins/`, already part of the upstream tree. Some require optional Python/npm packages or external executables/services.
- MCP catalog: 65 HTTP endpoint definitions; no server source or install blocks. There is therefore no MCP server source to vendor in the initial bundle.
- Skills: 208 bundled/optional `SKILL.md` files plus generated indexes. The Skills Hub can fetch URL/well-known content, GitHub repositories, LobeHub and browse.sh bundles at runtime; those remote sources are excluded from the base bundle.
- Model/source data: Hugging Face model files, wake-word models, local-engine assets and provider catalogs can be downloaded on demand but are not pinned as repository artifacts.
- Other release sources: SQLite, s6-overlay, Node, uv, Git for Windows, CUA, iron-proxy, Bitwarden `bws`, ast-grep and browser archives.

## Container and CI sources

The Dockerfile uses `debian:13.4`, digest-pinned Astral uv and Node images, apt repositories, SQLite mirrors, GitHub release archives, npm, PyPI and Playwright downloads. Compose has a local build path and mutable `nousresearch/hermes-agent:latest` on Windows. The Matrix test Compose uses `ghcr.io/continuwuity/continuwuity:latest`.

There are 33 workflow files. Third-party GitHub Actions are commit-pinned, including actions/checkout/cache/artifact/pages, Astral setup-uv, Docker actions, Cachix/Nix cache actions, OSV scanner, Hadolint and ShellCheck. Hosted runners, actions, registries, caches and package managers remain online dependencies and are not part of an offline release.

## Phase 2 source policy

Only sources required by an approved profile should be collected. Each must be immutable, checksummed and license-reviewed. Catalog availability must not imply bundling. Mutable branches, `latest`, generated package-manager resolutions and download-and-execute scripts must be converted to fixed artifacts or disabled with an actionable error.

