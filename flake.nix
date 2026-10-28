{
  description = "claude-otel: Claude Code telemetry kept on the machine — a local OpenTelemetry collector + OpenObserve, and the OTEL_* environment pointing at it (Home Manager module)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    # Only for the module-eval check; consumers already carry home-manager and should `follows` it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      lib = nixpkgs.lib;
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeManagerModules.default = import ./nix/module.nix;

      checks = forAll (pkgs: lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin (
        let
          hm = extra: (home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [ self.homeManagerModules.default { home = { username = "t"; homeDirectory = "/Users/t"; stateVersion = "24.11"; }; } extra ];
          }).config;
          on = hm {
            programs.claudeOtel = {
              enable = true;
              openobserve = { rootEmail = "me@example.test"; retentionDays = 7; };
              extraExportersYaml = ''
                otlphttp/extra:
                  endpoint: http://127.0.0.1:4399
                  encoding: json
              '';
              extraExporterNames = [ "otlphttp/extra" ];
            };
          };
          off = hm { };
          wrapper = builtins.head on.launchd.agents.otelcol-claude.config.ProgramArguments;
          oo = builtins.head on.launchd.agents.openobserve.config.ProgramArguments;
        in
        {
          # Under Home Manager: nothing by default; on, both agents, the session env, the settings.json merge and the credential step;
          # and the rendered collector config VALIDATES with otelcol-contrib itself, extra exporter in every non-browsing pipeline.
          module-eval =
            assert !(off.launchd.agents ? otelcol-claude && off.launchd.agents.otelcol-claude.enable) && !(off.home.sessionVariables ? OTEL_EXPORTER_OTLP_ENDPOINT);
            assert on.home.sessionVariables.OTEL_EXPORTER_OTLP_ENDPOINT == "http://localhost:4317";
            assert lib.hasInfix "/Users/t/.claude/settings.json" on.home.activation.claudeTelemetryEnv.data;
            assert lib.hasInfix "email=me@example.test" on.home.activation.openobserveAuth.data;
            pkgs.runCommand "claude-otel-module-eval" { nativeBuildInputs = [ pkgs.opentelemetry-collector-contrib pkgs.yq-go ]; } ''
              conf=$(grep -o '/nix/store/[^ ]*-otelcol-claude.yaml' ${wrapper})
              OO_TOKEN=x otelcol-contrib validate --config="$conf"
              for p in metrics logs traces; do yq -e ".service.pipelines.$p.exporters | contains([\"otlphttp/extra\"])" "$conf" >/dev/null; done
              ! yq -e '.service.pipelines["traces/browsing"].exporters | contains(["otlphttp/extra"])' "$conf" >/dev/null
              grep -q 'ZO_DATA_RETENTION_DAYS=7' ${oo}
              grep -q 'ZO_HTTP_ADDR=127.0.0.1' ${oo}
              touch $out
            '';
        }));
    };
}
