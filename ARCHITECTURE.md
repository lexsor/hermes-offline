# Architecture

## Design Principle

This should be a vendored distribution repository, not a loose fork with hidden online installation behavior.

The repository should contain the artifacts and scripts needed to reconstruct the runtime from local resources while preserving upstream Hermes as a mostly untouched source tree.

## Recommended Layout

```text
hermes-self-contained/
├── AGENTS.md
├── README.md
├── LICENSES.md
├── upstream/
│   └── hermes-agent/
├── patches/
│   ├── README.md
│   └── series
├── vendor/
│   ├── python/
│   ├── node/
│   ├── binaries/
│   ├── browser/
│   └── source/
├── manifests/
│   ├── upstream.lock
│   ├── python.lock
│   ├── node.lock
│   ├── binaries.lock
│   ├── browser.lock
│   ├── source.lock
│   ├── licenses.lock
│   └── checksums.sha256
├── scripts/
│   ├── bootstrap.sh
│   ├── install-offline.sh
│   ├── verify-deps.sh
│   ├── verify-offline.sh
│   ├── build-bundle.sh
│   ├── update-upstream.sh
│   ├── refresh-vendor-artifacts.sh
│   └── diff-dependency-surface.sh
├── config/
│   ├── env.example
│   ├── hermes.example.yaml
│   ├── providers/
│   ├── honcho.example.yaml
│   └── mcps.example.yaml
├── docker/
│   ├── Dockerfile
│   ├── compose.yaml
│   └── README.md
├── tests/
│   ├── offline-install/
│   ├── checksum/
│   ├── network-block/
│   └── smoke/
├── reports/
│   ├── dependency-inventory.md
│   ├── network-access-inventory.md
│   ├── binary-inventory.md
│   ├── browser-runtime-inventory.md
│   ├── submodule-and-source-inventory.md
│   ├── license-redistribution-review.md
│   ├── redistribution-exceptions.md
│   ├── offline-install-test.md
│   └── final-gap-list.md
└── docs/
    ├── upstream-update-workflow.md
    ├── offline-install.md
    ├── configuration.md
    └── troubleshooting.md
```

## Upstream Source Strategy

Keep Hermes source under `upstream/hermes-agent/`.

Use one of these approaches:

1. Git subtree or vendored source copy for a single-repository distribution.
2. Git submodule only if the final offline clone process explicitly vendors the submodule content and does not require online submodule fetches.
3. Patch files for unavoidable changes.

Preferred final state:

- `manifests/upstream.lock` records upstream repository URL, commit SHA, import date, and patch series version.
- `patches/series` lists each patch applied to upstream.
- `scripts/update-upstream.sh` handles import/rebase/update review.

## Dependency Classes

### Python

Vendor:

- wheels
- source distributions only when wheels are unavailable
- local build requirements needed to build sdists

Offline install should use local-only options such as:

- no index access
- explicit local find-links directory
- locked dependency versions
- checksum verification where supported

Do not commit a generated virtual environment.

### Node

Vendor:

- package tarballs
- lockfile
- package-manager cache when intentionally used as immutable input

Offline install should use the chosen package manager's local/offline mode and fail if a dependency is missing.

Do not commit generated `node_modules/` unless a later explicit distribution decision requires it and documents the tradeoff.

### Binaries

Vendor redistributable binary archives for tools Hermes requires, such as:

- ripgrep
- ffmpeg
- other command-line tools discovered during Phase 1

Each binary must include:

- platform
- architecture
- source URL
- version
- checksum
- license

### Browser Runtime

If Hermes or its tests require Playwright, Chromium, or another browser runtime, vendor redistributable browser artifacts or document why they cannot be redistributed.

Disable browser-manager online downloads during offline install.

### Source Dependencies

For dependencies that cannot be packaged as normal Python or Node artifacts, vendor immutable source archives or commit-pinned source directories under `vendor/source/`.

## Configuration Strategy

Keep runtime config separate from vendored artifacts.

Recommended files:

- `config/env.example`
- `config/hermes.example.yaml`
- `config/providers/*.example.yaml`
- `config/honcho.example.yaml`
- `config/mcps.example.yaml`

Do not commit real local config. Add ignore rules for:

- `.env`
- `config/*.local.*`
- `config/secrets.*`
- generated runtime state

## Network Boundary

There should be two clearly separated command families:

### Offline commands

These must not access the Internet:

- `scripts/verify-deps.sh`
- `scripts/install-offline.sh`
- `scripts/verify-offline.sh`
- offline smoke tests

### Online maintenance commands

These may access the Internet and must be labeled online-only:

- `scripts/update-upstream.sh`
- `scripts/refresh-vendor-artifacts.sh`
- dependency refresh commands
- license refresh commands

## Failure Design

Missing artifacts should fail with messages like:

```text
Missing required Python artifact:
  package: example-package==1.2.3
  expected: vendor/python/example_package-1.2.3-py3-none-any.whl
  manifest: manifests/python.lock

Offline install cannot continue.
Run scripts/refresh-vendor-artifacts.sh from an online maintenance environment.
```

Silent fallback to online registries is not acceptable.
