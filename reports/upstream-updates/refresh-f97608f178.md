# Vendor refresh for upstream f97608f178

## Vendor refresh plan

Python wheels: 68 selected; 0 to add, 0 to remove. npm tarballs: 1029 selected; 1 to add, 0 to remove.

### npm tarballs to add (1)

- `lucide-react@0.577.0` (ISC)

### Pinned runtimes

- ok: electron (browser.lock: 40.10.2) vs npm electron 40.10.2
- ok: get-windows-native (binaries.lock: 9.3.0-napi9) vs npm get-windows 9.3.0
- ok: lightningcss-source (source.lock: 1.32.0, 1.33.0) vs npm lightningcss 1.32.0, 1.33.0
- ok: electron-builder-7zip (binaries.lock: 1.0.0) vs npm app-builder-lib 26.15.3 (reviewed against 26.15.3)
- ok: electron-builder-nsis (binaries.lock: 3.0.4.1) vs npm app-builder-lib 26.15.3 (reviewed against 26.15.3)
- ok: electron-builder-nsis-resources (binaries.lock: 3.4.1) vs npm app-builder-lib 26.15.3 (reviewed against 26.15.3)
- ok: electron-builder-wix (binaries.lock: 4.0.0.5512.2) vs npm app-builder-lib 26.15.3 (reviewed against 26.15.3)

### Notes

- socksio is reached but excluded by the profile: Reached through httpx[socks]; not vendored in Phase 2, so httpx has no SOCKS proxy support offline (gap G19). Remove this entry to vendor it.

