# AGENTS.md

## Mission

Build a self-contained, offline-capable distribution repository for NousResearch Hermes Agent.

Preserve upstream Hermes as much as possible. Prefer wrapping, vendoring, configuration, and patch files over invasive modifications to upstream source.

## Operating Rules

1. Work in phases. Do not start a later phase until the required outputs from the current phase exist and have been reviewed.
2. Phase 1 is discovery only. Do not modify upstream Hermes source during Phase 1.
3. Never hide network access. Any missing dependency artifact must cause a clear, actionable failure rather than falling back to the Internet.
4. Keep secrets out of Git. Do not commit API keys, tokens, private keys, `.env` files, local credentials, or generated user config.
5. Do not vendor generated runtime folders such as `.venv/`, `node_modules/`, Playwright cache directories, or machine-specific package manager caches unless the project explicitly decides to treat a cache as an immutable artifact and documents why.
6. Prefer immutable artifacts: wheels, sdists, npm tarballs, binary archives, source archives, lockfiles, checksums, and license records.
7. Document every dependency that cannot legally or technically be redistributed.
8. Support external local services such as Honcho and MCP servers through configuration and documented integration points rather than bundling them in the initial repository.
9. Validate with outbound networking disabled before claiming offline support.
10. Use clear failures. A missing wheel, npm tarball, binary, browser artifact, source archive, or checksum must stop the install with a message naming the missing item.

## Expected Workflow

### Phase 1: Discovery

Do not modify upstream source.

Produce:

- `reports/dependency-inventory.md`
- `reports/network-access-inventory.md`
- `reports/binary-inventory.md`
- `reports/browser-runtime-inventory.md`
- `reports/submodule-and-source-inventory.md`
- `reports/license-redistribution-review.md`
- `reports/proposed-architecture.md`
- `reports/phase-1-open-questions.md`

Discovery should inspect:

- Python package files such as `pyproject.toml`, `requirements*.txt`, lockfiles, setup files, and installer scripts
- Node files such as `package.json`, lockfiles, workspace definitions, frontend packages, and scripts
- Dockerfiles, Compose files, CI workflows, shell scripts, Python scripts, and installer/bootstrap logic
- Submodules, GitHub references, curl/wget calls, package-manager calls, browser installers, runtime plugin downloads, model downloads, and MCP/provider integration code

### Phase 2: Vendoring

Create the vendor structure and collect redistributable artifacts.

Required outputs:

- `vendor/python/`
- `vendor/node/`
- `vendor/binaries/`
- `vendor/browser/`
- `vendor/source/`
- `manifests/python.lock`
- `manifests/node.lock`
- `manifests/binaries.lock`
- `manifests/browser.lock`
- `manifests/source.lock`
- `manifests/licenses.lock`
- `manifests/checksums.sha256`
- `reports/redistribution-exceptions.md`

Every artifact must be pinned by version and checksum.

### Phase 3: Offline Installer

Create local-only install scripts.

Required scripts:

- `scripts/bootstrap.sh`
- `scripts/install-offline.sh`
- `scripts/verify-deps.sh`
- `scripts/verify-offline.sh`
- `scripts/build-bundle.sh`

Installer requirements:

- Must prefer local artifacts only.
- Must refuse implicit downloads.
- Must set package-manager options that disable network fallback where possible.
- Must print the exact missing artifact and expected path when failing.
- Must keep user-editable config separate from vendored artifacts.

### Phase 4: Validation

Validate from a clean environment with outbound networking disabled.

Required outputs:

- `reports/offline-install-test.md`
- `reports/offline-runtime-smoke-test.md`
- `reports/checksum-verification.md`
- `reports/final-gap-list.md`

### Phase 5: Distribution and Containerization

Produce distributable artifacts.

Expected outputs:

- a release archive of the self-contained repository
- optional Dockerfile and Compose setup
- optional offline container image build path
- release notes listing supported platforms, known exceptions, and manual prerequisites

### Phase 6: Upstream Maintenance

Create a controlled update workflow.

Required scripts/docs:

- `scripts/update-upstream.sh`
- `scripts/refresh-vendor-artifacts.sh`
- `scripts/diff-dependency-surface.sh`
- `docs/upstream-update-workflow.md`

The update workflow must detect new dependency sources, new network calls, changed licenses, changed checksums, and changed installer behavior.

## Completion Standard

Do not report the project complete until:

- offline dependency verification passes
- offline install passes
- outbound networking is disabled during validation
- all vendored artifacts are checksummed
- all non-vendored exceptions are documented
- secrets are absent from the repository
- update workflow exists and has been tested on at least one upstream refresh simulation
