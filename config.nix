# ┌───────────────────────────────────────────────────────────────────────────┐
# │ pi-nix configuration — the declarative equivalent of Dockerfile.pi        │
# └───────────────────────────────────────────────────────────────────────────┘
#
# Edit this file, then run `nix run` (or launch your installed `pi`). pi-nix
# reconciles the Pi configuration on the next launch:
#
#   * new/changed extension sources are installed automatically,
#   * `settings` keys and `mcpServers` are applied to the Pi config directory,
#   * everything else in that directory (credentials, sessions, unrelated
#     settings) is preserved.
#
# Adding an extension is one line in `extensions`, just like one RUN line in a
# Dockerfile.
{pkgs}: {
  # ── Pi itself ──────────────────────────────────────────────────────────────
  # Exact versions are pinned and re-installed when they change. npm version
  # ranges ("^1.0", ">=1.0 <2") and dist-tags ("latest") also work.
  piVersion = ">=1.0";

  # Which config directory Pi uses:
  #   "shared"   → ~/.pi/agent, the same directory a plain Pi install uses
  #                (shares credentials and sessions with it)
  #   "isolated" → private directory inside the pi-nix state directory; use this
  #                when you run several differently-configured pi-nix envs
  #   "<path>"   → an absolute path, or "~/something"
  configDir = "shared";

  # Who owns the declared configuration:
  #   "enforce" → the flake is the source of truth. Declared settings, the
  #               package list and the MCP server set are reset on every
  #               launch; changes made through Pi (`pi install`, `pi mcp add`)
  #               to them are reverted. Fully reproducible.
  #   "merge"   → the flake is a baseline. Declared entries are added when
  #               missing and re-applied when you change them here, but Pi may
  #               install extra packages, add MCP servers, and change settings
  #               itself, and those changes are kept.
  # In both modes, entries you delete from this file are removed again.
  ownership = "enforce";

  # ── Extensions / packages ──────────────────────────────────────────────────
  # Anything `pi install` accepts: npm:, git:, https://, ssh://, or a local
  # path. Set `extensions = null` to leave the user's package list untouched.
  #
  # A package that should only contribute selected resources uses the object
  # form (omit a key to load everything, use [] to load none):
  #
  #   { source = "npm:@example/pi-tools"; prompts = [ ]; skills = [ "skills/review" ]; }
  extensions = [
    "npm:pi-subagents"
    "npm:@narumitw/pi-goal"
    "npm:@narumitw/pi-btw"
    "npm:@narumitw/pi-plan-mode"
    "npm:@juicesharp/rpiv-ask-user-question"
    "npm:@juicesharp/rpiv-todo"
    "npm:@richardgill/pi-background-bash"
    "npm:@richardgill/pi-project-resources"
    "npm:@richardgill/pi-up-history"
  ];

  # ── MCP servers ────────────────────────────────────────────────────────────
  # HTTP:
  #   exa = { url = "https://mcp.exa.ai/mcp"; bearerTokenEnvVar = "EXA_TOKEN"; };
  #   docs = { url = "https://example.com/mcp"; headers = { X-Key = "v"; }; };
  # stdio:
  #   fs = { command = "mcp-server-filesystem"; args = [ "/workspace" ]; };
  #   local = { command = "my-server"; env = { LOG = "debug"; }; };
  # escape hatch (written to mcp.json verbatim):
  #   odd = { raw = { type = "http"; url = "https://example.com/mcp"; }; };
  # Any other Pi MCP key is passed through (exposure, toolExposure, cwd,
  # timeout, enabled, description, oauth, ...).
  mcpServers = {
    exa = {
      url = "https://mcp.exa.ai/mcp";
      bearerTokenEnvVar = "EXA_TOKEN";
    };
  };

  # ── Pi settings ────────────────────────────────────────────────────────────
  # Any key from Pi's settings reference (docs/settings.md) can be declared
  # here — models, thinking, compaction, terminal, themes, shell, retries, ...
  # These keys are owned by pi-nix and enforced on every launch; keys you do not
  # declare are preserved as-is in settings.json.
  settings = {
    # Tools (built-in and extension tools) enabled at startup.
    defaultTools = [
      "+codemode"
      "+tool_search"
    ];

    # Examples:
    # defaultProvider = "openrouter";
    # defaultModel = "openrouter/openrouter/auto";
    # defaultThinkingLevel = "high";
    # theme = "system";
    # compaction = { enabled = true; reserveTokens = 16384; };
    # shellPath = "${pkgs.bashInteractive}/bin/bash";
    # terminal = { showImages = true; clearOnShrink = true; };
    # retry = { maxRetries = 5; };
  };

  # ── Environment ────────────────────────────────────────────────────────────
  # Environment variables for Pi and every process it spawns (including the
  # bash tool). Variables already set in your environment win over these.
  #
  # Secrets: values here end up world-readable in the Nix store. Export API
  # keys in your shell/direnv (.envrc), not in this file. Provider keys such as
  # OPENROUTER_API_KEY and EXA_TOKEN are picked up from the environment.
  env = {
    PI_SKIP_VERSION_CHECK = "1";
  };

  # ── Extra packages ─────────────────────────────────────────────────────────
  # Usually unnecessary: pi-nix runs Pi inside *your* environment, so Pi and its
  # tools already see everything on your PATH (jq, rust, python, gh, ...).
  # Add entries only to guarantee a binary exists independently of the shell.
  extraTools = [];

  # Node.js used to run Pi and to install packages.
  # nodejs = pkgs.nodejs_24;
}
