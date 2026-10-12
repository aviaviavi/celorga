#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageDir = join(repoRoot, "apps", "macos", "Org2Workspace");
const corpusRoot = join(repoRoot, "examples", "macos-workspace-demo");
const renderCorpusContainer = "/tmp/celorga-macos-workspace-demo";
const renderCorpusRoot = join(renderCorpusContainer, "Celorga Demo");

function corpusConfigName(root) {
  return existsSync(join(root, "celorga.json")) ? "celorga.json" : "org2.json";
}
const screenshotDir = join(repoRoot, "docs", "site", "assets", "screenshots");
// Published screenshots use one catalog theme so the site stays visually
// consistent. Override with --theme=ID (for example --theme=spacemacs-dark).
const defaultTheme = "spacemacs-light";

const scenarios = [
  {
    mode: "agenda",
    target: "review launch plan",
    agendaMode: "range",
    width: 1600,
    height: 900,
    scale: 2,
    fileName: "macos-workspace-agenda.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    scale: 2,
    fileName: "macos-workspace-runs-review.png",
  },
  {
    mode: "files",
    target: "notes/projects/beacon-launch",
    scale: 2,
    fileName: "macos-workspace-files.png",
  },
  {
    mode: "files",
    target: "notes/projects/beacon-launch",
    contextTab: "brief",
    scale: 2,
    fileName: "macos-workspace-context.png",
  },
  {
    mode: "files",
    target: "views/launch-readiness-data",
    scale: 2,
    fileName: "macos-workspace-data.png",
  },
  {
    mode: "ai-room",
    scale: 2,
    fileName: "macos-workspace-ai-room.png",
  },
  {
    mode: "meetings",
    target: "beta review",
    scale: 2,
    fileName: "macos-workspace-meetings.png",
  },
  // Homepage crops: rendered at 2x and cropped (in points) to the part of the
  // window each homepage section describes.
  {
    mode: "ai-room",
    target: "atlas pilot handoff",
    width: 1400,
    height: 1000,
    scale: 2,
    crop: { x: 352, y: 92, width: 1048, height: 572 },
    fileName: "home-agents-room.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    width: 1250,
    height: 700,
    scale: 2,
    crop: { x: 314, y: 36, width: 936, height: 630 },
    fileName: "home-agent-work.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    width: 1400,
    height: 700,
    scale: 2,
    crop: { x: 800, y: 200, width: 590, height: 210 },
    fileName: "home-approval-desktop.png",
  },
  {
    mode: "files",
    target: "views/launch-readiness-data",
    width: 900,
    height: 1150,
    scale: 2,
    settleMs: 6000,
    crop: { x: 228, y: 150, width: 660, height: 740 },
    fileName: "home-data-notebook.png",
  },
  {
    mode: "meetings",
    target: "beta review",
    contextTab: "references",
    width: 1900,
    height: 1500,
    scale: 2,
    settleMs: 6000,
    crop: { x: 1070, y: 590, width: 830, height: 840 },
    fileName: "home-meeting-notes.png",
  },
];

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: options.env ?? process.env,
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      detail ? `${command} ${args.join(" ")} failed:\n${detail}` : `${command} ${args.join(" ")} failed`
    );
  }
  return result.stdout?.trim() ?? "";
}

function captureScenario(scenario, theme) {
  const outputPath = join(screenshotDir, scenario.fileName);
  const scale = scenario.scale ?? 1;
  // Cropped homepage shots render the full window first, then keep only the
  // region named in points so the published image stays readable at page size.
  const renderPath = scenario.crop
    ? join(tmpdir(), `celorga-screenshot-${process.pid}-${scenario.fileName}`)
    : outputPath;
  run("swift", ["run", "Org2WorkspaceScreenshotRenderer", "--out", renderPath], {
    cwd: packageDir,
    env: {
      ...process.env,
      ORG2_REPO_ROOT: repoRoot,
      ORG2_WORKSPACE_SCREENSHOT_CORPUS: renderCorpusRoot,
      ORG2_WORKSPACE_SCREENSHOT_MODE: scenario.mode,
      ORG2_WORKSPACE_SCREENSHOT_TARGET: scenario.target ?? "",
      ORG2_WORKSPACE_SCREENSHOT_AGENDA_MODE: scenario.agendaMode ?? "",
      ORG2_WORKSPACE_SCREENSHOT_CONTEXT_TAB: scenario.contextTab ?? "",
      ORG2_WORKSPACE_SCREENSHOT_WIDTH: String(scenario.width ?? 1400),
      ORG2_WORKSPACE_SCREENSHOT_HEIGHT: String(scenario.height ?? 900),
      ORG2_WORKSPACE_SCREENSHOT_SCALE: String(scale),
      ORG2_WORKSPACE_SCREENSHOT_THEME: theme,
      ...(scenario.settleMs ? { ORG2_WORKSPACE_SCREENSHOT_SETTLE_MS: String(scenario.settleMs) } : {}),
    },
  });
  if (scenario.crop) {
    const { x, y, width, height } = scenario.crop;
    run("sips", [
      "--cropOffset", String(Math.round(y * scale)), String(Math.round(x * scale)),
      "-c", String(Math.round(height * scale)), String(Math.round(width * scale)),
      renderPath, "--out", outputPath,
    ], { capture: true });
    rmSync(renderPath, { force: true });
  }
  console.log(`Rendered ${outputPath}`);
}

