{ lib }:

let
  inherit (lib)
    attrNames
    concatStringsSep
    escapeShellArg
    filter
    hasInfix
    hasPrefix
    isAttrs
    isList
    isString
    makeBinPath
    mapAttrs
    mapAttrsToList
    optionalAttrs
    removeAttrs
    subtractLists
    ;

  piPackage = "@earendil-works/pi-coding-agent";

  # Keys accepted by the settings.json object form of a package entry.
  extensionKeys = [
    "source"
    "autoload"
    "extensions"
    "skills"
    "prompts"
    "themes"
  ];

  isEnvName = name: builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;

  # A package entry is either a plain source string or an attrset that narrows
  # which resources of the package load.
  normalizeExtension =
    value:
    if isString value then
      value
    else if isAttrs value then
      let
        unknown = subtractLists extensionKeys (attrNames value);
      in
      if !(value ? source) then
        throw "pi-nix: an extension entry given as an attrset must set `source`: ${builtins.toJSON value}"
      else if unknown != [ ] then
        throw "pi-nix: extension `${toString value.source}` has unknown keys ${builtins.toJSON unknown} (allowed: ${concatStringsSep ", " extensionKeys})"
      else
        value
    else
      throw "pi-nix: extension entries must be strings or attrsets: ${builtins.toJSON value}";

  # MCP server definitions in mcp.json shape. Every key Pi understands
  # (`type`, `cwd`, `timeout`, `enabled`, `exposure`, `toolExposure`,
  # `description`, `oauth`, ...) is passed through unchanged. pi-nix adds:
  #   bearerTokenEnvVar = "TOKEN";  → headers.Authorization = "Bearer ${TOKEN}"
  #   raw = { ... };                → written verbatim, no validation
  normalizeMcpServer =
    name: value:
    if !isAttrs value then
      throw "pi-nix: MCP server `${name}` must be an attrset"
    else if value ? raw then
      if builtins.length (attrNames value) != 1 then
        throw "pi-nix: MCP server `${name}`: when using `raw`, no other keys may be set"
      else
        value.raw
    else if value ? url && value ? command then
      throw "pi-nix: MCP server `${name}` sets both `url` and `command`; pick one"
    else if !(value ? url || value ? command) then
      throw "pi-nix: MCP server `${name}` must set `url`, `command`, or `raw`"
    else if (value.type or null) == "sse" then
      throw "pi-nix: MCP server `${name}`: Pi does not support the SSE transport; use the server's streamable HTTP endpoint (often /mcp)"
    else if value ? args && !isList value.args then
      throw "pi-nix: MCP server `${name}`: `args` must be a list"
    else if value ? bearerTokenEnvVar && !(value ? url) then
      throw "pi-nix: MCP server `${name}`: `bearerTokenEnvVar` only applies to HTTP (`url`) servers"
    else if value ? bearerTokenEnvVar && !isEnvName value.bearerTokenEnvVar then
      throw "pi-nix: MCP server `${name}`: `bearerTokenEnvVar` must be an environment variable name, got: ${value.bearerTokenEnvVar}"
    else
      removeAttrs value [ "bearerTokenEnvVar" ]
      // optionalAttrs (value ? bearerTokenEnvVar) {
        headers = (value.headers or { }) // {
          Authorization = "Bearer \${${value.bearerTokenEnvVar}}";
        };
      };

  # Binaries pi-nix itself needs to bootstrap, reconcile, and talk to package
  # sources. Everything else is inherited from the caller's environment: pi-nix
  # deliberately does not seal PATH, so Pi and its tools can use whatever the
  # user already has (jq, rust, python, cloud CLIs, ...).
  coreTools =
    pkgs: with pkgs; [
      bash
      coreutils
      gnugrep
      gnused
      findutils
      git
      cacert
    ];

  # Store/derivation-safe name for a version spec. Plain versions are kept
  # as-is; ranges and tags get a hash suffix so that e.g. "^1.0" and "~1.0"
  # never share a runtime directory.
  runtimeNameFor =
    version:
    let
      sanitized = lib.strings.sanitizeDerivationName version;
    in
    if sanitized == version then
      version
    else
      "${sanitized}-${builtins.substring 0 8 (builtins.hashString "sha256" version)}";

  mkPi =
    pkgs: cfg:
    let
      knownKeys = [
        "piVersion"
        "configDir"
        "ownership"
        "extensions"
        "mcpServers"
        "settings"
        "env"
        "extraTools"
        "nodejs"
      ];
      unknownKeys = subtractLists knownKeys (attrNames cfg);

      nodejs = cfg.nodejs or pkgs.nodejs;

      piVersion =
        let
          value = toString (cfg.piVersion or "latest");
        in
        if value == "" || hasInfix "'" value || hasInfix "\"" value || hasInfix "\n" value then
          throw "pi-nix: piVersion must be a non-empty version, range, or tag without quotes or newlines: ${value}"
        else
          value;

      configDir = toString (cfg.configDir or "shared");
      configMode =
        if hasInfix "'" configDir || hasInfix "\n" configDir then
          throw "pi-nix: configDir must not contain quotes or newlines: ${configDir}"
        else if
          builtins.elem configDir [
            "shared"
            "isolated"
          ]
        then
          configDir
        else if hasPrefix "/" configDir || configDir == "~" || hasPrefix "~/" configDir then
          configDir
        else
          throw "pi-nix: configDir must be \"shared\", \"isolated\", or an absolute (or ~/-prefixed) path, got: ${configDir}";

      ownership =
        let
          value = cfg.ownership or "enforce";
        in
        if
          builtins.elem value [
            "enforce"
            "merge"
          ]
        then
          value
        else
          throw "pi-nix: ownership must be \"enforce\" or \"merge\", got: ${toString value}";

      userSettings =
        if !isAttrs (cfg.settings or { }) then
          throw "pi-nix: `settings` must be an attrset (any Pi setting, e.g. settings.defaultTools)"
        else
          cfg.settings or { };
      mcpServers =
        if !isAttrs (cfg.mcpServers or { }) then
          throw "pi-nix: `mcpServers` must be an attrset of server definitions"
        else
          mapAttrs normalizeMcpServer (cfg.mcpServers or { });
      extraTools = cfg.extraTools or [ ];

      extensions = cfg.extensions or null;
      managePackages = extensions != null;
      packages =
        if !managePackages then
          [ ]
        else if !isList extensions then
          throw "pi-nix: `extensions` must be a list of sources (or null to leave packages unmanaged)"
        else
          map normalizeExtension extensions;

      # The declarative slice of settings.json. Declaring `settings.packages`
      # directly is a configuration mistake worth an evaluation error:
      # `extensions` is the supported knob.
      managedSettings =
        if userSettings ? packages then
          throw "pi-nix: declare packages through `extensions`, not `settings.packages`"
        else
          userSettings // optionalAttrs managePackages { inherit packages; };

      env =
        let
          value = cfg.env or { };
          bad = filter (name: !isEnvName name) (attrNames value);
        in
        if !isAttrs value then
          throw "pi-nix: `env` must be an attrset"
        else if bad != [ ] then
          throw "pi-nix: invalid environment variable names in `env`: ${builtins.toJSON bad}"
        else
          value;

      # Declared variables are only exported when the caller has not set them.
      envExports = concatStringsSep "\n" (
        mapAttrsToList (
          name: value:
          let
            str = if builtins.isBool value then (if value then "1" else "0") else toString value;
          in
          ''[ -n "''${${name}+x}" ] || export ${name}=${escapeShellArg str}''
        ) env
      );

      binPath = makeBinPath (coreTools pkgs ++ [ nodejs ] ++ extraTools);

      template = builtins.readFile ./wrapper.sh;
      render =
        defaultMode:
        builtins.replaceStrings
          [
            "@bash@"
            "@piPackage@"
            "@piVersion@"
            "@runtimeName@"
            "@shareDir@"
            "@configMode@"
            "@cacertBundle@"
            "@binPath@"
            "@envExports@"
            "@defaultMode@"
          ]
          [
            "${pkgs.bash}/bin/bash"
            piPackage
            piVersion
            (runtimeNameFor piVersion)
            "${share}"
            configMode
            "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            binPath
            envExports
            defaultMode
          ]
          template;

      # Desired configuration, read by the reconciler at every launch.
      share = pkgs.runCommand "pi-nix-share" { } ''
        mkdir -p "$out"
        cp ${pkgs.writeText "pi-nix-settings.json" (builtins.toJSON managedSettings)} "$out/settings.json"
        cp ${pkgs.writeText "pi-nix-mcp.json" (builtins.toJSON { inherit mcpServers; })} "$out/mcp.json"
        cp ${pkgs.writeText "pi-nix-meta.json" (builtins.toJSON { inherit ownership; })} "$out/meta.json"
        cp ${./reconcile.mjs} "$out/reconcile.mjs"
        ${nodejs}/bin/node --check "$out/reconcile.mjs"
      '';

      mkLauncher =
        binName: defaultMode:
        pkgs.writeTextFile {
          name = "pi-nix-${binName}";
          destination = "/bin/${binName}";
          executable = true;
          text = render defaultMode;
          checkPhase = ''
            ${pkgs.bash}/bin/bash -n "$target"
          '';
        };

      # Derivation names may not contain arbitrary npm range operators.
      name = "pi-" + lib.strings.sanitizeDerivationName piVersion;
    in
    if unknownKeys != [ ] then
      throw "pi-nix: unknown configuration keys ${builtins.toJSON unknownKeys} (known: ${concatStringsSep ", " knownKeys})"
    else
      # Only the launchers are exposed: node, bash and the core tools stay
      # private to the launcher (via its PATH) so that installing pi-nix into a
      # profile does not shadow or collide with the user's own node/bash.
      pkgs.symlinkJoin {
        inherit name;
        paths = [
          (mkLauncher "pi" "run")
          (mkLauncher "pi-reconcile" "reconcile")
        ];
        passthru = {
          inherit
            mcpServers
            packages
            managedSettings
            configMode
            ownership
            extraTools
            share
            ;
          config = cfg;
        };
        meta = {
          description = "Pi coding agent (${piVersion}) with declarative extensions, MCP servers, and settings";
          homepage = "https://pi.dev";
          mainProgram = "pi";
          platforms = lib.platforms.unix;
        };
      };
in
{
  inherit
    mkPi
    normalizeExtension
    normalizeMcpServer
    coreTools
    runtimeNameFor
    ;
}
