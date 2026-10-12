#!/usr/bin/env node
/**
 * pi-nix reconciler.
 *
 * Merges the configuration declared in the flake (desired state) into the Pi
 * agent config directory (`PI_CODING_AGENT_DIR`, usually `~/.pi/agent`).
 *
 * Ownership modes (`ownership` in the flake, stored in `meta.json`)
 * ----------------------------------------------------------------
 *  enforce (default) — the flake is the source of truth for what it declares:
 *    - declared `settings` keys are overwritten on every launch,
 *    - `packages` (from `extensions`) is exactly the declared list,
 *    - `mcpServers` in mcp.json is exactly the declared set.
 *  merge — the flake provides a baseline and Pi may extend it:
 *    - declared entries are added when missing, and re-applied when their
 *      declaration changes in the flake,
 *    - entries Pi adds itself (`pi install`, `pi mcp add`, edits to
 *      settings.json) and Pi's edits to declared entries are kept until the
 *      declaration itself changes.
 *
 * In both modes, entries that were declared on a previous launch and have
 * since been removed from the flake are removed from the config files (in
 * merge mode only if Pi has not modified them in the meantime), and every key
 * pi-nix never declared is preserved untouched. `packages` is never removed
 * wholesale: with `extensions = null` the user's list is left alone.
 *
 * What was last applied is recorded in `<configDir>/.pi-nix-state.json`.
 * Files are only rewritten when the merged result actually differs, so a warm
 * environment performs no writes at all. Writes are atomic (temp + rename).
 *
 * Usage
 * -----
 *   node reconcile.mjs                 reconcile; prints the lines below
 *   node reconcile.mjs --packages-done record a successful package install
 *
 * Output (line-based, so the launcher needs nothing but grep/cut):
 *
 *   SETTINGS_CHANGED=0|1
 *   PACKAGES_CHANGED=0|1   package reconciliation is needed (changed or pending)
 *   NPM_PACKAGES=0|1       the effective package list contains npm sources
 *   MCP_CHANGED=0|1
 */

import fs from "node:fs";
import path from "node:path";

const shareDir = process.env.PI_NIX_SHARE_DIR;
const configDir = process.env.PI_NIX_CONFIG_DIR;

if (!shareDir || !configDir) {
  process.stderr.write(
    "pi-nix: PI_NIX_SHARE_DIR and PI_NIX_CONFIG_DIR must both be set\n",
  );
  process.exit(2);
}

const warn = (message) => process.stderr.write(`pi-nix: warning: ${message}\n`);
const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const isObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);

/**
 * Read a JSON object, returning `fallback` for missing files. A corrupt file
 * (or one that is not a JSON object) is backed up next to the original before
 * being treated as absent, so a typo never silently destroys user settings.
 */
const readJsonObject = (file, fallback) => {
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return fallback;
  }
  try {
    const value = JSON.parse(raw);
    if (isObject(value)) return value;
  } catch {
    // fall through to the backup below
  }
  const backup = `${file}.corrupt-${new Date().toISOString().replace(/[:.]/g, "-")}`;
  try {
    fs.copyFileSync(file, backup);
    warn(`${file} is not a valid JSON object; backed it up to ${backup}`);
  } catch (error) {
    warn(`${file} is not a valid JSON object and could not be backed up: ${error}`);
  }
  return fallback;
};

const readDesired = (name, fallback) => {
  const file = path.join(shareDir, name);
  if (fallback !== undefined && !fs.existsSync(file)) return fallback;
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    process.stderr.write(`pi-nix: cannot read declared ${file}: ${error}\n`);
    process.exit(2);
  }
};