// Keep the agenda useful whenever it is recaptured. Only the disposable copy
// gets date-relative planning examples; the checked-in demo remains untouched.
function prepareAgendaDemo() {
  const stamp = (offset) => {
    const date = new Date();
    date.setHours(12, 0, 0, 0);
    date.setDate(date.getDate() + offset);
    const iso = [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
    const day = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][date.getDay()];
    return `<${iso} ${day}>`;
  };
  writeFileSync(join(renderCorpusRoot, "notes/projects/launch.org"), `#+TITLE: Beacon launch

* TODO [#A] Review launch plan
SCHEDULED: ${stamp(0)}

Keep the first release small: a clear welcome, a useful sample dashboard, and a direct way to send feedback.

** Ready for review
- [X] Welcome email and setup guide
- [X] Sample data and dashboard walkthrough
- [ ] Confirm the support handoff with Maya
- [ ] Send the final checklist to the pilot team

** Decisions from the team
Start with five teams. Review their first week together before opening the next group.

* TODO [#A] Confirm pilot invitations
DEADLINE: ${stamp(-1)}

Check the final team list before sending the welcome email.

* IN_PROGRESS Polish setup guide
SCHEDULED: ${stamp(0)}

Walk through a fresh installation and tighten the first-run instructions.

* TODO Send pilot welcome email
SCHEDULED: ${stamp(1)}

Include the setup guide and a link to the feedback note.

* TODO Review first-week feedback
SCHEDULED: ${stamp(3)}

Collect the pilot team's questions and prioritize the next improvements.
`);
  writeFileSync(join(renderCorpusRoot, "notes/projects/website.org"), `#+TITLE: Website refresh

* TODO Choose homepage screenshots
SCHEDULED: ${stamp(0)}

Show the current app with readable, realistic examples.

* TODO Publish the product update
SCHEDULED: ${stamp(2)}

Link the refreshed tour from the release notes.
`);
  const configPath = join(renderCorpusRoot, corpusConfigName(renderCorpusRoot));
  const config = JSON.parse(readFileSync(configPath, "utf8"));
  config.agendaFiles = ["notes/projects/launch.org", "notes/projects/website.org"];
  writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
}

function main() {
  if (process.platform !== "darwin") {
    throw new Error("macOS Workspace screenshots can only be rendered on macOS.");
  }
  if (!existsSync(corpusRoot)) {
    throw new Error(`Demo corpus not found: ${corpusRoot}`);
  }

  mkdirSync(screenshotDir, { recursive: true });
  rmSync(renderCorpusContainer, { recursive: true, force: true });
  mkdirSync(renderCorpusContainer, { recursive: true });
  cpSync(corpusRoot, renderCorpusRoot, { recursive: true });
  run("npm", ["run", "build"]);

  // --only=PREFIX limits the run to screenshots whose file name starts with
  // PREFIX, for example --only=home- for the homepage crops.
  const only = process.argv.find((arg) => arg.startsWith("--only="))?.slice("--only=".length);
  const selected = only ? scenarios.filter((scenario) => scenario.fileName.startsWith(only)) : scenarios;
  if (selected.length === 0) {
    throw new Error(`No screenshot scenarios match --only=${only}`);
  }
  const theme = process.argv.find((arg) => arg.startsWith("--theme="))?.slice("--theme=".length) || defaultTheme;
  for (const scenario of selected) {
    if (scenario.mode === "agenda") prepareAgendaDemo();
    captureScenario(scenario, theme);
    if (scenario.mode === "agenda") {
      // Other scenarios continue to use their established demo records.
      rmSync(join(renderCorpusRoot, "notes/projects/launch.org"));
      rmSync(join(renderCorpusRoot, "notes/projects/website.org"));
      const configName = corpusConfigName(corpusRoot);
      cpSync(join(corpusRoot, configName), join(renderCorpusRoot, configName));
    }
  }

  run("npm", ["run", "celorga", "--", "publish", "docs-site", "--config", "celorga.json"]);
  console.log("Updated macOS Workspace screenshot assets.");
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
