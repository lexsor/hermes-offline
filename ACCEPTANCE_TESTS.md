# Acceptance Tests

## Test Philosophy

Offline support must be proven, not assumed.

The final repository is accepted only after installation and verification pass in a clean environment with outbound networking disabled.

## Required Test Environments

At minimum, test on a clean native Windows 10/11 x64 target with CPython 3.11 compatibility, as approved during discovery.

Recommended:

- clean Windows x64 VM
- no pre-existing Python virtual environment
- no pre-existing Node dependencies
- no global package-manager cache relied upon
- outbound network blocked
- repository copied in as the only application input

## Phase 1 Acceptance: Discovery

Pass criteria:

- `reports/dependency-inventory.md` exists and covers Python, Node, binary, browser, source, container, CI, plugin, provider, and runtime dependencies.
- `reports/network-access-inventory.md` lists every discovered network access path, including install scripts, package managers, browser downloads, GitHub downloads, runtime plugin/model/provider fetches, and container builds.
- `reports/license-redistribution-review.md` identifies license and redistribution status for each dependency class.
- `reports/proposed-architecture.md` explains the final repository structure and tradeoffs.
- No upstream Hermes source files were modified.

## Phase 2 Acceptance: Vendoring

Pass criteria:

- Every redistributable required artifact exists under `vendor/`.
- Every vendored artifact appears in a manifest.
- Every vendored artifact has a SHA-256 checksum.
- `reports/redistribution-exceptions.md` lists every non-vendored required or optional artifact.
- Running checksum verification succeeds.

Windows requirement:

Phase 3 must provide a native Windows entry point (PowerShell) in addition to the required cross-platform verification script named in `AGENTS.md`.

Expected result:

- exits with code 0
- prints summary of verified artifacts
- reports no missing required artifacts

## Phase 3 Acceptance: Offline Installer

Pass criteria:

- Offline install completes from local artifacts only.
- Package managers are configured for offline/local-only behavior.
- Missing artifacts fail clearly.
- No secrets are required in Git.
- External services are configured through examples and health checks.

Windows requirement:

Phase 3 must provide a native Windows offline installer entry point (PowerShell) and retain the required script names from `AGENTS.md` where applicable.

Expected result:

- creates local runtime environment
- installs Python dependencies from `vendor/python/`
- installs Node dependencies from `vendor/node/` or an approved offline cache
- installs or links binaries from `vendor/binaries/`
- installs or configures browser runtime from `vendor/browser/`, if required
- refuses online fallback

## Phase 4 Acceptance: Network-Blocked Validation

Pass criteria:

- Outbound networking is blocked by the test harness.
- Offline dependency verification passes.
- Offline install passes.
- Hermes smoke test starts successfully.
- Any configured external local services are checked through local endpoints only.

Windows requirement:

The Phase 4 sequence must be executable from native Windows PowerShell and must run with public outbound networking blocked.

Network assertions:

- DNS resolution to public hosts should fail or be blocked.
- HTTP/HTTPS access to public package registries should fail or be blocked.
- The install must still succeed.
- No command should attempt to use a public registry during the offline path.

## Missing Artifact Test

Deliberately move one required vendored artifact out of the repository and rerun install.

Pass criteria:

- install fails
- error names the exact missing artifact
- error names the manifest that referenced it
- error does not attempt to download the artifact

## Checksum Failure Test

Deliberately alter one vendored artifact and rerun verification.

Pass criteria:

- verification fails
- error names the artifact with mismatched checksum
- install refuses to continue

## Secret Hygiene Test

Run a repository scan for secret-like values.

Pass criteria:

- no committed API keys, provider tokens, private keys, real `.env` files, or credential stores
- only example placeholders are present

## Update Workflow Test

Run a controlled upstream refresh simulation.

Pass criteria:

- current upstream revision is recorded
- dependency surface diff is generated
- new network access paths are reported
- changed checksums are intentional and reviewed
- licenses are refreshed
- offline validation is rerun after update

## Final Acceptance Checklist

- [ ] Phase 1 reports complete
- [ ] upstream source preserved with minimal modifications
- [ ] all required redistributable dependencies vendored
- [ ] manifests and checksums generated
- [ ] offline installer created
- [ ] missing artifact failure tested
- [ ] checksum failure tested
- [ ] outbound network disabled during validation
- [ ] offline install tested from clean environment
- [ ] smoke test documented and passing
- [ ] secrets absent from Git
- [ ] redistribution exceptions documented
- [ ] upstream update workflow documented and tested