/** Deterministic serialization used for structural comparison. */
const stable = (value) => {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (isObject(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stable(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
};

const equal = (a, b) => stable(a) === stable(b);

/**
 * Atomically replace `file` with `next`. Symlinks are followed so that a
 * settings.json linked into a dotfiles repository stays a symlink; the
 * existing file mode is preserved.
 */
const writeJsonAtomic = (file, next) => {
  let target = file;
  let mode;
  try {
    target = fs.realpathSync(file);
    mode = fs.statSync(target).mode & 0o7777;
  } catch {
    // new file
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const tmp = `${target}.pi-nix-${process.pid}.tmp`;
  try {
    fs.writeFileSync(
      tmp,
      `${JSON.stringify(next, null, 2)}\n`,
      mode === undefined ? {} : { mode },
    );
    fs.renameSync(tmp, target);
  } catch (error) {
    fs.rmSync(tmp, { force: true });
    throw error;
  }
};

const writeJsonIfChanged = (file, current, next) => {
  if (current !== null && equal(current, next)) return false;
  writeJsonAtomic(file, next);
  return true;
};

/**
 * Three-way merge of keyed entries (settings keys, MCP servers).
 *
 *   current    what is on disk now
 *   desired    what the flake declares
 *   last       what pi-nix applied on the previous launch
 *   exclusive  drop every key that is not declared (enforce-mode mcpServers)
 */
const mergeKeyed = (current, desired, last, { enforce, exclusive = false }) => {
  const result = exclusive ? {} : { ...current };
  for (const [key, value] of Object.entries(desired)) {
    const declarationChanged = !has(last, key) || !equal(last[key], value);
    if (enforce || declarationChanged || !has(current, key)) {
      result[key] = value;
    }
  }
  if (!exclusive) {
    for (const key of Object.keys(last)) {
      if (has(desired, key)) continue;
      // No longer declared: drop it, unless Pi changed it in merge mode.
      if (enforce || equal(current[key], last[key])) delete result[key];
    }
  }
  return result;
};

/** Package entries are identified by their source. */
const sourceOf = (entry) => (typeof entry === "string" ? entry : entry?.source);
const bySource = (entries) =>
  new Map((entries ?? []).map((entry) => [sourceOf(entry), entry]));

const mergePackages = (current, desired, last, { enforce }) => {
  if (enforce) return desired;
  const desiredMap = bySource(desired);
  const lastMap = bySource(last);
  const result = [];
  const seen = new Set();
  for (const entry of Array.isArray(current) ? current : []) {
    const source = sourceOf(entry);
    if (desiredMap.has(source)) {
      seen.add(source);
      const declared = desiredMap.get(source);
      const unchanged = lastMap.has(source) && equal(lastMap.get(source), declared);
      result.push(unchanged ? entry : declared);
    } else if (lastMap.has(source) && equal(entry, lastMap.get(source))) {
      // Previously declared, now removed from the flake, untouched by Pi: drop.
    } else {
      result.push(entry);
    }
  }
  for (const entry of desired) {
    if (!seen.has(sourceOf(entry))) result.push(entry);
  }
  return result;
};

// ---------------------------------------------------------------------------
const stateFile = path.join(configDir, ".pi-nix-state.json");
const settingsFile = path.join(configDir, "settings.json");
const mcpFile = path.join(configDir, "mcp.json");

const loadState = () => {
  const state = readJsonObject(stateFile, {});
  return {
    settings: isObject(state.settings) ? state.settings : {},
    packages: Array.isArray(state.packages) ? state.packages : null,
    mcpServers: isObject(state.mcpServers) ? state.mcpServers : {},
    packagesPending: state.packagesPending === true,
  };
};

const saveState = (state) => {
  const current = readJsonObject(stateFile, null);
  writeJsonIfChanged(stateFile, current, { version: 1, ...state });
};

if (process.argv[2] === "--packages-done") {
  saveState({ ...readJsonObject(stateFile, {}), packagesPending: false });
  process.exit(0);
}

const meta = readDesired("meta.json", {});
const ownership = meta.ownership ?? "enforce";
if (ownership !== "enforce" && ownership !== "merge") {
  process.stderr.write(`pi-nix: unknown ownership mode: ${ownership}\n`);
  process.exit(2);
}
const enforce = ownership === "enforce";

const desiredSettings = readDesired("settings.json");
const desiredMcp = readDesired("mcp.json");
const desiredServers = isObject(desiredMcp.mcpServers) ? desiredMcp.mcpServers : {};
const state = loadState();

// --- settings.json ----------------------------------------------------------
// `packages` is only owned by pi-nix when the flake declares `extensions`.
// With `extensions = null` the user's existing package list is left alone and
// no package reconciliation is triggered.
const packagesManaged = has(desiredSettings, "packages");
const { packages: desiredPackages, ...desiredPlain } = desiredSettings;

const settingsOnDisk = readJsonObject(settingsFile, null);
const currentSettings = settingsOnDisk ?? {};
const nextSettings = mergeKeyed(currentSettings, desiredPlain, state.settings, {
  enforce,
});
if (packagesManaged) {
  nextSettings.packages = mergePackages(
    currentSettings.packages,
    desiredPackages,
    state.packages,
    { enforce },
  );
}
const settingsChanged = writeJsonIfChanged(settingsFile, settingsOnDisk, nextSettings);

const packagesChanged =
  packagesManaged && !equal(currentSettings.packages ?? null, nextSettings.packages);
const packagesPending = packagesManaged && (state.packagesPending || packagesChanged);
const npmPackages = (nextSettings.packages ?? []).some((entry) =>
  String(sourceOf(entry) ?? "").startsWith("npm:"),
);

// --- mcp.json ---------------------------------------------------------------
const mcpOnDisk = readJsonObject(mcpFile, null);
const currentMcp = mcpOnDisk ?? {};
const nextMcp = {
  ...currentMcp,
  mcpServers: mergeKeyed(
    isObject(currentMcp.mcpServers) ? currentMcp.mcpServers : {},
    desiredServers,
    state.mcpServers,
    { enforce, exclusive: enforce },
  ),
};
const mcpChanged = writeJsonIfChanged(mcpFile, mcpOnDisk, nextMcp);

// --- state ------------------------------------------------------------------
// Recorded after the config files and before package installation: a failed
// `pi update` leaves `packagesPending` set, so the next launch retries instead
// of assuming the (already rewritten) package list is installed.
saveState({
  ownership,
  settings: desiredPlain,
  packages: packagesManaged ? desiredPackages : null,
  mcpServers: desiredServers,
  packagesPending,
});

process.stdout.write(`SETTINGS_CHANGED=${settingsChanged ? 1 : 0}\n`);
process.stdout.write(`PACKAGES_CHANGED=${packagesPending ? 1 : 0}\n`);
process.stdout.write(`NPM_PACKAGES=${npmPackages ? 1 : 0}\n`);
process.stdout.write(`MCP_CHANGED=${mcpChanged ? 1 : 0}\n`);
