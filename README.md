# pi-nix

> [!CAUTION]
> This projects is fully vibe-coded, with not a single human-written line of code. Use it at your own risk!

Run [Pi](https://pi.dev) from Nix with **declarative extensions, MCP servers, tools, and settings** — and run it *inside your own environment*, so Pi and its tools can use everything you already have on your `PATH`.

Adding an extension is one line, exactly like one `RUN pi install ...` line in a `Dockerfile`:

```nix
extensions = [ "npm:pi-subagents" "npm:@richardgill/pi-up-history" ];
```

pi-nix reconciles that declaration into Pi on the next launch: missing packages get installed, changed settings and MCP servers get applied, and everything it does not manage (credentials, sessions, unrelated settings) is left alone.

```bash
nix run .#pi                    # first launch bootstraps Pi, then runs it
nix run .#pi -- -p "hello"      # CLI arguments pass straight through
nix run .#pi-reconcile          # apply config.nix without starting Pi
```

> **Pinning:** `flake.lock` pins nixpkgs. Run `nix flake update` to bump it, and commit the result.

---

## Contents

- [What you get](#what-you-get)
- [Quick start](#quick-start)
- [Configuration reference](#configuration-reference)
  - [Pi version](#pi-version)
  - [Extensions and packages](#extensions-and-packages)
  - [MCP servers](#mcp-servers)
  - [Pi settings (tools, models, themes, ...)](#pi-settings-tools-models-themes-)
  - [Environment variables](#environment-variables)
  - [Config directory](#config-directory)
  - [Ownership: enforce or merge](#ownership-enforce-or-merge)
  - [Extra packages](#extra-packages)
- [Using pi-nix](#using-pi-nix)
  - [Ad-hoc runs](#ad-hoc-runs)
  - [Installing it](#installing-it)
  - [Development shells](#development-shells)
  - [From your own flake](#from-your-own-flake)
  - [home-manager and NixOS](#home-manager-and-nixos)
- [How it works](#how-it-works)
- [Updating](#updating)
- [Multiple environments](#multiple-environments)
- [Environment variables that pi-nix reads](#environment-variables-that-pi-nix-reads)
- [Testing](#testing)
- [Repository layout](#repository-layout)
- [Design notes](#design-notes)

---

## What you get

- **Declarative extensions.** npm, git, URL, and local package sources, with optional per-resource filtering, in one list.
- **Declarative MCP servers.** HTTP (with bearer-token helpers), stdio, every Pi MCP option, and a verbatim escape hatch.
- **Strict or collaborative.** `ownership = "enforce"` makes the flake the single source of truth; `ownership = "merge"` treats it as a baseline that Pi itself may extend (`pi install`, `pi mcp add`).
- **Every Pi setting is configurable.** `defaultTools`, models, thinking levels, compaction, terminal, themes, shell, retries — anything from Pi's settings reference, as a Nix attrset.
- **Runs in *your* environment.** pi-nix never seals `PATH` or drops environment variables. If `jq`, `rust`, `python`, or `gh` are available to you, they are available to Pi. No need to enumerate tools in Nix.
- **No container required.** Pi runs directly on the host, as your user, with your credentials and your files.
- **Self-bootstrapping and offline-friendly.** The first launch installs the pinned Pi runtime and packages; every later launch is a fast no-op that needs no network.
- **Reusable library and modules.** `lib.mkPi`, plus home-manager and NixOS modules for anytime-available installs.

---

## Quick start

```bash
git clone <this repo> pi-nix && cd pi-nix
nix run .#pi                # or: nix run .
```

Provide credentials the usual way — environment variables or `pi auth`:

```bash
export OPENROUTER_API_KEY=...
export EXA_TOKEN=...        # used by the example MCP server
nix run .#pi
```

Then edit [`config.nix`](./config.nix) to taste. It is the only file you normally touch.

### Coming from `Dockerfile.pi`

| `Dockerfile.pi` | `config.nix` |
|---|---|
| `npm install -g @earendil-works/pi-coding-agent` | `piVersion = "1.0.4";` |
| `pi install npm:pi-subagents` (one line each) | `extensions = [ "npm:pi-subagents" ... ];` |
| `pi mcp add exa --url https://mcp.exa.ai/mcp --bearer-token-env-var EXA_TOKEN` | `mcpServers.exa = { url = "https://mcp.exa.ai/mcp"; bearerTokenEnvVar = "EXA_TOKEN"; };` |
| `settings.json` `{"defaultTools": [...]}` | `settings.defaultTools = [ ... ];` |
| `apt-get install ... jq ripgrep fd-find python3 ...` | *nothing* — your environment's tools are already visible to Pi |
| `curl ... \| sh -s -- -y` (rustup), `wget typst` | *nothing* — use the rust/typst you already have |
| `ENV OPENROUTER_API_KEY=...` | export it in your shell (secrets stay out of the Nix store) |
| `WORKDIR /workspace` | run `pi` in whatever directory you are in |
| `ENTRYPOINT ["pi"]` | `nix run .#pi` |

---

## Configuration reference

All configuration lives in [`config.nix`](./config.nix), which is passed to `mkPi`. It is an ordinary attrset, so values may reference `pkgs` (for example a `shellPath`).

### Pi version

```nix
piVersion = "1.0.4";      # exact versions are re-installed when they change
piVersion = "^1.0";       # npm ranges work (installed when missing)
piVersion = "latest";     # dist-tags work
```

Exact pins are the reproducible choice: launch checks the installed version and reinstalls automatically when you bump the pin.

### Extensions and packages

Anything `pi install` accepts:

```nix
extensions = [
  "npm:pi-subagents"                       # npm package
  "npm:@scope/package@1.2.3"               # pinned npm package
  "git:github.com/user/repo@v1"            # git tag / commit / branch
  "https://github.com/user/repo"           # treated as git
  "ssh://git@github.com/user/repo"         # ssh
  "/absolute/path/to/local-package"        # local package or single file
];
```

A package can contribute only selected resources by using the object form (omit a key to load everything, use `[]` to load none, `!pattern` to exclude, `+path`/`-path` for exact matches):

```nix
extensions = [
  { source = "npm:@example/pi-tools";
    prompts = [ ];                    # no prompt templates from this package
    skills = [ "skills/review" ];     # only this skill
  }
];
```

Set `extensions = null` to leave the user's existing package list completely untouched (pi-nix then manages no packages at all).

### MCP servers

```nix
mcpServers = {
  # HTTP, with the token read from an environment variable at connect time
  exa = {
    url = "https://mcp.exa.ai/mcp";
    bearerTokenEnvVar = "EXA_TOKEN";       # writes Authorization: Bearer ${EXA_TOKEN}
  };

  # HTTP with explicit headers
  docs = {
    url = "https://example.com/mcp";
    headers = { "X-Api-Key" = "public-demo"; };
  };

  # stdio server
  filesystem = {
    command = "mcp-server-filesystem";
    args = [ "/workspace" ];
    env = { LOG_LEVEL = "warn"; };
  };

  # escape hatch: written to mcp.json verbatim
  odd = { raw = { type = "http"; url = "https://example.com/mcp"; }; };

  # any other Pi MCP key passes straight through
  github = {
    url = "https://api.githubcopilot.com/mcp/";
    bearerTokenEnvVar = "GITHUB_TOKEN";
    exposure = "deferred";               # codemode | deferred | direct | hidden
    toolExposure = { "get_*" = "direct"; };
    description = "GitHub issues and PRs";
    timeout = 120;
  };
};
```

Pi's own keys (`type`, `cwd`, `timeout`, `enabled`, `exposure`, `toolExposure`, `description`, `oauth`, ...) are written unchanged; pi-nix only rejects obvious mistakes at evaluation time (both `url` and `command`, `type = "sse"`, which Pi does not support, non-list `args`).

With `ownership = "enforce"` pi-nix owns `mcpServers` in `mcp.json`: servers added with `pi mcp add` are removed on the next launch. With `ownership = "merge"` they are kept. See [Ownership](#ownership-enforce-or-merge).

### Pi settings (tools, models, themes, ...)

Anything from Pi's [settings reference](https://github.com/earendil-works/pi-coding-agent/blob/main/docs/settings.md) can be declared; nested keys map naturally from Nix attrsets:

```nix
settings = {
  # LLM-callable tools enabled at startup (built-in and extension tools)
  defaultTools = [ "+codemode" "+tool_search" ];

  defaultProvider = "openrouter";
  defaultModel = "openrouter/anthropic/claude-sonnet-4.5";
  defaultThinkingLevel = "high";
  enabledModels = [ "openrouter/*sonnet*" "openai/gpt-5*" ];

  theme = "system";
  quietStartup = true;
  terminal = { showImages = true; clearOnShrink = true; };
  compaction = { enabled = true; reserveTokens = 16384; };
  shellPath = "${pkgs.bashInteractive}/bin/bash";
  retry = { enabled = true; maxRetries = 5; };
  cacheWarming = "idle";

  # resource paths (absolute, or relative to the config directory)
  skills = [ "~/my-skills" ];
  prompts = [ "/etc/pi/prompts" ];
};
```

Every key you do not declare in `settings.json`, including keys Pi writes itself such as `lastChangelogVersion`, is left alone. What happens to the keys you *do* declare (plus `packages`, derived from `extensions`) depends on [`ownership`](#ownership-enforce-or-merge). A key you delete from `config.nix` is removed from `settings.json` on the next launch.

### Environment variables

```nix
env = {
  PI_SKIP_VERSION_CHECK = "1";
  PI_TELEMETRY = "0";
  PI_OFFLINE = "0";
  HTTP_PROXY = "http://proxy.internal:3128";
};
```

These are exported by the launcher and inherited by Pi and everything it spawns. Variables you already have in your environment win over the declared value, and anything not declared here is simply inherited. Booleans become `1`/`0`; names are validated at evaluation time.

> **Secrets:** `env` values end up in the world-readable Nix store. Keep API keys in your environment/direnv/secret manager, not in `config.nix`. Provider keys (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `EXA_TOKEN`, ...) are picked up from the environment automatically.

### Config directory

```nix
configDir = "shared";    # default: ~/.pi/agent — the same dir a plain Pi install uses
configDir = "isolated";  # private dir inside the pi-nix state directory
configDir = "~/pi/work"; # any absolute or ~-prefixed path
```

Use `"isolated"` when you keep several differently configured pi-nix environments and do not want them to fight over one config directory. `PI_CODING_AGENT_DIR` in the environment always takes precedence.

### Extra packages

```nix
extraTools = [ pkgs.ripgrep pkgs.jq ];
```

Usually unnecessary: pi-nix keeps your `PATH`, so tools you already have are already available. Set entries only to guarantee a binary is on Pi's `PATH` regardless of the invoking shell. They are added to the launcher's `PATH` only, not to your profile, so installing pi-nix never shadows your own `node`, `bash`, or tools.

### Ownership: enforce or merge

```nix
ownership = "enforce";  # default
ownership = "merge";
```

| | `enforce` | `merge` |
|---|---|---|
| Declared setting changed by Pi / `pi config` | reverted on next launch | kept |
| Declared setting changed in `config.nix` | applied | applied (overrides Pi's value) |
| Package added with `pi install` | removed | kept |
| MCP server added with `pi mcp add` | removed | kept |
| Declared entry deleted by Pi | restored | restored |
| Entry deleted from `config.nix` | removed | removed, unless Pi changed it since |
| Keys pi-nix never declared | untouched | untouched |

- **`enforce`** gives you a reproducible configuration: what is in `config.nix` is what Pi runs with, on every machine.
- **`merge`** lets Pi manage itself (install extensions, add MCP servers, tweak settings) on top of a declared baseline. Changes you make in `config.nix` still win, because pi-nix re-applies a declaration whenever it changes.

What pi-nix applied last is recorded in `<configDir>/.pi-nix-state.json`, which is how it tells your edits in `config.nix` apart from Pi's edits on disk. Switching modes at any time is safe.

> **Security:** in `merge` mode Pi (or anything that can steer Pi, such as a prompt injection) can install extension packages that later run as you. Use `enforce` when you want every installed package to be reviewed in `config.nix`.

---

## Using pi-nix

### Ad-hoc runs

```bash
nix run .#pi                      # interactive
nix run .#pi -- -p "run the tests"
nix run .#pi-reconcile            # provision/repair without launching Pi
```

### Installing it

```bash
nix profile install .#pi          # on PATH for the whole user profile
nix profile install github:you/pi-nix
nix build .#pi && ./result/bin/pi
```

### Development shells

```bash
nix develop                       # shell with the configured pi + pi-reconcile
```

### From your own flake

Use the library directly to build an environment from any attrset — no `config.nix` required:

```nix
{
  inputs.pi-nix.url = "github:you/pi-nix";
  outputs = { self, nixpkgs, pi-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.pi = pi-nix.lib.mkPi pkgs {
        piVersion = "1.0.4";
        configDir = "isolated";
        extensions = [ "npm:pi-subagents" "npm:@richardgill/pi-up-history" ];
        mcpServers.exa = { url = "https://mcp.exa.ai/mcp"; bearerTokenEnvVar = "EXA_TOKEN"; };
        settings.defaultTools = [ "+codemode" "+tool_search" ];
        env.PI_SKIP_VERSION_CHECK = "1";
      };
    };
}
```

### home-manager and NixOS

```nix
# home-manager
imports = [ pi-nix.homeManagerModules.default ];
programs.pi-nix = {
  enable = true;
  config = {
    extensions = [ "npm:pi-subagents" ];
    mcpServers.exa = { url = "https://mcp.exa.ai/mcp"; bearerTokenEnvVar = "EXA_TOKEN"; };
    settings.defaultTools = [ "+codemode" "+tool_search" ];
  };
};
```

```nix
# NixOS
imports = [ pi-nix.nixosModules.default ];
programs.pi-nix = { enable = true; config.extensions = [ "npm:pi-subagents" ]; };
```

`programs.pi-nix.package` accepts a prebuilt environment (for example `pi-nix.packages.<system>.pi`) when you want the module to install exactly the `config.nix` build.

---

## How it works

pi-nix is a *reconciler*, not a snapshot. Each launch:

1. **Ensures the runtime.** `$STATE_DIR/runtimes/<piVersion>` holds `@earendil-works/pi-coding-agent` plus its dependencies, installed from npm with the version pinned in `config.nix`. An exact pin is verified on every launch; a missing runtime triggers installation.
2. **Reconciles configuration.** A small Node script merges the declared `settings` and `packages` into `settings.json`, and the declared `mcpServers` into `mcp.json`, following the [ownership mode](#ownership-enforce-or-merge). Files are compared structurally and written only when something actually changed. Writes are atomic and follow symlinks, and a corrupt file is backed up (`settings.json.corrupt-<time>`) before being regenerated.
3. **Reconciles packages.** When pi-nix changed the package list (or the npm package tree is missing), `pi update --extensions` installs the missing sources. This is the same supported code path `pi install` uses, so git and local sources work too. If it fails, for example while offline, it is retried on the next launch.
4. **Executes Pi.** `exec node <cli.js> "$@"`, in your environment, with stdout left clean for `--print` / `--mode json` pipelines.

A warm launch does none of the above except a few file comparisons and the `exec`; it takes ~0.15s and works offline. A lock directory in the state directory serializes concurrent launches. A lock left behind by a crashed process is detected via its PID and reclaimed. The runtime is installed into a scratch directory and swapped in only when complete, so an interrupted install never leaves a broken runtime behind.

State layout:

```
${XDG_STATE_HOME:-~/.local/state}/pi-nix
├── runtimes/
│   └── <piVersion>/   # pinned Pi install; one per pinned version
├── npm-cache/         # npm cache for the above
├── .lock/             # serializes concurrent launches (owner: host + PID)
└── agent/             # only when configDir = "isolated"
```

The Pi config directory holds `settings.json`, `mcp.json`, `npm/` (package tree), `.pi-nix-state.json` (what pi-nix applied last), plus whatever Pi itself maintains (`auth.json`, `sessions/`, ...).

`pi-reconcile` performs steps 1–3 and exits: useful for provisioning machines, warming caches in CI, or repairing a broken state.

---

## Updating

| What | How |
|---|---|
| Pi itself | Bump `piVersion` in `config.nix` (exact pins update automatically on the next launch). |
| Extensions | Pin them in `extensions` (`"npm:pi-subagents@0.76.1"`) for reproducibility, or leave them unpinned and run `PI_NIX_FORCE_RECONCILE=1 nix run .#pi-reconcile` to re-resolve. |
| nixpkgs / node | `nix flake update`, then commit `flake.lock`. |
| Pi's model catalog | `pi update --models`, or `pi-reconcile` when needed. |

---

## Multiple environments

Run several pi-nix configurations side by side (for example a "work" and a "personal" environment, or per-project tooling) by giving each an isolated config directory:

```nix
configDir = "isolated";
```

Each build then keeps its own `settings.json`, `mcp.json`, package tree, credentials, and sessions under its state directory, and none of them touch `~/.pi/agent`.

---

## Environment variables that pi-nix reads

| Variable | Effect |
|---|---|
| `PI_NIX_STATE_DIR` | Where runtime, npm cache, and isolated configs live. Default: `${XDG_STATE_HOME:-~/.local/state}/pi-nix`. |
| `PI_NIX_NPM_CACHE` | npm cache directory used for the runtime install. |
| `PI_NIX_MODE` | `run` (default) or `reconcile`. |
| `PI_NIX_FORCE_RECONCILE` | `1` re-runs package reconciliation even if the declaration is unchanged. |
| `PI_NIX_RECONCILE_STRICT` | `0` logs a warning and continues when package reconciliation fails (for example while offline) instead of aborting. |
| `PI_CODING_AGENT_DIR` | Standard Pi override; wins over `configDir`. |

---

## Testing

The launcher and reconciler are plain bash + Node, so they are testable without Nix:

```bash
./tests/launcher-test.sh
```

The suite renders the launcher the way the flake does, then exercises a throwaway HOME against a real Pi release: cold start, warm no-op, stdout purity, settings ownership, `extensions = null`, object-form packages, MCP reconciliation, strict/tolerant failure modes, retry after a failed install, removal of undeclared keys, `merge` ownership, corrupt-file backups, isolated configs, version reinstall, offline reuse, concurrent cold starts, and missing-`HOME` diagnostics. It needs network access on the first run (it bootstraps Pi and packages from npm).

For Nix-side evaluation:

```bash
nix flake check                   # builds the env + runs tests/lib-test.nix (offline)
nix build .#pi && ./result/bin/pi-reconcile
```

---

## Repository layout

```
flake.nix                 # flake outputs: packages, apps, devShell, lib, modules
config.nix                # the declarative configuration (edit this)
lib/default.nix           # mkPi: normalization, launcher rendering, environment build
lib/wrapper.sh            # launcher template (bootstrap, reconcile, exec)
lib/reconcile.mjs         # merges declared settings/mcpServers into the config dir
modules/home-manager.nix  # home-manager integration
modules/nixos.nix         # NixOS integration
tests/launcher-test.sh    # behavioural test suite (no Nix required)
tests/lib-test.nix        # evaluation tests for lib/default.nix (nix flake check)
```

---

## Design notes

**Why does the launcher install Pi at runtime instead of using a pure Nix build?**
The published `@earendil-works/pi-coding-agent` tarball ships a prebuilt bundle plus regular dependencies and *no* lockfile. A pure `buildNpmPackage` would therefore require vendoring a generated lockfile and a `npmDepsHash` per release, plus another hash per extension — which would destroy the "just write the name" ergonomics that make a `Dockerfile` pleasant, and would need hash churn on every upstream release. Instead, pi-nix pins an exact `piVersion` and installs it on first use, keeping the state directory as the only mutable part. Everything else — the launcher, the reconciler, the declared settings, and the Nix store paths pi-nix depends on — is fully reproducible from the flake.

**Why is `PATH` inherited rather than sealed?**
Pi's value comes from what it can *do* on your machine: run your compilers, your cloud CLIs, your scripts. Sealing the environment would mean re-declaring `jq`, `rust`, `python`, and everything else in Nix, and Pi's tools would stop seeing things you installed outside Nix. pi-nix only prepends the handful of store paths it needs to bootstrap and reconcile, then hands control back to your environment.

**Trust and security.** Extension packages execute code inside Pi, and pi-nix will install whatever `extensions` declares. Treat that list like a `Dockerfile` that runs as you: review third-party packages before adding them, and pin versions where it matters. Credentials stay in your environment — pi-nix never stores secrets in the Nix store unless you explicitly put them in `env`.
