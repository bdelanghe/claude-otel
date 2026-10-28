{ config, lib, pkgs, ... }:

# claude-otel: Claude Code telemetry kept on the machine. A local OpenTelemetry collector (OTLP on 127.0.0.1:4317/4318)
# fans out to a local OpenObserve (storage + SQL/HTTP query API), rotated JSONL files (the zero-dependency fallback),
# and any extra exporters you add; Claude Code's OTEL_* environment points at it, in the session and in settings.json.
# Spans from the browsing service (`browsing.serviceName`, e.g. a tab-focus extension) go to their own OpenObserve
# stream, so URLs can get their own retention.
let
  cfg = config.programs.claudeOtel;
  extra = lib.concatMapStrings (n: n + ", ") cfg.extraExporterNames;
  # extraExportersYaml is written at column 0; it sits under `exporters:`, two spaces in.
  extraYaml = lib.optionalString (cfg.extraExportersYaml != "")
    (lib.concatMapStrings (l: (if l == "" then "" else "  " + l) + "\n") (lib.splitString "\n" (lib.removeSuffix "\n" cfg.extraExportersYaml)));
  stateDir = "${config.home.homeDirectory}/.local/state";
  authFile = "${stateDir}/openobserve/auth.env";

  # The collector config — production-shaped: memory_limiter + batch processors
  # on every pipeline, OTLP in, sinks: the openobserve backend (storage +
  # SQL/HTTP query API — the agent-facing surface), rotated JSONL files (the
  # zero-dependency fallback any process can read), and `extraExporters*`.
  # The Authorization header is env-expanded at start from the
  # locally-generated credential, never stored in the nix store.
  #
  # Extra exporters FAN OUT rather than switch over: producers change nothing,
  # every store sees byte-identical traffic, and they can be compared for as
  # long as it takes before one is torn down. Backing one out is deleting it
  # from extraExporterNames.
  collectorConfig = pkgs.writeText "otelcol-claude.yaml" (''
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 127.0.0.1:4317 }
          http: { endpoint: 127.0.0.1:4318 }
    processors:
      memory_limiter: { check_interval: 1s, limit_mib: 256, spike_limit_mib: 64 }
      batch: { timeout: 5s }

      # BROWSING IS SPLIT OFF THE MAIN TRACE STREAM, and the reason is
      # retention rather than tidiness.
      #
      # Browsing spans carry the tab URL and title — the single most
      # sensitive thing anything on a machine emits, even after an extension
      # drops query strings and fragments. Every other trace
      # here is token spend, tool calls and app focus, which are worth keeping
      # for months because that is the point of the witnesses.
      #
      # OpenObserve applies `data_retention` PER STREAM, and every trace
      # currently lands in one stream called `default`. So a retention policy
      # for URLs is impossible until they have a stream of their own — this
      # split is the mechanism, not a preference.
      filter/drop-browsing:
        error_mode: ignore
        traces:
          span:
            - 'resource.attributes["service.name"] == "${cfg.browsing.serviceName}"'
      filter/only-browsing:
        error_mode: ignore
        traces:
          span:
            - 'resource.attributes["service.name"] != "${cfg.browsing.serviceName}"'
    exporters:
      otlphttp/openobserve:
        endpoint: http://127.0.0.1:5080/api/default
        headers: { Authorization: "Basic ''${env:OO_TOKEN}" }
      # Same endpoint, different stream. `stream-name` is how OpenObserve's
      # OTLP route chooses one; without it everything defaults to `default`.
      otlphttp/openobserve-browsing:
        endpoint: http://127.0.0.1:5080/api/default
        headers:
          Authorization: "Basic ''${env:OO_TOKEN}"
          stream-name: browsing
  '' + extraYaml + ''
      file/metrics:
        path: ${stateDir}/otelcol/metrics.jsonl
        rotation: { max_megabytes: 20, max_backups: 2 }
      file/traces:
        path: ${stateDir}/otelcol/traces.jsonl
        rotation: { max_megabytes: 20, max_backups: 2 }
      file/logs:
        path: ${stateDir}/otelcol/logs.jsonl
        rotation: { max_megabytes: 20, max_backups: 2 }
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlphttp/openobserve, ${extra}file/metrics]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlphttp/openobserve, ${extra}file/logs]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, filter/drop-browsing, batch]
          exporters: [otlphttp/openobserve, ${extra}file/traces]

        # Browsing, to its own stream and NOT to the extra exporters.
        #
        # Shipping URLs to a second store with its own unbounded retention
        # would defeat the retention set here — a policy that covers one sink
        # of three is not a policy. If an extra store ever needs them, that is
        # a decision to make deliberately rather than by inheriting a default
        # pipeline.
        #
        # file/traces stays: it rotates at 20MB with 2 backups, so it is
        # already self-bounding, and it is the local copy that makes the
        # collector debuggable when OpenObserve is down.
        traces/browsing:
          receivers: [otlp]
          processors: [memory_limiter, filter/only-browsing, batch]
          exporters: [otlphttp/openobserve-browsing, file/traces]
  '');

  collectorWrapper = pkgs.writeShellScript "otelcol-claude" ''
    set -a; . ${authFile}; set +a
    export OO_TOKEN
    exec ${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config=${collectorConfig}
  '';

  openobserveWrapper = pkgs.writeShellScript "openobserve-local" ''
    set -a; . ${authFile}; set +a
    export ZO_ROOT_USER_EMAIL="$OO_EMAIL" ZO_ROOT_USER_PASSWORD="$OO_PASSWORD"
    export ZO_DATA_DIR="${stateDir}/openobserve/data"
    export ZO_HTTP_ADDR=127.0.0.1 ZO_HTTP_PORT=5080
    # Pin the internal querier address to loopback. Left unset, openobserve
    # registers the node at whatever LAN address it holds at startup and keeps
    # calling itself there — so a DHCP lease change makes every search time out
    # ("tcp connect error … :5081") while ingestion carries on fine, which
    # reads as "the witnesses are empty" rather than as a network fault. This
    # is a single-node install on one machine; it never needs to be reachable
    # at a routable address.
    export ZO_GRPC_ADDR=127.0.0.1
    export ZO_TELEMETRY=false
    # RETENTION. Without this, openobserve keeps every stream FOREVER — its
    # default is 0, meaning no expiry — and this instance ingests real PII:
    # prompts, tool arguments, file paths and URLs, off three OTLP pipelines.
    # Applies as the DEFAULT for streams with no per-stream override; a stream
    # with an explicit `data_retention` keeps it. Set your own number
    # (openobserve.retentionDays).
    export ZO_DATA_RETENTION_DAYS=${toString cfg.openobserve.retentionDays}
    exec ${pkgs.openobserve}/bin/openobserve
  '';

  # Defined once, delivered twice — see the two consumers below. A second
  # literal here is how the shell and settings.json routes would drift apart.
  telemetryEnv = {
    CLAUDE_CODE_ENABLE_TELEMETRY = "1";
    OTEL_METRICS_EXPORTER = "otlp";
    # Default metric export cadence is 60s, which makes anything reading the
    # meters lag a fresh session by over a minute. 5s is cheap against a
    # localhost collector.
    OTEL_METRIC_EXPORT_INTERVAL = "5000";
    OTEL_LOGS_EXPORT_INTERVAL = "5000";
    OTEL_LOGS_EXPORTER = "otlp";
    OTEL_EXPORTER_OTLP_PROTOCOL = "grpc";
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4317";
    # Prompt text in the user_prompt events. Off by default upstream because
    # it puts what you typed into the telemetry pipeline; on here because the
    # pipeline is this machine — a collector on loopback writing to an
    # openobserve on loopback.
    OTEL_LOG_USER_PROMPTS = "1";
  };

  cfgFile = cfg.claudeSettingsFile;
in
{
  options.programs.claudeOtel = {
    enable = lib.mkEnableOption "a local OTel collector + OpenObserve for Claude Code telemetry, and the OTEL_* environment pointing at it";
    claudeSettingsFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude/settings.json";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.claude/settings.json"'';
      description = "The Claude Code settings.json whose `env` gets the telemetry variables merged in at each switch (created as {} if missing; other keys kept).";
    };
    openobserve = {
      rootEmail = lib.mkOption { type = lib.types.str; default = "admin@localhost"; description = "Root user of the local OpenObserve (its password is generated once into ~/.local/state/openobserve/auth.env, 0600)."; };
      retentionDays = lib.mkOption { type = lib.types.ints.positive; default = 30; description = "Default stream retention (ZO_DATA_RETENTION_DAYS); the data is prompts, tool arguments, paths and URLs."; };
    };
    browsing.serviceName = lib.mkOption { type = lib.types.str; default = "focus-observer-tabs"; description = "service.name of the spans routed to the separate `browsing` stream."; };
    extraExportersYaml = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra collector exporters, as YAML at column 0 (the module indents them under `exporters:`). Name each in extraExporterNames.";
    };
    extraExporterNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Exporters from extraExportersYaml added to the metrics, logs and (non-browsing) traces pipelines.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Claude Code (and every OTLP-speaking tool)
    # export here. The collector is the single ingest door; openobserve is the
    # backend with storage and a query API. UI: http://localhost:5080 —
    # credentials in ~/.local/state/openobserve/auth.env.
    home.sessionVariables = telemetryEnv;

    # Route two: the same variables written into claude's own settings, because
    # a login shell is not where every claude session comes from. A session
    # spawned by a daemon inherits that daemon's environment — a snapshot of
    # whichever shell first started it, which `home-manager switch` cannot
    # reach; the same is true of anything launchd, cron, or a long-lived
    # supervisor starts. settings.json travels with the config dir instead of
    # the process tree, so it reaches all of them.
    #
    # Additive merge via jq's `*`: settings.json is hand-maintained state (and
    # Claude Code's own), and `*` recurses into objects, so other .env keys
    # survive.
    #
    # Note: settings.json .env OVERRIDES a real environment variable. Harmless
    # for telemetry; it is why nothing with an emergency-bypass story (e.g.
    # ANTHROPIC_BASE_URL) belongs here.
    home.activation.claudeTelemetryEnv =
      config.lib.dag.entryAfter [ "writeBoundary" ] ''
        f="${cfgFile}"
        mkdir -p "$(dirname "$f")"
        [ -f "$f" ] || echo '{}' > "$f"
        tmp=$(mktemp "''${f}.XXXXXX")
        ${pkgs.jq}/bin/jq --argjson add '${builtins.toJSON { env = telemetryEnv; }}' \
          '. * $add' "$f" > "$tmp" && mv "$tmp" "$f"
      '';

    home.packages = [ pkgs.opentelemetry-collector-contrib pkgs.openobserve ];

    # Machine-local credential, generated once at activation, 0600, outside the
    # store. Both daemons and any querying agent read it from here.
    home.activation.openobserveAuth =
      config.lib.dag.entryAfter [ "writeBoundary" ] ''
        mkdir -p "${stateDir}/otelcol" "${stateDir}/openobserve/data"
        if [ ! -f "${authFile}" ]; then
          # openobserve enforces complexity: upper+lower+digit+special. Prefix
          # guarantees all classes; the hex tail carries the entropy.
          pass="Aa1!$(/usr/bin/openssl rand -hex 24)"
          email=${lib.escapeShellArg cfg.openobserve.rootEmail}
          umask 077
          {
            echo "OO_EMAIL=$email"
            echo "OO_PASSWORD=$pass"
            echo "OO_TOKEN=$(printf '%s' "$email:$pass" | /usr/bin/base64)"
          } > "${authFile}"
        fi
      '';

    launchd.agents.openobserve = {
      enable = true;
      config = {
        ProgramArguments = [ "${openobserveWrapper}" ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${stateDir}/openobserve/out.log";
        StandardErrorPath = "${stateDir}/openobserve/err.log";
      };
    };


    launchd.agents.otelcol-claude = {
      enable = true;
      config = {
        ProgramArguments = [ "${collectorWrapper}" ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${stateDir}/otelcol/out.log";
        StandardErrorPath = "${stateDir}/otelcol/err.log";
      };
    };
  };
}
