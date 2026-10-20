import { applyInteractiveViewAction, createInteractiveView, handleViewBridgeIntent, listInteractiveViews, loadInteractiveView, previewInteractiveViewAction, refreshInteractiveView, renderInteractiveViewOrg, undoInteractiveViewAction, updateInteractiveViewState } from "./interactiveViews.js";

const HELP = `celorga view

Saved, refreshable interactive workspace views (first kind: daily-plan).
Usage:
  celorga view list --dir CORPUS
  celorga view create ID --title TEXT [--kind daily-plan] [--available-minutes N] [--deadline-days N] --dir CORPUS [--apply]
  celorga view show ID --dir CORPUS
  celorga view refresh ID [--date YYYY-MM-DD] [--format json|org] --dir CORPUS
  celorga view state ID --patch JSON --if-revision SHA --dir CORPUS [--apply]
  celorga view action ID --action JSON --dir CORPUS
  celorga view action ID --action JSON --fingerprint SHA --if-revision SHA [--actor NAME] --dir CORPUS --apply
  celorga view undo ID --action-id ID --dir CORPUS [--apply]
  celorga view bridge ID --message JSON --dir CORPUS

Views live in views/ID.org2-interactive-view.json with their remembered
choices (availableMinutes, order, excluded, estimates) and action history.
Refresh recompiles canonical Org sources; every item links its source task.
Writes preview by default. Choice saves require the view revision; actions
require the preview fingerprint and the source file revision, and undo refuses
when the source changed afterwards. The only action is
{"action":"schedule","task":"id:UUID","date":"YYYY-MM-DD"}.
"view bridge" validates a sandboxed frame intent (set-state, preview-action,
open-source); it can save choices or preview, never apply.`;

export async function runInteractiveViewCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h") || !args.length) { process.stdout.write(HELP + "\n"); return; }
  const values = [...args];
  const action = values.shift()!;
  const allowedByAction: Record<string, string[]> = {
    list: [], show: [], refresh: ["--date", "--format"],
    create: ["--title", "--kind", "--available-minutes", "--deadline-days"],
    state: ["--patch", "--if-revision"], action: ["--action", "--fingerprint", "--if-revision", "--actor"],
    undo: ["--action-id"], bridge: ["--message"],
  };
  const allowed = allowedByAction[action];
  if (!allowed) throw new Error("Expected view list, create, show, refresh, state, action, undo or bridge");
  const id = action === "list" ? undefined : values.shift();
  if (action !== "list" && (!id || id.startsWith("--"))) throw new Error(`view ${action} requires a view ID`);
  const flags = new Map<string, string>();
  let apply = false;
  while (values.length) {
    const key = values.shift()!;
    if (key === "--json") continue;
    if (key === "--apply" && ["create", "state", "action", "undo"].includes(action)) { apply = true; continue; }
    if (!["--dir", ...allowed].includes(key) || flags.has(key)) throw new Error(`Unknown or duplicate view option: ${key}`);
    const value = values.shift();
    if (value === undefined) throw new Error(`Missing value for ${key}`);
    flags.set(key, value);
  }
  const required = (key: string) => { const value = flags.get(key); if (value === undefined) throw new Error(`Required: ${key}`); return value; };
  const int = (key: string) => flags.has(key) ? Number(required(key)) : undefined;
  const root = required("--dir");
  let result: unknown;
  try {
    switch (action) {
      case "list": result = listInteractiveViews(root); break;
      case "create": result = createInteractiveView(root, { id: id!, title: required("--title"), kind: flags.get("--kind"), availableMinutes: int("--available-minutes"), deadlineHorizonDays: int("--deadline-days") }, { apply }); break;
      case "show": result = { schema: "org2:interactive-view-show:v1", ...loadInteractiveView(root, id!) }; break;
      case "refresh": {
        const format = flags.get("--format") ?? "json";
        if (!["json", "org"].includes(format)) throw new Error("--format must be json or org");
        const refresh = refreshInteractiveView(root, id!, { date: flags.get("--date") });
        if (format === "org") { process.stdout.write(renderInteractiveViewOrg(refresh)); return; }
        result = refresh; break;
      }
      case "state": result = updateInteractiveViewState(root, id!, JSON.parse(required("--patch")), { expectedRevision: required("--if-revision"), apply }); break;
      case "action": {
        const request = JSON.parse(required("--action"));
        result = apply
          ? applyInteractiveViewAction(root, id!, request, { fingerprint: required("--fingerprint"), sourceRevision: required("--if-revision"), actor: flags.get("--actor") })
          : previewInteractiveViewAction(root, id!, request);
        break;
      }
      case "undo": result = undoInteractiveViewAction(root, id!, required("--action-id"), { apply }); break;
      case "bridge": result = handleViewBridgeIntent(root, JSON.parse(required("--message")), { viewId: id! }); break;
    }
  } catch (error) {
    const code = (error as { code?: string }).code;
    if (code === "ORG2_WRITE_CONFLICT") {
      process.stdout.write(JSON.stringify({ schema: "org2:interactive-view-error:v1", code, message: (error as Error).message }, null, 2) + "\n");
      process.exitCode = 3;
      return;
    }
    throw error;
  }
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
}
