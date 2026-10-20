#!/usr/bin/env node

// Load only the requested command family. In particular, chat/workflow helpers
// need not initialize the full document/search/agenda command implementation.
import fs from "node:fs";
import process from "node:process";
import { mirrorCelorgaEnvironment } from "./brandNames.js";

// CELORGA_* environment variables are accepted everywhere ORG2_* ones are.
mirrorCelorgaEnvironment();

function org2PackageVersion(): string {
  const packageUrl = new URL("../package.json", import.meta.url);
  const metadata = JSON.parse(fs.readFileSync(packageUrl, "utf8")) as { version?: unknown };
  if (typeof metadata.version !== "string" || !metadata.version.trim()) {
    throw new Error(`package metadata at ${packageUrl.pathname} does not declare a version`);
  }
  return metadata.version;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args[0] === "roam" && ["connections", "mention-link"].includes(args[1] || "")) {
    const { runRoamConnectionsCommand } = await import("./roamConnectionsCli.js");
    await runRoamConnectionsCommand(args);
    return;
  }
  if (args[0] === "browser-clip") {
    const { runBrowserClipCommand } = await import("./browserClip.js");
    await runBrowserClipCommand(args.slice(1));
    return;
  }
  if (args[0] === "canvas") {
    const { runJSONCanvasCommand } = await import("./jsonCanvasCli.js");
    await runJSONCanvasCommand(args);
    return;
  }
  if (args[0] === "activity") {
    const { runActivityCommand } = await import("./activityCli.js");
    await runActivityCommand(args.slice(1));
    return;
  }
  if (args[0] === "server") {
    const { runServerCommand } = await import("./serverCli.js");
    await runServerCommand(args.slice(1));
    return;
  }

  if (args.length === 1 && ["version", "--version", "-v"].includes(args[0] || "")) {
    process.stdout.write(`${org2PackageVersion()}\n`);
    return;
  }

  if (["doctor", "ledger", "corpus", "workspace", "thread", "project", "goal", "agent-profile", "run", "review", "workflow", "artifact", "runtime", "mcp", "eval"].includes(args[0] || "")) {
    const { runAgenticWorkspaceCommand } = await import("./agenticWorkspaceCli.js");
    if (await runAgenticWorkspaceCommand(args)) return;
  }
  if (args[0] === "migrate-names") {
    const { runMigrateNamesCommand } = await import("./migrateNames.js");
    await runMigrateNamesCommand(args.slice(1));
    return;
  }
  if (args[0] === "todo-config") {
    const { runTodoConfigCommand } = await import("./todoConfigCli.js");
    await runTodoConfigCommand(args.slice(1));
    return;
  }
  if (args[0] === "daily-config") {
    const { runDailyConfigCommand } = await import("./dailyConfigCli.js");
    await runDailyConfigCommand(args.slice(1));
    return;
  }
  if (args[0] === "property-view") {
    const { runPropertyViewsCommand } = await import("./propertyViewsCli.js");
    await runPropertyViewsCommand(args.slice(1));
    return;
  }
  if (args[0] === "view") {
    const { runInteractiveViewCommand } = await import("./interactiveViewsCli.js");
    await runInteractiveViewCommand(args.slice(1));
    return;
  }
  if (args[0] === "embed") {
    const { runEmbedCommand } = await import("./liveEmbeds.js");
    await runEmbedCommand(args.slice(1));
    return;
  }
  if (args[0] === "checkbox") {
    const { runCheckboxCommand } = await import("./checkboxCli.js");
    await runCheckboxCommand(args.slice(1));
    return;
  }
  if (args[0] === "skill") {
    const { runSkillCommand } = await import("./skillCli.js");
    if (await runSkillCommand(args)) return;
  }
  if (args[0] === "source" || args[0] === "sources") {
    const { runSourceCommand } = await import("./sourceRuntime.js");
    if (await runSourceCommand(args)) return;
  }
  if (args[0] === "table") {
    const { runTableFormulaCommand } = await import("./tableFormulaCli.js");
    if (await runTableFormulaCommand(args)) return;
  }
  if (args[0] === "plugin" || args[0] === "plugins") {
    const { runPluginCommand } = await import("./pluginCli.js");
    if (await runPluginCommand(args)) return;
  }
  if (args[0] === "publish" && args[1] === "document") {
    const { runPublishDocumentCommand } = await import("./publishDocumentCli.js");
    if (await runPublishDocumentCommand(args)) return;
  }

  // Other argument combinations retain the full CLI's validation and help.
  if (args.length === 2 && args[0] === "agent" && args[1] === "capabilities") {
    const { buildOrg2CapabilityManifest } = await import("./capabilities.js");
    process.stdout.write(JSON.stringify(buildOrg2CapabilityManifest(), null, 2) + "\n");
    return;
  }
  await import("./cliMain.js");
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : err);
  process.exit(1);
});
