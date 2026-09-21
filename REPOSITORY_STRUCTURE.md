# Suggested Repository Directory Structure

Use this as the initial target structure for the self-contained Hermes distribution repository.

```text
hermes-self-contained/
├── AGENTS.md
├── README.md
├── REQUIREMENTS.md
├── ARCHITECTURE.md
├── ACCEPTANCE_TESTS.md
├── SECURITY.md
├── .gitignore
├── upstream/
│   └── hermes-agent/
├── patches/
│   ├── README.md
│   ├── series
│   └── 0001-example.patch
├── vendor/
│   ├── README.md
│   ├── python/
│   │   ├── wheels/
│   │   └── sdists/
│   ├── node/
│   │   ├── tarballs/
│   │   └── offline-cache/
│   ├── binaries/
│   │   ├── linux-x86_64/
│   │   └── README.md
│   ├── browser/
│   │   ├── playwright/
│   │   └── chromium/
│   └── source/
│       └── README.md
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
│   │   └── providers.example.yaml
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
│   ├── proposed-architecture.md
│   ├── phase-1-open-questions.md
│   ├── redistribution-exceptions.md
│   ├── offline-install-test.md
│   ├── offline-runtime-smoke-test.md
│   ├── checksum-verification.md
│   ├── secret-scan.md
│   └── final-gap-list.md
└── docs/
    ├── offline-install.md
    ├── configuration.md
    ├── external-services.md
    ├── upstream-update-workflow.md
    └── troubleshooting.md
```

## Notes

- `upstream/hermes-agent/` should contain the pinned Hermes source.
- `vendor/` should contain immutable redistributable artifacts, not generated runtime directories.
- `manifests/` should be human-reviewable and generated or refreshed by scripts.
- `scripts/` should separate offline install commands from online maintenance commands.
- `config/` should contain examples only.
- `reports/` should preserve discovery and validation evidence.
- `patches/` should contain only unavoidable upstream changes.
