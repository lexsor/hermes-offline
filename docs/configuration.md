# Offline configuration

Keep user configuration and credentials outside this repository. Merge the examples from `config/` into the user-owned offline Hermes home (default `%LOCALAPPDATA%\OfflineHermes-home`) and replace placeholders locally. `config/hermes.example.yaml` uses upstream's real keys; `upstream/hermes-agent/cli-config.yaml.example` documents the rest.

The base profile assumes inference providers, Honcho, MCP servers, databases, and model servers are externally managed. Prefer loopback or explicitly approved LAN endpoints. An unavailable service must be fixed or disabled; it must never cause `pip`, `uv`, `uvx`, `npm`, `npx`, Git, or a browser downloader to run.

The installed launchers set `HERMES_DISABLE_LAZY_INSTALLS=1`, `UV_OFFLINE=1`, and `PIP_NO_INDEX=1`. Do not remove those settings from an offline deployment.

Keep `updates.check: false` in the offline home's `config.yaml`. Passive update checks otherwise call `api.github.com` from `hermes --version` and the banner. `scripts/verify-offline.ps1` fails if the check is enabled.
