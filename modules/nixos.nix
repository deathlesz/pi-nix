# NixOS integration for pi-nix.
#
#   imports = [ pi-nix.nixosModules.default ];
#   programs.pi-nix = {
#     enable = true;
#     config = {
#       extensions = [ "npm:pi-subagents" ];
#       settings.defaultTools = [ "+codemode" "+tool_search" ];
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.pi-nix;
  piNix = import ../lib { inherit (pkgs) lib; };
in
{
  options.programs.pi-nix = {
    enable = lib.mkEnableOption "the declaratively configured Pi coding agent (pi-nix)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Prebuilt pi-nix environment to install. When null, an environment is
        built from {option}`programs.pi-nix.config`.
      '';
    };

    config = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = lib.literalExpression ''
        {
          piVersion = "1.0.4";
          extensions = [ "npm:pi-subagents" ];
          mcpServers.exa = { url = "https://mcp.exa.ai/mcp"; bearerTokenEnvVar = "EXA_TOKEN"; };
          settings.defaultTools = [ "+codemode" "+tool_search" ];
        }
      '';
      description = ''
        pi-nix configuration passed to `mkPi`: `piVersion`, `extensions`,
        `mcpServers`, `settings`, `env`, `configDir`, `ownership`, `extraTools`,
        and `nodejs`.
        See the pi-nix README for the full reference.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (if cfg.package != null then cfg.package else piNix.mkPi pkgs cfg.config)
    ];
  };
}
