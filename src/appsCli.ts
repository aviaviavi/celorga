import { listWorkspaceApps, renderPluginSurface, setWorkspaceAppEnabled } from "./workspaceApps.js";

const HELP = `celorga apps

Optional workspace apps: sidebar surfaces that stay hidden until a corpus turns
them on. Built-in apps include People & Companies (crm) and Canvases
(canvases); installed plugins that contribute surfaces appear as plugin:ID.
Enablement is portable corpus intent stored in celorga.json under "apps".

Usage:
  celorga apps list --dir CORPUS [--no-suggestions]
  celorga apps enable APP_ID --dir CORPUS [--if-revision SHA] [--apply]
  celorga apps disable APP_ID --dir CORPUS [--if-revision SHA] [--apply]
  celorga apps render PLUGIN_ID:SURFACE_ID --dir CORPUS

list reports each app, whether it is on, and a suggestion when the corpus
already holds data the app is useful for. render runs a trusted plugin surface
in the plugin sandbox and returns HTML for a sandboxed, network-free frame.
All responses are JSON. enable and disable preview unless --apply is given.`;

export async function runAppsCommand(args: string[]): Promise<void> {
  if (!args.length || args.includes("--help") || args.includes("-h")) { process.stdout.write(HELP + "\n"); return; }
  const values = [...args];
  const action = values.shift()!;
  const positional: string[] = [];
  const flags = new Map<string, string>();
  let apply = false;
  let suggestions = true;
  while (values.length) {
    const token = values.shift()!;
    if (token === "--json") continue;
    if (token === "--apply") { apply = true; continue; }
    if (token === "--no-suggestions") { suggestions = false; continue; }
    if (token === "--dir" || token === "--if-revision") {
      const value = values.shift();
      if (value === undefined) throw new Error(`Missing value for ${token}`);
      flags.set(token, value);
      continue;
    }
    if (token.startsWith("--")) throw new Error(`Unknown apps option: ${token}`);
    positional.push(token);
  }
  const dir = flags.get("--dir");
  if (!dir) throw new Error("Required: --dir CORPUS");
  let result: unknown;
  if (action === "list") result = listWorkspaceApps(dir, { suggestions });
  else if (action === "enable" || action === "disable") {
    if (!positional[0]) throw new Error(`apps ${action} requires an app ID`);
    result = setWorkspaceAppEnabled(dir, positional[0], action === "enable", { apply, expectedRevision: flags.get("--if-revision") });
  } else if (action === "render") {
    if (!positional[0]) throw new Error("apps render requires PLUGIN_ID:SURFACE_ID");
    result = renderPluginSurface(dir, positional[0]);
  } else throw new Error("Expected apps list, enable, disable or render");
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
}
