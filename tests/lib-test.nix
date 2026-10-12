# Evaluation tests for lib/default.nix (run by `nix flake check`).
{ pkgs, piNix }:

let
  inherit (pkgs) lib;

  # True when evaluating `value` (deeply) throws.
  throws = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  build = cfg: piNix.mkPi pkgs cfg;

  example = build {
    piVersion = "1.0.4";
    ownership = "merge";
    extensions = [
      "npm:pi-subagents"
      {
        source = "npm:@example/tools";
        skills = [ ];
      }
    ];
    mcpServers = {
      exa = {
        url = "https://mcp.exa.ai/mcp";
        bearerTokenEnvVar = "EXA_TOKEN";
        exposure = "direct";
      };
      fs = {
        command = "mcp-server-filesystem";
        args = [ "/workspace" ];
        cwd = "~/src";
      };
      odd.raw = {
        type = "http";
        url = "https://example.com/mcp";
      };
    };
    settings.defaultTools = [ "+codemode" ];
    env.PI_TELEMETRY = false;
  };

  cases = {
    "bearer token becomes an Authorization header" =
      example.mcpServers.exa.headers.Authorization == "Bearer \${EXA_TOKEN}";
    "pi-nix helper keys are not written to mcp.json" = !(example.mcpServers.exa ? bearerTokenEnvVar);
    "Pi MCP keys are passed through" =
      example.mcpServers.exa.exposure == "direct" && example.mcpServers.fs.cwd == "~/src";
    "raw servers are verbatim" =
      example.mcpServers.odd == {
        type = "http";
        url = "https://example.com/mcp";
      };
    "object-form packages are kept" =
      builtins.elemAt example.packages 1 == {
        source = "npm:@example/tools";
        skills = [ ];
      };
    "packages land in settings" = example.managedSettings.packages == example.packages;
    "ownership is exposed" = example.ownership == "merge";
    "extensions = null leaves packages unmanaged" =
      !((build { extensions = null; }).managedSettings ? packages);
    "plain versions keep their runtime name" = piNix.runtimeNameFor "1.0.4" == "1.0.4";
    "ranges get distinct runtime names" = piNix.runtimeNameFor "^1.0" != piNix.runtimeNameFor "~1.0";

    "unknown top-level keys are rejected" = throws (build { extension = [ ]; }).drvPath;
    "invalid ownership is rejected" = throws (build { ownership = "both"; }).drvPath;
    "relative configDir is rejected" = throws (build { configDir = "pi"; }).drvPath;
    "~user configDir is rejected" = throws (build { configDir = "~bob/pi"; }).drvPath;
    "settings.packages is rejected" = throws (build { settings.packages = [ ]; }).drvPath;
    "invalid env names are rejected" = throws (build { env."FOO BAR" = "1"; }).drvPath;
    "SSE MCP servers are rejected" =
      throws
        (build {
          mcpServers.x = {
            type = "sse";
            url = "https://x";
          };
        }).drvPath;
    "url + command is rejected" =
      throws
        (build {
          mcpServers.x = {
            url = "https://x";
            command = "x";
          };
        }).drvPath;
    "unknown extension keys are rejected" =
      throws
        (build {
          extensions = [
            {
              source = "npm:x";
              skill = [ ];
            }
          ];
        }).drvPath;
  };

  failures = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
in
pkgs.runCommand "pi-nix-lib-test" { } (
  if failures == [ ] then
    ''
      grep -q 'PI_TELEMETRY+x' ${example}/bin/pi
      grep -Eq "export PI_TELEMETRY='?0'?$" ${example}/bin/pi
      echo "${toString (builtins.length (lib.attrNames cases))} lib checks passed" > "$out"
    ''
  else
    ''
      echo "pi-nix lib test failures:" >&2
      ${lib.concatMapStrings (name: "echo ${lib.escapeShellArg "  - ${name}"} >&2\n") failures}
      exit 1
    ''
)
