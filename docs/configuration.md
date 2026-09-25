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

## Point Hermes at your model server

The offline build needs an inference provider on your own network: any OpenAI-compatible server, for example vLLM, llama.cpp `server`, Ollama or NVIDIA NIM on a GPU machine. Configure it **before the first desktop launch**. Without a provider, the desktop opens on upstream's setup screen, whose options (Nous Portal, "download a model", cloud API keys) all need the Internet, and whose checks try to reach `inference-api.nousresearch.com` and `openrouter.ai` (gap G18).

```powershell
.\scripts\configure-provider.ps1 -BaseUrl http://<server>:8000/v1 -Model <model-id>
```

- It writes `model.provider: custom`, `model.base_url` and `model.default` through the installed Hermes (`hermes config set`), then calls `GET <BaseUrl>/models` on the local network. It confirms the server answers and lists `<model-id>`, and reports the context window the server advertises.
- **Context window:** Hermes Agent refuses models with less than **64,000 tokens** of context. Serve the model with at least that (vLLM `--max-model-len 65536` or more; llama.cpp `-c 65536`; Ollama `OLLAMA_CONTEXT_LENGTH=65536`). Pass `-ContextLength <n>` if the server does not advertise its window; with models.dev disabled offline, Hermes otherwise relies on the server.
- **API key:** for a server that requires one, pass `-ApiKeyEnv <NAME>` and put `<NAME>=<key>` in `<offline home>\.env`. The script never writes the key itself. No-auth servers need nothing; Hermes sends a placeholder.
- Rerunning it with new values updates the provider. `-SkipCheck` saves without contacting the server.
- `-Model` must be the exact id from the server's `/v1/models` list. For vLLM that is the `--served-model-name`, or the model path if none was given.

For a GPU box on the LAN, the base URL is its address and port, for example `http://192.168.1.50:8000/v1`. A public IP address produces a warning, because an offline deployment should not need one.
