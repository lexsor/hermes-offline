# Offline configuration

Keep user configuration and credentials outside this repository. Merge the examples from `config/` into the user-owned offline Hermes home (default `%LOCALAPPDATA%\OfflineHermes-home`) and replace placeholders locally. `config/hermes.example.yaml` uses upstream's real keys; `upstream/hermes-agent/cli-config.yaml.example` documents the rest.

The base profile assumes inference providers, Honcho, MCP servers, databases, and model servers are externally managed. Prefer loopback or explicitly approved LAN endpoints. An unavailable service must be fixed or disabled; it must never cause `pip`, `uv`, `uvx`, `npm`, `npx`, Git, or a browser downloader to run.

The installed launchers set `HERMES_DISABLE_LAZY_INSTALLS=1`, `UV_OFFLINE=1`, and `PIP_NO_INDEX=1`. Do not remove those settings from an offline deployment.

Keep `updates.check: false` in the offline home's `config.yaml`. Passive update checks otherwise call `api.github.com` from `hermes --version` and the banner. `scripts/verify-offline.ps1` fails if the check is enabled.

Also keep these two settings in the offline home. Without them, the desktop backend (`hermes serve`) downloads a model catalog from `hermes-agent.nousresearch.com` (falling back to `raw.githubusercontent.com`) and the `models.dev` registry. The Phase 4 Azure run recorded those lookups each time the desktop backend started.

```yaml
model_catalog:
  enabled: false
models_dev:
  url: "http://127.0.0.1:9/offline-hermes-models-dev-disabled"
```

`models.dev` has no on/off switch, only a mirror URL. A closed loopback port makes the fetch fail at once, without any DNS lookup, and Hermes falls back to cached or built-in model data. As a result, offline the desktop shows no per-provider model lists or registry metadata; set the model name and `context_length` for local models explicitly. New installs seed both settings. The installer warns if an existing `config.yaml` lacks them, and `scripts/verify-offline.ps1` fails until they are present.
