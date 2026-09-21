# Codex Start Prompt

Use this prompt to start the implementation task in Codex.

```text
Use the handoff files in this directory as the governing instructions for this project.

Objective:
Build a self-contained/offline-capable distribution repository for NousResearch Hermes Agent: https://github.com/NousResearch/hermes-agent

Start with Phase 1 only.

Phase 1 requirements:
- Clone or import upstream Hermes at a pinned commit.
- Audit all dependency sources.
- Audit all install-time and runtime network access.
- Audit Python, Node, binary, browser/runtime, source, container, CI, plugin, provider, Honcho, and MCP integration surfaces.
- Do not modify upstream Hermes source during Phase 1.
- Produce the required Phase 1 reports listed in AGENTS.md.
- Identify redistribution and licensing concerns.
- Propose the final repository architecture.
- Stop after Phase 1 and wait for review.

Guardrails:
- Missing dependencies must become explicit failures in later phases, never silent Internet downloads.
- Keep secrets out of Git.
- Preserve upstream Hermes with minimal modifications.
- Treat Honcho and MCP servers as external configurable services unless a later phase explicitly approves bundling them.
```
