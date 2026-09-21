# Security and Supply-Chain Requirements

## Security Goals

The distribution must be reproducible, inspectable, and safe to install in an offline or restricted environment.

Security priorities:

- no committed secrets
- no silent network access
- checksum verification before install
- clear artifact provenance
- documented license and redistribution status
- controlled update workflow
- minimal upstream source modifications

## Secret Handling

Never commit:

- API keys
- provider tokens
- private keys
- passwords
- real `.env` files
- local credential stores
- generated user config
- SSH keys
- cloud credentials

Allowed:

- `config/env.example`
- placeholder values such as `REPLACE_ME`
- documentation describing required environment variables

Recommended ignore patterns:

```gitignore
.env
.env.*
!*.example
config/*.local.*
config/secrets.*
secrets/
credentials/
*.pem
*.key
*.p12
*.pfx
```

## Artifact Provenance

Each vendored artifact must record:

- original source URL
- upstream package name
- version or immutable revision
- download date
- checksum
- license
- redistribution status
- reason for inclusion

Prefer SHA-256 checksums.

## Network Access Policy

Offline install commands must not access the public Internet.

Online access is allowed only in clearly named maintenance commands, such as:

- `scripts/update-upstream.sh`
- `scripts/refresh-vendor-artifacts.sh`
- license refresh scripts

Offline scripts must fail if they detect an attempted network fallback.

Potential network sources to audit:

- package managers
- browser installers
- Git submodules
- shell scripts using `curl` or `wget`
- Python code fetching models, plugins, tools, schemas, or provider metadata
- Node postinstall scripts
- Docker builds
- CI workflows
- runtime plugin managers

## Package Manager Controls

Python installer should use local-only behavior:

- no online index
- local wheel/source directory
- locked versions
- checksum verification where practical

Node installer should use local/offline behavior:

- locked versions
- local tarballs or approved immutable cache
- no registry fallback
- postinstall scripts reviewed for network behavior

Browser runtime installation should disable online downloads and use vendored artifacts or documented exceptions.

## Checksums

Before install:

1. verify all manifest files exist
2. verify all required artifacts exist
3. verify all checksums match
4. abort on mismatch

Do not continue with warnings for required artifacts.

## License and Redistribution Review

Classify every dependency as one of:

- redistributable
- redistributable with notice
- source-only redistribution required
- not redistributable
- unknown, requires review

Unknown status is not acceptable for final release. It must either be resolved or documented as a release blocker.

## External Services

Do not bundle Honcho, MCP servers, provider APIs, model services, databases, or user-specific services in the initial distribution.

Instead provide:

- example config
- health checks
- documentation
- clear startup errors when a configured service is missing

## Update Security

Upstream updates must:

- record old and new upstream commits
- show source diffs
- show dependency diffs
- show license diffs
- show checksum diffs
- detect new network access
- rerun offline validation

No upstream update should be accepted only because it installs successfully online.

## Required Security Reports

- `reports/network-access-inventory.md`
- `reports/license-redistribution-review.md`
- `reports/redistribution-exceptions.md`
- `reports/checksum-verification.md`
- `reports/secret-scan.md`
- `reports/update-security-review.md`
