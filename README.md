# Hermes Self-Contained Codex Handoff

This package is a Codex-ready handoff for building a self-contained, offline-capable distribution of the NousResearch Hermes Agent project.

Target upstream:

- Repository: https://github.com/NousResearch/hermes-agent
- Product name in this handoff: Hermes Agent
- Desired output: a separate distribution repository that preserves upstream Hermes with minimal source changes while vendoring redistributable dependencies and providing offline bootstrap, install, verification, and update workflows.

## Objective

Create a repository that can be cloned or copied to a fresh supported Linux host and installed without downloading application dependencies from the Internet.

The repository should include all redistributable artifacts required to reconstruct the runtime:

- Python wheels and source distributions
- Node package tarballs or offline package cache
- External binaries such as ripgrep and ffmpeg, where redistributable
- Browser/runtime artifacts such as Playwright/Chromium, where required and redistributable
- Source archives for dependencies that cannot be represented as normal package artifacts
- Lockfiles, checksums, manifests, and license metadata
- Offline bootstrap/install/verification scripts
- A controlled upstream-update workflow

The repository should not blindly commit generated runtime directories such as `.venv/`, `node_modules/`, cache directories, local secrets, user config, or machine-specific state.

## How to Use This Handoff

Give this folder to Codex as the project brief. Start by asking Codex to complete Phase 1 only.

Recommended first prompt:

```text
Use the files in this handoff package as the governing instructions. Start with Phase 1 only: discovery and audit. Do not modify upstream Hermes source during Phase 1. Produce the required dependency, network, licensing, and architecture reports, then stop for review.
```

After Phase 1 is reviewed, continue phase by phase.

## Included Files

- `AGENTS.md`: operating instructions and guardrails for Codex
- `REQUIREMENTS.md`: functional and non-functional requirements
- `ARCHITECTURE.md`: suggested distribution architecture and directory layout
- `ACCEPTANCE_TESTS.md`: acceptance criteria and offline validation tests
- `SECURITY.md`: secret handling, supply-chain, checksum, and network controls
- `REPOSITORY_STRUCTURE.md`: suggested final repository tree

## Phase Summary

1. Discovery: audit Hermes and produce reports; no upstream source modifications.
2. Vendoring: collect redistributable dependency artifacts and generate manifests.
3. Offline installer: create local-only bootstrap/install scripts with fail-fast behavior.
4. Validation: test installation and startup with outbound networking disabled.
5. Distribution/containerization: package archives and optional container images.
6. Upstream maintenance: create a controlled update workflow and drift detection.

## Definition of Done

The work is complete only when a fresh supported host can install and verify Hermes from the self-contained repository with outbound network access disabled, and any non-vendored exception is documented with a clear reason, owner action, and failure mode.
