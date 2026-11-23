// Locates the Google OAuth Desktop client the macOS build bundles. The client
// JSON never lives in this repository. Builds read, in order:
//   1. --google-oauth-client-json PATH (handled by the caller)
//   2. CELORGA_GOOGLE_OAUTH_CLIENT_JSON or ORG2_GOOGLE_OAUTH_CLIENT_JSON
//   3. the paired CELORGA_/ORG2_GOOGLE_OAUTH_CLIENT_ID and _SECRET values
//   4. the machine-local default file below, when it exists
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export function googleOAuthEnvironmentValue(name, env = process.env) {
  return env[`CELORGA_${name}`]?.trim() || env[`ORG2_${name}`]?.trim() || "";
}

/** `$XDG_CONFIG_HOME/celorga/google-oauth-client.json`, or `~/.config/...`. */
export function defaultGoogleOAuthClientJSONPath(env = process.env) {
  const configHome = env.XDG_CONFIG_HOME?.trim() || join(env.HOME?.trim() || homedir(), ".config");
  return join(configHome, "celorga", "google-oauth-client.json");
}

/**
 * Returns `{ jsonPath, source }` for the configured client JSON, or
 * `{ jsonPath: "", source: null }` when only an environment pair (or nothing)
 * is configured. Explicit configuration always wins over the default file.
 */
export function configuredGoogleOAuthClientJSON(env = process.env) {
  const explicit = googleOAuthEnvironmentValue("GOOGLE_OAUTH_CLIENT_JSON", env);
  if (explicit) return { jsonPath: explicit, source: "desktop-client-json" };
  if (
    googleOAuthEnvironmentValue("GOOGLE_OAUTH_CLIENT_ID", env)
    || googleOAuthEnvironmentValue("GOOGLE_OAUTH_CLIENT_SECRET", env)
  ) {
    return { jsonPath: "", source: null };
  }
  const fallback = defaultGoogleOAuthClientJSONPath(env);
  if (existsSync(fallback)) return { jsonPath: fallback, source: "default-client-json" };
  return { jsonPath: "", source: null };
}
