# Requirements

## Goal

Create a self-contained/offline-capable distribution repository for NousResearch Hermes Agent.

The distribution must allow a fresh supported Linux host to install and verify Hermes without downloading application dependencies from the Internet.

## Scope

In scope:

- Audit upstream Hermes dependencies and install/runtime behavior.
- Vendor redistributable dependency artifacts.
- Generate lockfiles, manifests, checksums, and license records.
- Build offline bootstrap/install/verification scripts.
- Preserve upstream Hermes with minimal source modifications.
- Support configuration for external local services such as Honcho and MCP servers.
- Validate installation with outbound networking disabled.
- Document redistribution exceptions.
- Provide a controlled upstream-update workflow.

Out of scope for the initial version:

- Bundling external local services such as Honcho or arbitrary MCP servers.
- Bundling user secrets, API keys, provider credentials, private model weights, or private repositories.
- Guaranteeing support for every operating system before platform requirements are discovered.
- Rewriting Hermes architecture unless an upstream behavior prevents offline operation and cannot be wrapped.

## Functional Requirements

### FR1: Upstream Preservation

The distribution must keep upstream Hermes source recognizable and minimally modified.

Preferred methods:

- Keep upstream source under `upstream/hermes-agent/` or `hermes/`.
- Use patch files under `patches/` for unavoidable changes.
- Document every patch with purpose, risk, and upstream rebase considerations.

### FR2: Dependency Inventory

Codex must produce a complete dependency inventory covering:

- Python dependencies
- Node dependencies
- system binaries
- browser/runtime dependencies
- Git submodules or source dependencies
- installer-time downloads
- runtime downloads
- CI/container dependencies
- optional plugin/provider/MCP dependencies

### FR3: Vendored Artifacts

The repository must vendor all redistributable artifacts required for offline install.

Each artifact must include:

- name
- version or immutable revision
- source URL
- local path
- license
- checksum
- reason it is needed
- install phase where it is consumed

### FR4: Offline Install

The install path must use only local artifacts.

It must fail if:

- a required artifact is missing
- a checksum does not match
- a package manager attempts a network fallback
- an expected lockfile is missing
- a runtime installer attempts to fetch from the Internet

### FR5: Network Guardrails

Install and validation scripts must explicitly disable, block, or detect network access.

No script may silently call:

- `curl`
- `wget`
- package registries
- browser download endpoints
- GitHub release downloads
- package manager online resolution
- remote install scripts

If network access is needed for a maintenance command, it must be isolated to update scripts and clearly labeled as online-only.

### FR6: Secrets

The repository must never contain:

- API keys
- provider tokens
- private keys
- `.env` files with real values
- local credential stores
- generated user config with secrets

Provide `config/env.example` and document required environment variables.

### FR7: External Services

Honcho, MCP servers, model services, databases, provider APIs, and other external services should be supported through configuration.

Initial distribution should include:

- example config
- expected endpoint shape
- health-check commands
- clear error messages when services are unavailable

It should not bundle external services unless a later phase explicitly approves that expansion.

### FR8: Manifests and Checksums

The repository must include:

- lockfiles for each dependency class
- SHA-256 checksums for vendored artifacts
- license manifest
- redistribution exception report
- upstream revision lock

### FR9: Controlled Updates

The repository must include a repeatable upstream-update workflow that:

- records current upstream commit
- pulls or imports a new upstream revision
- detects dependency changes
- refreshes vendored artifacts
- updates checksums and licenses
- runs offline validation
- documents manual review items

## Non-Functional Requirements

- Clear failure messages
- Reproducible install behavior
- Minimal upstream source changes
- Human-reviewable manifests
- Platform requirements documented
- No implicit Internet access during offline install
- No committed secrets
- Scripts should be understandable and maintainable

## Success Criteria

The project succeeds when:

1. A clean supported host can install Hermes from the repository without outbound Internet access.
2. Checksum verification passes before install.
3. Hermes can complete a documented smoke test using configured local/external services.
4. Missing artifacts produce explicit failures.
5. Non-redistributable items are documented as exceptions.
6. Upstream updates can be performed through a controlled workflow.
