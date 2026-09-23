# Offline Hermes distribution

This repository builds a self-contained, offline-capable Windows x64 distribution of NousResearch Hermes Agent.

Target upstream:

- Repository: https://github.com/NousResearch/hermes-agent
- Product name in this handoff: Hermes Agent
- Supported Phase 3 profile: native Windows 10/11 x64, CPython 3.11, Node 26, and the Electron desktop application.

## Objective

Allow a clean supported Windows host to install Hermes without downloading application dependencies from the Internet.

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

## Install from local artifacts

From native Windows PowerShell:

```powershell
.\scripts\verify-deps.ps1
.\scripts\install-offline.ps1
.\scripts\verify-offline.ps1
```

The default destination is `%LOCALAPPDATA%\OfflineHermes`. See `docs/offline-install.md` for options and explicit profile limitations.

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

Phases 1 and 2 are complete. Phase 3 has been run on native Windows 11 x64: install and verification pass after fixing an Electron network fallback, a shared/online `HERMES_HOME` with a live update check, and stale venv paths (see `reports/phase-3-native-windows-run.md`). Phase 4 network-blocked validation on a clean VM has not started.

## Definition of Done

The work is complete only when a fresh supported host can install and verify Hermes from the self-contained repository with outbound network access disabled, and any non-vendored exception is documented with a clear reason, owner action, and failure mode.
