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
    height: 800,
    scale: 2,
    crop: { x: 706, y: 40, width: 544, height: 560 },
    fileName: "home-agent-work.png",
  },
  {
    mode: "approvals",
    target: "publish the beacon launch brief",
    width: 1250,
    height: 900,
    scale: 2,
    crop: { x: 712, y: 160, width: 530, height: 206 },
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

// Homepage hero: Start work on a TODO, frame by frame. Every frame is the real
// app rendered by the screenshot renderer; site/assets/hero-demo.js crossfades
// them and moves a pointer between the controls. The agent's activity and
// reply are the only scripted content.
const startWorkHeading = "Review launch readiness brief";
const startWorkFile = "notes/projects/beacon-launch.org2";
const startWorkActivities = [
  { title: "Read", detail: "notes/projects/beacon-launch.org2" },
  { title: "Read", detail: "meetings/2026-06-15-0900-beta-review.org2" },
  { title: "Read", detail: "views/launch-readiness-data.org2" },
];
const startWorkReply = `* Ready for a private beta

- *Offline import is unverified.* The [[id:77777777-7777-4777-8777-777777777777][Beta review]] left the CSV check open, due Jun 18.
- *Seven blockers remain open,* three in docs. See [[file:../../views/launch-readiness-data.org2][launch readiness]].

Want me to add this summary under the task?`;
const startWorkFrames = [
  { name: "before", stage: "before" },
  { name: "hover", stage: "before", hover: true },
  { name: "sheet", stage: "before", hover: true, sheet: true },
  { name: "working", stage: "working", activities: startWorkActivities.slice(0, 2).concat([{ ...startWorkActivities[2], status: "running" }]) },
  { name: "streaming", stage: "working", activities: startWorkActivities, partial: startWorkReply.split("\n\n").slice(0, 2).join("\n\n") },
  { name: "done", stage: "done", activities: startWorkActivities, reply: startWorkReply },
].map((frame, index) => ({
  mode: "start-work",
  target: "notes/projects/beacon-launch",
  width: 1440,
  height: 780,
  scale: 2,
  settleMs: 2500,
  // Keep the two panes the hero is about; the sidebar and tab bar make the
  // text too small at page width.
  crop: { x: 361, y: 36, width: 1079, height: 744 },
  format: "webp",
  fileName: `home-start-work-${index + 1}-${frame.name}.webp`,
  startWork: frame,
}));
scenarios.push(...startWorkFrames);

// Each Start work frame starts from a clean copy of the demo corpus. Frames
// after the click get the run and heading link that Start work creates, using
// the same CLI calls as the app.
function prepareStartWorkCorpus(frame) {
  rmSync(renderCorpusRoot, { recursive: true, force: true });
  cpSync(corpusRoot, renderCorpusRoot, { recursive: true });
  if (frame.stage === "before") return;
  const notePath = join(renderCorpusRoot, startWorkFile);
  const lines = readFileSync(notePath, "utf8").split("\n");
  const headingIndex = lines.findIndex((line) => line.endsWith(` ${startWorkHeading}`));
  const cli = (args) => run("node", [join(repoRoot, "dist", "cli.js"), ...args, "--dir", renderCorpusRoot, "--json"], { capture: true });
  const created = JSON.parse(cli([
    "run", "create",
    "--title", `Work: ${startWorkHeading}`,
    "--goal", startWorkHeading,
    "--context", `file:${startWorkFile}:${headingIndex + 1}`,
    "--owner", "Celorga",
    "--assignee", "OpenClaw",
  ]));
  const runID = created.run?.id ?? created.id;
  cli(["run", "start", runID, "--actor", "Celorga"]);
  lines[headingIndex] = lines[headingIndex].replace(/^(\*+) TODO /, "$1 IN_PROGRESS ");
  const drawerEnd = lines.findIndex((line, index) => index > headingIndex && line.trim() === ":END:");
  lines.splice(drawerEnd, 0, `:ORG2_RUN_ID: ${runID}`);
  writeFileSync(notePath, lines.join("\n"));
}

function startWorkEnvironment(frame) {
  if (!frame) return {};
  return {
    ORG2_WORKSPACE_SCREENSHOT_START_WORK_STAGE: frame.stage,
    ORG2_WORKSPACE_SCREENSHOT_START_WORK_HEADING: startWorkHeading,
    ORG2_WORKSPACE_SCREENSHOT_START_WORK_DESTINATION: "builtin.openclaw",
    // Fold the heading's Properties drawer so the task's notes stay in view.
    ORG2_WORKSPACE_SCREENSHOT_COLLAPSE_PROPERTIES: "1",
    ...(frame.hover ? { ORG2_WORKSPACE_SCREENSHOT_START_WORK_HOVER: startWorkHeading } : {}),
    ...(frame.sheet ? { ORG2_WORKSPACE_SCREENSHOT_START_WORK_SHEET: startWorkHeading } : {}),
    ...(frame.activities ? { ORG2_WORKSPACE_SCREENSHOT_START_WORK_ACTIVITIES: JSON.stringify(frame.activities) } : {}),
    ...(frame.partial ? { ORG2_WORKSPACE_SCREENSHOT_START_WORK_PARTIAL_REPLY: frame.partial } : {}),
    ...(frame.reply ? { ORG2_WORKSPACE_SCREENSHOT_START_WORK_REPLY: frame.reply } : {}),
  };
}

function captureScenario(scenario, theme) {
  const outputPath = join(screenshotDir, scenario.fileName);
  const scale = scenario.scale ?? 1;
  // Cropped homepage shots render the full window first, then keep only the
  // region named in points so the published image stays readable at page size.
  const renderPath = scenario.crop || scenario.format
    ? join(tmpdir(), `celorga-screenshot-${process.pid}-${scenario.fileName}.png`)
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
      ...startWorkEnvironment(scenario.startWork),
    },
  });
  if (scenario.crop) {
    const { x, y, width, height } = scenario.crop;
    run("sips", [
      "--cropOffset", String(Math.round(y * scale)), String(Math.round(x * scale)),
      "-c", String(Math.round(height * scale)), String(Math.round(width * scale)),
      renderPath, "--out", scenario.format ? renderPath : outputPath,
    ], { capture: true });
  }
  if (scenario.format === "webp") {
    run("cwebp", ["-quiet", "-q", "86", renderPath, "-o", outputPath], { capture: true });
  }
  if (renderPath !== outputPath) rmSync(renderPath, { force: true });
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
    if (scenario.startWork) prepareStartWorkCorpus(scenario.startWork);
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
