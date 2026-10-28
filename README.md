# claude-otel

Claude Code telemetry kept on the machine, as a Home Manager module (launchd, macOS):

- an **OpenTelemetry collector** (`otelcol-contrib`) on `127.0.0.1:4317` (gRPC) / `:4318` (HTTP) with
  memory_limiter + batch on every pipeline, fanning out to
- a local **OpenObserve** on `127.0.0.1:5080` (storage + SQL/HTTP query API; credential generated once into
  `~/.local/state/openobserve/auth.env`, 0600, never in the store; default retention `openobserve.retentionDays`),
- rotated **JSONL files** in `~/.local/state/otelcol/` (the zero-dependency fallback), and
- any **extra exporters** you add (`extraExportersYaml` + `extraExporterNames`).

Spans whose `service.name` is `browsing.serviceName` (URLs and titles) go to their own OpenObserve stream and not to
the extra exporters, so they can carry their own retention. Claude Code's `CLAUDE_CODE_ENABLE_TELEMETRY` / `OTEL_*`
variables (5 s export, prompt text included — the pipeline never leaves loopback) go into the session environment
and are merged into `claudeSettingsFile`'s `env`, because a daemon-spawned session never sees a login shell.

```nix
inputs.claude-otel = { url = "github:bdelanghe/claude-otel"; inputs.nixpkgs.follows = "nixpkgs"; inputs.home-manager.follows = "home-manager"; };
# modules = [ claude-otel.homeManagerModules.default ];
programs.claudeOtel = { enable = true; openobserve.rootEmail = "me@localhost"; };
```

## Checks

`nix flake check` (macOS): the module under Home Manager, and the rendered collector config validated by
`otelcol-contrib validate`.
