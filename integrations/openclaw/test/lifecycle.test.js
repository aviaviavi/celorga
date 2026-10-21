import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { approvedRunContinuationPrompt, clarificationContinuationPrompt, conciseGoal, cronKey, cronPayloadText, cronSessionKey, durableRunMarker, executionSummary, outcomeCommand, shouldEnsureCronRun, shouldTrackMainTurn, workflowContinuationPrompt, workflowExecutionPrompt, workflowMarker, workflowRevisionPrompt } from "../lib/lifecycle.js";
import { Org2Lifecycle } from "../lib/lifecycle.js";
import { approvalAction, approvalContext, approvalTitle, draftCreatedEffect, draftSendEffect } from "../lib/draft-approvals.js";

const lifecycleTestRoot = await mkdtemp(join(tmpdir(), "org2-openclaw-lifecycle-tests-"));
let lifecycleTestStateID = 0;
const newTestLifecycle = (options = {}) => new Org2Lifecycle({
  stateFile: join(lifecycleTestRoot, `state-${lifecycleTestStateID += 1}.json`),
  ...options,
});

test("tracks substantial work but not acknowledgements or heartbeats", () => {
  assert.equal(shouldTrackMainTurn("Please implement the lifecycle plugin", {}), true);
  assert.equal(shouldTrackMainTurn("cool", {}), false);
  assert.equal(shouldTrackMainTurn("investigate the failed job", { trigger: "heartbeat" }), false);
});

test("excludes internal skill reviews without suppressing requested skill work", () => {
  const prompt = "Skill review. Distill new durable learning from the full retained conversation.";
  const ctx = {
    sessionKey: "agent:org2:internal-session-effects:skill-workshop-review_7625c241",
    runId: "skill-workshop-review:7625c241",
  };
  assert.equal(shouldTrackMainTurn(prompt, ctx), false);
  assert.equal(shouldTrackMainTurn(prompt, { sessionKey: ctx.sessionKey }), false);
  assert.equal(shouldTrackMainTurn(prompt, { runId: ctx.runId }), false);
  assert.equal(shouldTrackMainTurn("Please review and update this skill", { sessionKey: "agent:org2:main" }), true);
  assert.equal(shouldTrackMainTurn("ORG2_WORKFLOW_ID: weekly-review\nExecute the workflow", ctx), false);
});

test("maps terminal outcomes", () => {
  assert.equal(outcomeCommand("ok"), "complete");
  assert.equal(outcomeCommand("timeout"), "fail");
  assert.equal(outcomeCommand("interrupted"), "fail");
  assert.equal(outcomeCommand("killed"), "cancel");
});

test("recognizes an explicitly delegated durable run", () => {
  assert.equal(durableRunMarker("Do the work.\nORG2_RUN_ID: run-42\n"), "run-42");
  assert.equal(durableRunMarker("ORG2_WORKFLOW_RUN_ID: workflow-run-42"), undefined);
});

test("bounds run goals", () => assert.ok(conciseGoal("x".repeat(400)).length <= 240));

test("extracts a concise outcome from the last assistant message", () => {
  assert.equal(executionSummary([
    { role: "assistant", content: "Older" },
    { role: "user", content: "Continue" },
    { role: "assistant", content: [{ type: "text", text: "Finished the workflow.\nArtifacts are ready." }] },
  ]), "Finished the workflow. Artifacts are ready.");
});

test("uses the same cron key when finish adds run and session ids", () => {
  const started = { jobId: "job-1", runAtMs: 123 };
  const finished = { jobId: "job-1", runAtMs: 123, runId: "run-1", sessionId: "session-1" };
  assert.equal(cronKey(started), cronKey(finished));
});

test("derives the agent-scoped OpenClaw session for cron continuations", () => {
  assert.equal(
    cronSessionKey({ jobId: "job-1" }, "scarf-support"),
    "agent:scarf-support:cron:job-1",
  );
  assert.equal(
    cronSessionKey({ jobId: "job-1", sessionKey: "agent:custom:cron:one" }, "scarf-support"),
    "agent:custom:cron:one",
  );
  assert.equal(cronSessionKey({ jobId: "job-1" }, undefined), undefined);
});

test("reads current and legacy OpenClaw cron prompt payloads", () => {
  assert.equal(cronPayloadText({ kind: "agentTurn", message: "current" }), "current");
  assert.equal(cronPayloadText({ kind: "agentTurn", text: "legacy" }), "legacy");
  assert.equal(cronPayloadText(undefined), "");
});

test("defers triggered cron lifecycle creation until a real execution finishes", () => {
  assert.equal(shouldEnsureCronRun({ action: "started", job: {} }), true);
  assert.equal(shouldEnsureCronRun({ action: "finished", job: {} }), false);
  assert.equal(shouldEnsureCronRun({ action: "started", job: { trigger: { script: "json({ fire: false })" } } }), false);
  assert.equal(shouldEnsureCronRun({ action: "finished", job: { trigger: { script: "json({ fire: true })" } } }), true);
  assert.equal(shouldEnsureCronRun({ action: "started", job: {} }, true), false);
  assert.equal(shouldEnsureCronRun({ action: "finished", job: {} }, true), true);
});

test("detects triggered cron jobs from the full scheduler inventory", async () => {
  const lifecycle = new Org2Lifecycle({
    cron: {
      list: async () => ({
        jobs: [
          { id: "ordinary", name: "Ordinary job" },
          { id: "gated", name: "Gated job", trigger: { script: "json({ fire: false })" } },
        ],
      }),
    },
  });
  assert.equal(await lifecycle.cronHasTrigger("ordinary"), false);
  assert.equal(await lifecycle.cronHasTrigger("gated"), true);
  assert.equal(await lifecycle.cronHasTrigger("missing", true), true);
});

test("recognizes prepared Org2 workflow runs", () => {
  const prompt = workflowExecutionPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, { week: "2026-W29" }, "run-42");
  assert.deepEqual(workflowMarker(prompt), {
    workflowId: "weekly-review",
    workflowRunId: "run-42",
    inputs: { week: "2026-W29" },
  });
  assert.equal(shouldTrackMainTurn(prompt, {}), true);
  assert.equal(shouldTrackMainTurn(prompt, { jobId: "cron-1" }), false);
  assert.match(prompt, /Provider draft: PROVIDER:TOOL:DRAFT_ID/);
  assert.match(prompt, /ORG2_AI_CHAT_THREAD_ID/);
  assert.match(prompt, /celorga thread post THREAD_ID/);
  assert.match(workflowContinuationPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, "run-42"), /artifact-review/);
  assert.match(workflowContinuationPrompt({ id: "weekly-review", version: "1.2.0", title: "Weekly review" }, "run-42"), /celorga run approval-resolve --decision-key/);
});

test("recognizes a workflow run already started by OpenOrg", async () => {
  const marker = workflowMarker([
    "ORG2_WORKFLOW_ID: weekly-review",
    "ORG2_WORKFLOW_RUN_ID: run-42",
    "ORG2_WORKFLOW_RUN_STARTED: true",
    "ORG2_WORKFLOW_INPUTS: {}",
  ].join("\n"));
  assert.equal(marker.workflowRunStarted, true);

  const calls = [];
  const lifecycle = newTestLifecycle({
    exec: async (args) => {
      calls.push(args);
      return "";
    },
  });
  await lifecycle.attach("turn:openorg:run-42", "run-42", { runAlreadyStarted: true });
  assert.equal(calls.some((args) => args[0] === "run" && args[1] === "start"), false);
  assert.equal(calls.some((args) => args[0] === "run" && args[1] === "comment"), true);
});

test("reply and resume persists the clarification and returns its correlated session", async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), "org2-clarification-resume-"));
  const blocked = {
    id: "run-clarification",
    goal: "Prepare the customer proposal",
    status: "blocked",
    blockedReason: "Which commercial terms should we use?",
  };
  const lifecycle = newTestLifecycle({
    stateFile: join(dir, "state.json"),
    exec: async (args) => {
      calls.push(args);
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "run" && args[1] === "show") return JSON.stringify(blocked);
      if (args[0] === "run" && args[1] === "comment") return JSON.stringify({ ...blocked, comments: [{ body: "Use the current plan." }] });
      if (args[0] === "run" && args[1] === "resume") return JSON.stringify({ ...blocked, status: "running" });
      throw new Error(`unexpected command: ${args.join(" ")}`);
    },
  });
  lifecycle.state.mappings.clarification = {
    org2RunId: blocked.id,
    sessionKey: "agent:scarf-support:cron:job-1",
    pausedAt: "2026-08-04T12:00:00.000Z",
    pausedStatus: "blocked",
    createdAt: "2026-08-04T11:00:00.000Z",
  };

  const result = await lifecycle.replyAndResumeRun(blocked.id, "  Use the current plan.  ", {
    expectedCorpusId: "personal",
  });

  assert.equal(result.run.status, "running");
  assert.equal(result.sessionKey, "agent:scarf-support:cron:job-1");
  assert.equal(result.correlated, true);
  assert.equal(durableRunMarker(result.prompt), blocked.id);
  assert.match(result.prompt, /Use the current plan\./);
  assert.match(result.prompt, /do not create a replacement run/);
  assert.deepEqual(calls.find((args) => args[1] === "comment"), [
    "run", "comment", blocked.id, "--author", "Workspace user", "--body", "Use the current plan.", "--json",
  ]);
  assert.equal(lifecycle.state.mappings.clarification.pausedAt, undefined);
  assert.equal(lifecycle.state.mappings.clarification.pausedStatus, undefined);
});

test("reply and resume returns a usable fallback prompt without stale session correlation", async () => {
  const blocked = { id: "run-unmapped", goal: "Continue work", status: "blocked", blockedReason: "What next?" };
  const lifecycle = newTestLifecycle({
    exec: async (args) => {
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[1] === "show" || args[1] === "comment") return JSON.stringify(blocked);
      if (args[1] === "resume") return JSON.stringify({ ...blocked, status: "running" });
      throw new Error(`unexpected command: ${args.join(" ")}`);
    },
  });

  const result = await lifecycle.replyAndResumeRun(blocked.id, "Proceed with option B.");
  assert.equal(result.sessionKey, undefined);
  assert.equal(result.correlated, false);
  assert.match(clarificationContinuationPrompt(blocked, "Proceed with option B."), /ORG2_RUN_ID: run-unmapped/);
});

test("prepares a durable run before handing a workflow to OpenClaw", async () => {
  const calls = [];
  const workflow = { id: "weekly-review", version: "1.0.0", title: "Weekly review" };
  const lifecycle = newTestLifecycle({
    owner: "operator",
    exec: async (args) => {
      calls.push(args);
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "run") return JSON.stringify({ run: { id: "run-1" } });
      if (args[0] === "workflow" && args[1] === "show") return JSON.stringify(workflow);
      return "";
    },
  });
  const prepared = await lifecycle.prepareWorkflowRun("weekly-review", { week: "29" });
  assert.equal(prepared.run.id, "run-1");
  assert.equal(workflowMarker(prepared.prompt).workflowRunId, "run-1");
  assert.deepEqual(calls.find((args) => args[0] === "workflow" && args[1] === "run"), ["workflow", "run", "weekly-review", "--owner", "operator", "--json", "--input", "week=29"]);
});

test("resolves a named OpenClaw agent profile and stamps its goal on a durable run", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-agent-profile-"));
  const calls = [];
  const lifecycle = newTestLifecycle({
    owner: "operator",
    stateFile: join(dir, "state.json"),
    exec: async (args) => {
      calls.push(args);
      if (args[0] === "agent-profile") return JSON.stringify({
        found: true,
        agentRef: "scarf-support",
        goalRef: "customer-trust",
      });
      if (args[0] === "run" && args[1] === "create") return JSON.stringify({ run: { id: "run-identity" } });
      return "";
    },
  });
  await lifecycle.init();
  await lifecycle.ensure("turn:agent:scarf-support:chat:1", {
    kind: "agent-turn",
    goal: "Resolve a support request",
    sessionKey: "agent:scarf-support:chat:1",
    runtimeAgentId: "scarf-support",
    selectedAgentRef: "scarf-support",
    selectedGoalRef: "urgent-support",
  });
  assert.deepEqual(calls[0], [
    "agent-profile", "resolve",
    "--runtime", "openclaw",
    "--runtime-agent-id", "scarf-support",
    "--json",
  ]);
  const create = calls.find((args) => args[0] === "run" && args[1] === "create");
  assert.ok(create.includes("--agent-ref"));
  assert.equal(create[create.indexOf("--agent-ref") + 1], "scarf-support");
  assert.equal(create[create.indexOf("--goal-ref") + 1], "urgent-support");
  const comment = calls.find((args) => args[0] === "run" && args[1] === "comment");
  assert.match(comment.at(-1), /OPENCLAW_AGENT_ID: scarf-support/);
  assert.match(comment.at(-1), /ORG2_AGENT_REF: scarf-support/);
});

test("keeps an explicit workflow goal ahead of an agent profile default", async () => {
  const calls = [];
  const lifecycle = newTestLifecycle({
    exec: async (args) => {
      calls.push(args);
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "agent-profile") return JSON.stringify({ agentRef: "scarf-support", goalRef: "customer-trust" });
      if (args[0] === "workflow" && args[1] === "show") return JSON.stringify({
        id: "incident-response",
        version: "1.0.0",
        title: "Incident response",
        agentRef: "scarf-support",
        goalRef: "restore-production",
      });
      if (args[0] === "workflow" && args[1] === "run") return JSON.stringify({ run: { id: "run-incident" } });
      return "";
    },
  });
  await lifecycle.prepareWorkflowRun("incident-response", {}, { runtimeAgentId: "scarf-support" });
  const create = calls.find((args) => args[0] === "workflow" && args[1] === "run");
  assert.equal(create[create.indexOf("--agent-ref") + 1], "scarf-support");
  assert.equal(create[create.indexOf("--goal-ref") + 1], "restore-production");
});

test("reconciles an active Org2 schedule into OpenClaw cron", async () => {
  const added = [];
  const cron = {
    list: async () => [],
    add: async (input) => {
      assert.equal(typeof input.payload.message, "string");
      assert.equal(input.payload.text, undefined);
      added.push(input);
      return { id: "job-1" };
    },
    update: async () => {},
    remove: async () => ({ removed: true }),
  };
  const lifecycle = newTestLifecycle({
    cron,
    exec: async (args) => {
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "list") return JSON.stringify({ workflows: [{
        id: "weekly-review", version: "1.0.0", title: "Weekly review", state: "active",
        model: "openai/gpt-5.6-sol", reasoningEffort: "high",
        triggers: [{ id: "schedule", type: "schedule", enabled: true, schedule: "0 9 * * 1", timezone: "America/Los_Angeles" }],
      }] });
      return "";
    },
    stateFile: join(await mkdtemp(join(tmpdir(), "org2-openclaw-cron-")), "state.json"),
  });
  await lifecycle.init();
  await lifecycle.reconcile();
  assert.equal(added.length, 1);
  assert.equal(added[0].schedule.expr, "0 9 * * 1");
  assert.equal(added[0].schedule.tz, "America/Los_Angeles");
  assert.equal(workflowMarker(added[0].payload.message).workflowId, "weekly-review");
  assert.equal(workflowMarker(added[0].payload.message).triggerId, "schedule");
  assert.equal(added[0].payload.model, "openai/gpt-5.6-sol");
  assert.equal(added[0].payload.thinking, "high");
  assert.match(added[0].payload.message, /ORG2_MODEL: openai\/gpt-5\.6-sol/);
  assert.match(added[0].payload.message, /ORG2_REASONING_EFFORT: high/);
});

test("continues to reconcile the legacy OpenClaw schedule trigger", async () => {
  const added = [];
  const cron = {
    list: async () => [],
    add: async (input) => { added.push(input); return { id: "job-legacy" }; },
    update: async () => {},
    remove: async () => ({ removed: true }),
  };
  const lifecycle = newTestLifecycle({
    cron,
    exec: async (args) => {
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "list") return JSON.stringify({ workflows: [{
        id: "legacy-review", version: "1.0.0", title: "Legacy review", state: "active",
        triggers: [{ id: "openclaw-schedule", type: "schedule", enabled: true, schedule: "0 */4 * * *" }],
      }] });
      return "";
    },
    stateFile: join(await mkdtemp(join(tmpdir(), "org2-openclaw-legacy-cron-")), "state.json"),
  });
  await lifecycle.init();
  await lifecycle.reconcile();
  assert.equal(added.length, 1);
  assert.equal(workflowMarker(added[0].payload.message).triggerId, "openclaw-schedule");
});

test("records an ineligible scheduled workflow attempt as skipped without creating a run", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-gate-"));
  const lifecycle = newTestLifecycle({
    stateFile: join(dir, "state.json"),
    exec: async (args) => {
      if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
      if (args[0] === "workflow" && args[1] === "run") {
        return JSON.stringify({
          schema: "org2:workflow-run-skipped:v1",
          workflowId: "weekly-review",
          triggerId: "openclaw-schedule",
          eligible: false,
          reason: "no matching event or fresh-work signal arrived after the previous attempt",
        });
      }
      if (args[0] === "workflow" && args[1] === "show") {
        return JSON.stringify({ id: "weekly-review", version: "1.0.0", title: "Weekly review" });
      }
      return "";
    },
  });
  await lifecycle.init();
  const result = await lifecycle.ensureWorkflow("cron:job:1", "weekly-review", {}, {
    triggerId: "openclaw-schedule",
    attemptId: "cron-job-1",
    logicalWorkId: "workflow:weekly-review",
  });
  assert.equal(result, null);
  const state = JSON.parse(await readFile(join(dir, "state.json"), "utf8"));
  assert.equal(state.mappings["cron:job:1"].outcome, "skipped");
  assert.match(state.mappings["cron:job:1"].skippedReason, /no matching event/);
});

test("finish reloads a mapping and records the required completion summary", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "running" });
    return "";
  } });
  await lifecycle.init();
  await writeFile(stateFile, JSON.stringify({ version: 1, mappings: { key: { org2RunId: "run-1" } } }));
  await lifecycle.finish("key", "ok", { summary: "Finished the requested work." });
  assert.deepEqual(calls.find((args) => args[1] === "complete"), [
    "run", "complete", "run-1", "--actor", "org2-lifecycle", "--summary", "Finished the requested work.",
  ]);
  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(state.version, 4);
  assert.equal(state.mappings.key.outcome, "ok");
});

test("a successful OpenClaw turn leaves approval and clarification boundaries open", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-approval-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "waiting-approval" });
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1" };
  const result = await lifecycle.finish("key", "ok", { summary: "Approval requested." });
  assert.deepEqual(result, { terminal: false, status: "waiting-approval" });
  assert.equal(calls.some((args) => args[1] === "complete"), false);
});

test("a successful OpenClaw turn leaves review-required artifacts open", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-artifact-review-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({
        id: "run-1",
        status: "running",
        artifacts: [{ id: "report", reviewStatus: "review-required" }],
      });
    }
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1" };
  const result = await lifecycle.finish("key", "ok", { summary: "Report produced for review." });
  assert.deepEqual(result, { terminal: false, status: "review-required" });
  assert.equal(calls.some((args) => args[1] === "complete"), false);
});

test("a replayed terminal event accepts an already-completed historical run", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-completed-review-"));
  const stateFile = join(dir, "state.json");
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({
        id: "run-1",
        status: "completed",
        artifacts: [{ id: "report", reviewStatus: "review-required" }],
      });
    }
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1" };
  const result = await lifecycle.finish("key", "ok", { summary: "Already completed." });
  assert.deepEqual(result, { terminal: true, status: "completed" });
});

test("session end fails active durable runs left without a terminal agent event", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-interrupted-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "running" });
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = {
    org2RunId: "run-1",
    sessionKey: "agent:main:subagent:child-1",
  };
  const interrupted = await lifecycle.interruptSession("agent:main:subagent:child-1", "idle");
  assert.equal(interrupted.length, 1);
  assert.deepEqual(calls.find((args) => args[1] === "fail"), [
    "run", "fail", "run-1", "--actor", "org2-lifecycle",
    "--reason", "OpenClaw session ended before its durable run reached a terminal state (reason: idle).",
  ]);
  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(state.mappings.key.outcome, "interrupted");
});

test("session end preserves deliberate approval and review pauses", async () => {
  const lifecycle = newTestLifecycle({ exec: async () => {
    throw new Error("paused mappings must not call Org2");
  } });
  lifecycle.state.mappings.approval = {
    org2RunId: "run-approval",
    sessionKey: "agent:main:subagent:child-1",
    pausedAt: "2026-07-27T12:00:00Z",
    pausedStatus: "waiting-approval",
  };
  assert.deepEqual(await lifecycle.interruptSession("agent:main:subagent:child-1", "idle"), []);
});

test("resumes an approved workflow in its correlated OpenClaw session", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-resume-"));
  const stateFile = join(dir, "state.json");
  const workflow = { id: "weekly-review", version: "1.0.0", title: "Weekly review" };
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify({ id: "run-1", status: "running", workflowId: workflow.id, approvals: [{ status: "approved" }] });
    if (args[0] === "workflow" && args[1] === "show") return JSON.stringify(workflow);
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = { org2RunId: "run-1", sessionKey: "agent:main:org2:thread-1", createdAt: "2026-07-18T10:00:00Z" };
  const resumed = await lifecycle.resumeWorkflowRun("run-1", { expectedCorpusId: "personal" });
  assert.equal(resumed.sessionKey, "agent:main:org2:thread-1");
  assert.equal(workflowMarker(resumed.prompt).workflowRunId, "run-1");
  assert.match(workflowContinuationPrompt(workflow, "run-1"), /approval-decided/);
  assert.match(approvedRunContinuationPrompt({ id: "run-1", goal: "Review drafts" }), /Skip every rejected or canceled action/);
});

test("resumes a correlated approved plain run only once per approval boundary", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-approved-run-"));
  const stateFile = join(dir, "state.json");
  const approval = {
    id: "send-report",
    fingerprint: "sha256:report-v1",
    status: "approved",
    decidedAt: "2026-08-06T16:05:00.000Z",
  };
  const run = {
    id: "run-plain-1",
    goal: "Send the approved report",
    status: "running",
    approvals: [approval],
    comments: [],
    events: [
      { type: "status-changed", data: { to: "waiting-approval" } },
      { type: "approval-requested", data: { approvalId: approval.id } },
    ],
  };
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify(run);
    throw new Error(`unexpected command: ${args.join(" ")}`);
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = {
    kind: "agent-turn",
    org2RunId: run.id,
    sessionKey: "agent:main:org2:thread-plain",
    pausedAt: "2026-08-06T16:00:00.000Z",
    pausedStatus: "waiting-approval",
    createdAt: "2026-08-06T15:00:00.000Z",
  };

  const first = await lifecycle.resumeApprovedRun(run.id, { expectedCorpusId: "personal" });
  const second = await lifecycle.resumeApprovedRun(run.id, { expectedCorpusId: "personal" });

  assert.equal(first.kind, "run");
  assert.equal(first.sessionKey, "agent:main:org2:thread-plain");
  assert.equal(first.alreadyResumed, false);
  assert.equal(second.alreadyResumed, true);
  assert.equal(second.continuationKey, first.continuationKey);
  assert.equal(second.prompt, first.prompt);
  assert.match(first.prompt, new RegExp(`ORG2_APPROVAL_CONTINUATION_KEY: ${first.continuationKey}$`));
  assert.equal(lifecycle.state.mappings.key.pausedAt, undefined);
  assert.equal(lifecycle.state.mappings.key.pausedStatus, undefined);
  assert.equal(durableRunMarker(first.prompt), run.id);
  assert.match(approvedRunContinuationPrompt(run), /request the same approval again/);
  const saved = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(Object.keys(saved.approvalContinuations).length, 1);
});

test("does not resume a run whose current approval boundary is incomplete", async () => {
  const run = {
    id: "run-pending",
    goal: "Wait for both reviewers",
    status: "running",
    approvals: [{ id: "review-1", status: "approved" }, { id: "review-2", status: "pending" }],
    events: [],
  };
  const lifecycle = newTestLifecycle({ exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify(run);
    throw new Error(`unexpected command: ${args.join(" ")}`);
  } });
  await assert.rejects(() => lifecycle.resumeApprovedRun(run.id), /not fully decided/);
});

test("resumes a fully decided boundary while preserving rejected actions", async () => {
  const run = {
    id: "run-partial-batch",
    goal: "Process independently reviewed drafts",
    status: "running",
    approvals: [{ id: "review-1", status: "approved" }, { id: "review-2", status: "rejected" }],
    comments: [],
    events: [],
  };
  const lifecycle = newTestLifecycle({ exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify(run);
    throw new Error(`unexpected command: ${args.join(" ")}`);
  } });

  const resumed = await lifecycle.resumeApprovedRun(run.id);

  assert.match(resumed.prompt, /Skip every rejected or canceled action/);
});

test("resumes a requested workflow revision with the reviewer's durable feedback", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-revision-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  const workflow = { id: "weekly-review", version: "1.0.0", title: "Weekly review" };
  const approval = {
    id: "review-copy",
    status: "revised",
    decisionNote: "Lead with the recommendation and remove the internal acronym.",
  };
  const run = {
    id: "run-1",
    status: "blocked",
    workflowId: workflow.id,
    approvals: [approval],
    events: [
      { type: "status-changed", data: { to: "waiting-approval" } },
      { type: "approval-requested", data: { approvalId: approval.id } },
    ],
  };
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "personal" } });
    if (args[0] === "run" && args[1] === "show") return JSON.stringify(run);
    if (args[0] === "run" && args[1] === "resume") return JSON.stringify({ ...run, status: "running" });
    if (args[0] === "workflow" && args[1] === "show") return JSON.stringify(workflow);
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.key = {
    org2RunId: run.id,
    sessionKey: "agent:main:org2:thread-1",
    createdAt: "2026-07-18T10:00:00Z",
  };

  const resumed = await lifecycle.resumeWorkflowRevision(run.id, approval.id, { expectedCorpusId: "personal" });

  assert.equal(resumed.sessionKey, "agent:main:org2:thread-1");
  assert.equal(workflowMarker(resumed.prompt).workflowRunId, run.id);
  assert.match(resumed.prompt, /Lead with the recommendation/);
  assert.match(resumed.prompt, /request a replacement approval/);
  assert.match(resumed.prompt, /Request the replacement on ORG2_WORKFLOW_RUN_ID/);
  assert.match(resumed.prompt, /Provider draft: PROVIDER:TOOL:DRAFT_ID/);
  assert.match(resumed.prompt, /revision request is not approval/i);
  assert.deepEqual(
    calls.find((args) => args[0] === "run" && args[1] === "resume"),
    ["run", "resume", run.id, "--actor", "org2-lifecycle", "--json"],
  );
  assert.match(workflowRevisionPrompt(workflow, run.id, approval), /revision-requested/);
});

test("rejects a Mac workflow request for a different configured corpus", async () => {
  const lifecycle = newTestLifecycle({ exec: async (args) => {
    if (args[0] === "corpus") return JSON.stringify({ identity: { id: "team" } });
    return "";
  } });
  await assert.rejects(
    lifecycle.prepareWorkflowRun("weekly-review", {}, { expectedCorpusId: "personal" }),
    /corpus mismatch/,
  );
});

test("does not recognize ClawLink operations", () => {
  const params = {
    tool: "gmail_create_draft",
    connectionId: 7,
    arguments: { to: "person@example.com", subject: "Short update", body: "Hello" },
  };
  const result = { content: [{ type: "text", text: JSON.stringify({ result: { draftId: "draft-42" } }) }] };
  assert.equal(draftCreatedEffect("clawlink_call_tool", params, result), null);
  assert.equal(draftSendEffect("clawlink_call_tool", {
    tool: "gmail_send_draft",
    connectionId: 7,
    arguments: { draftId: "draft-42" },
  }), null);
});

test("recognizes gog Gmail draft commands", () => {
  const created = draftCreatedEffect("exec", {
    command: "gog gmail drafts create --account avi@example.com --to person@example.com --subject Update --body Hello",
  }, JSON.stringify({ draftId: "gog-1" }));
  assert.equal(created.draftId, "gog-1");
  assert.equal(draftSendEffect("exec", { command: "gog gmail drafts send gog-1" }).draftId, "gog-1");
  const wrapped = draftCreatedEffect("exec", {
    source: `const result = await tools.exec_command({cmd: "gog gmail drafts create --account avi@example.com --to person@example.com --subject 'Readable update' --body 'Hello there'"});`,
  }, `Script completed\nOutput:\n${JSON.stringify({ draftId: "gog-wrapped-1" })}`);
  assert.equal(wrapped.draftId, "gog-wrapped-1");
  assert.equal(wrapped.account, "avi@example.com");
  assert.equal(wrapped.destination, "person@example.com");
  assert.equal(wrapped.subject, "Readable update");
  assert.equal(wrapped.body, "Hello there");
  assert.match(approvalAction(wrapped), /To: person@example\.com\nCc: \(none\)\nBcc: \(none\)\nSubject: Readable update[\s\S]*Hello there/);
  assert.equal(
    approvalAction({ ...wrapped, body: "Hello there\r\n" }),
    approvalAction({ ...wrapped, body: "Hello there" }),
  );
  assert.equal(draftSendEffect("exec", {
    source: `await tools.exec_command({cmd: "gog gmail drafts send gog-wrapped-1"});`,
  }).draftId, "gog-wrapped-1");
});

test("recognizes verified safe-wrapper drafts for the normal Gmail approval path", () => {
  const effect = draftCreatedEffect("exec", {
    command: "node /Users/avi/dev/org2/integrations/openclaw/bin/gmail-draft-safe.mjs create --account avi@scarf.sh --to pat@example.com --subject 'Fluid follow-up' --body-file /tmp/body.txt",
  }, JSON.stringify({
    draftId: "safe-draft-1",
    verified: true,
    hasPlainTextFallback: true,
    hasHtmlBody: true,
    hardWrapCheck: "passed",
  }));
  assert.equal(effect.provider, "gmail:gog");
  assert.equal(effect.account, "avi@scarf.sh");
  assert.equal(effect.draftId, "safe-draft-1");
  assert.equal(effect.destination, "pat@example.com");
  assert.equal(effect.subject, "Fluid follow-up");
  assert.equal(draftCreatedEffect("exec", {
    command: "node /Users/avi/dev/org2/integrations/openclaw/bin/gmail-draft-safe.mjs create --account avi@scarf.sh --to pat@example.com --subject 'Fluid follow-up' --body-file /tmp/body.txt",
  }, JSON.stringify({
    draftId: "unsafe-draft-1",
    verified: false,
    hasPlainTextFallback: true,
    hasHtmlBody: true,
    hardWrapCheck: "passed",
  })), null);
});

test("does not turn unrelated shell output into draft approvals", () => {
  const githubCommand = "gh api graphql --field query='mutation CreateDraft { createDiscussion(input: {}) { discussion { id } } }'";
  const githubResult = JSON.stringify({ data: { createDiscussion: { discussion: { id: "MDQ6VXNlcjEzODgwNzE=" } } } });
  assert.equal(draftCreatedEffect("exec", { command: githubCommand }, githubResult), null);
  assert.equal(draftSendEffect("exec", { command: "node send-draft-report.mjs" }), null);
});

test("requests an Org2 approval for a draft and gates sending on its decision", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-draft-"));
  const stateFile = join(dir, "state.json");
  const calls = [];
  let approvalStatus = "pending";
  const lifecycle = newTestLifecycle({ owner: "avi", stateFile, exec: async (args) => {
    calls.push(args);
    if (args[0] === "run" && args[1] === "create") {
      return JSON.stringify({ run: { id: "draft-run-1" } });
    }
    if (args[0] === "run" && args[1] === "approval-request") {
      return JSON.stringify({ approvals: [{ id: "approval-1", status: "pending" }] });
    }
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({
        id: "run-1",
        status: approvalStatus === "approved" ? "running" : "waiting-approval",
        approvals: [{ id: "approval-1", status: approvalStatus, action: "Send update" }],
      });
    }
    if (args[0] === "review") return JSON.stringify({ reviews: [] });
    return "";
  } });
  await lifecycle.init();
  lifecycle.state.mappings.turn = { org2RunId: "run-1", openclawRunId: "openclaw-1", createdAt: "2026-07-19T00:00:00Z" };
  const effect = {
    key: "gmail:default:draft-1", provider: "gmail", account: "default", draftId: "draft-1",
    destination: "person@example.com", subject: "Update", fingerprint: "abc", title: "Approve update", action: "Send update",
    context: approvalContext({ provider: "gmail", draftId: "draft-1", destination: "person@example.com" }),
  };
  const record = await lifecycle.requestDraftApproval(effect, { openclawRunId: "openclaw-1" });
  assert.equal(record.org2RunId, "draft-run-1");
  assert.ok(calls.some((args) => args[0] === "run" && args[1] === "create"));
  assert.ok(calls.some((args) => args[0] === "run" && args[1] === "create" && args.includes("entity:email:person@example.com")));
  assert.ok(calls.some((args) => args[0] === "run" && args[1] === "approval-request" && args[2] === "draft-run-1"));
  assert.equal(record.approvalId, "approval-1");
  assert.equal((await lifecycle.draftSendDecision({ key: effect.key, draftId: effect.draftId, action: effect.action })).allowed, false);
  approvalStatus = "approved";
  assert.equal((await lifecycle.draftSendDecision({ key: effect.key, draftId: effect.draftId, action: effect.action })).allowed, true);
  assert.ok(calls.some((args) => args[1] === "approval-request" && args.includes("external-action")));
  assert.ok(calls.some((args) => args[1] === "approval-request" && args.includes("--role") && args.includes("owner")));
  assert.ok(calls.some((args) => args[1] === "approval-request" && args.includes("--note") && args.includes("Send update")));
});

test("reloads draft approvals written by another plugin process before sending", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-shared-draft-"));
  const stateFile = join(dir, "state.json");
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({ id: "run-1", status: "running", approvals: [{ id: "approval-1", status: "approved", action: "Send shared draft" }] });
    }
    return "";
  } });
  await lifecycle.init();

  await writeFile(stateFile, JSON.stringify({
    version: 4,
    mappings: {},
    workflowJobs: {},
    drafts: {
      "gmail:gog:default:draft-shared": {
        key: "gmail:gog:default:draft-shared",
        draftId: "draft-shared",
        org2RunId: "run-1",
        approvalId: "approval-1",
      },
    },
  }));

  const decision = await lifecycle.draftSendDecision({
    key: "gmail:gog:default:draft-shared",
    draftId: "draft-shared",
    action: "Send shared draft",
  });
  assert.equal(decision.allowed, true);
  assert.equal(decision.record.approvalId, "approval-1");
});

test("reconciles an approved replacement for a canceled malformed draft approval", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-replaced-draft-"));
  const stateFile = join(dir, "state.json");
  const exactAction = [
    "To: person@example.com",
    "Cc: (none)",
    "Bcc: (none)",
    "Subject: Readable update",
    "",
    "Body:",
    "Hello there",
    "",
    "Provider draft: gmail:gog:draft-replaced",
  ].join("\n");
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "run" && args[1] === "show") {
      return JSON.stringify({
        id: "run-1",
        approvals: [
          { id: "approval-old", status: "canceled", action: exactAction.replace(/\n/g, "\\n") },
          { id: "approval-new", status: "approved", action: exactAction },
        ],
      });
    }
    if (args[0] === "review") return JSON.stringify({ reviews: [] });
    return "";
  } });
  await lifecycle.init();
  await writeFile(stateFile, JSON.stringify({
    version: 4,
    mappings: {},
    workflowJobs: {},
    drafts: {
      "gmail:gog:default:draft-replaced": {
        key: "gmail:gog:default:draft-replaced",
        provider: "gmail:gog",
        draftId: "draft-replaced",
        org2RunId: "run-1",
        approvalId: "approval-old",
      },
    },
  }));

  const decision = await lifecycle.draftSendDecision({
    key: "gmail:gog:avi@example.com:draft-replaced",
    provider: "gmail:gog",
    account: "avi@example.com",
    draftId: "draft-replaced",
    action: `${exactAction}\nContent fingerprint: current`,
  });

  assert.equal(decision.allowed, true);
  assert.equal(decision.record.approvalId, "approval-new");
  const state = JSON.parse(await readFile(stateFile, "utf8"));
  assert.equal(state.drafts["gmail:gog:avi@example.com:draft-replaced"].approvalId, "approval-new");
});

test("reconciles a missing local draft record from the canonical Org2 review registry", async () => {
  const dir = await mkdtemp(join(tmpdir(), "org2-openclaw-review-registry-"));
  const stateFile = join(dir, "state.json");
  const action = "Send exact canonical draft";
  const lifecycle = newTestLifecycle({ stateFile, exec: async (args) => {
    if (args[0] === "review") {
      return JSON.stringify({
        reviews: [{
          kind: "approval",
          runId: "run-canonical",
          id: "approval-canonical",
          status: "approved",
          action,
        }],
      });
    }
    return "";
  } });
  await lifecycle.init();

  const decision = await lifecycle.draftSendDecision({
    key: "gmail:gog:avi@example.com:draft-canonical",
    provider: "gmail:gog",
    account: "avi@example.com",
    draftId: "draft-canonical",
    action,
  });

  assert.equal(decision.allowed, true);
  assert.equal(decision.record.org2RunId, "run-canonical");
  assert.equal(decision.record.approvalId, "approval-canonical");
});

test("fails closed when the canonical approval does not match the live draft", async () => {
  const lifecycle = newTestLifecycle({ exec: async (args) => {
    if (args[0] === "review") {
      return JSON.stringify({
        reviews: [{
          kind: "approval",
          runId: "run-other",
          id: "approval-other",
          status: "approved",
          action: "Different content",
        }],
      });
    }
    return "";
  } });

  const decision = await lifecycle.draftSendDecision({
    key: "gmail:gog:avi@example.com:draft-mismatch",
    provider: "gmail:gog",
    account: "avi@example.com",
    draftId: "draft-mismatch",
    action: "Current live content",
  });

  assert.equal(decision.allowed, false);
  assert.match(decision.reason, /No matching Celorga approval/);
});

test("waits for a replicated run copy to catch up before continuing", async () => {
  // The app recorded an approval on another machine; this host's copy arrives later.
  const copies = [
    { id: "run-sync-1", status: "waiting-approval", updatedAt: "2026-08-06T16:00:00.000Z" },
    { id: "run-sync-1", status: "waiting-approval", updatedAt: "2026-08-06T16:00:00.000Z" },
    { id: "run-sync-1", status: "blocked", updatedAt: "2026-08-06T16:05:01.000Z" },
  ];
  let reads = 0;
  const sleeps = [];
  const lifecycle = newTestLifecycle({
    syncPollMs: 5,
    sleep: async (ms) => { sleeps.push(ms); },
    exec: async (args) => {
      if (args[0] === "run" && args[1] === "show") return JSON.stringify(copies[Math.min(reads++, copies.length - 1)]);
      throw new Error(`unexpected command: ${args.join(" ")}`);
    },
  });

  const run = await lifecycle.awaitRunSync("run-sync-1", { expectedUpdatedAt: "2026-08-06T16:05:00.000Z" });
  assert.equal(run.status, "blocked");
  assert.equal(reads, 3);
  assert.deepEqual(sleeps, [5, 5]);
});

test("reports an unsynced run copy instead of a misleading status error", async () => {
  const stale = { id: "run-sync-2", status: "waiting-approval", updatedAt: "2026-08-06T16:00:00.000Z" };
  const lifecycle = newTestLifecycle({
    syncWaitSeconds: 0,
    sleep: async () => {},
    exec: async (args) => {
      if (args[0] === "run" && args[1] === "show") return JSON.stringify(stale);
      throw new Error(`unexpected command: ${args.join(" ")}`);
    },
  });

  await assert.rejects(
    () => lifecycle.awaitRunSync(stale.id, { expectedUpdatedAt: "2026-08-06T16:05:00.000Z" }),
    /has not synced to the OpenClaw host yet: its copy here is waiting-approval/,
  );
});

test("does not wait for sync when the app sends no expectation", async () => {
  let reads = 0;
  const lifecycle = newTestLifecycle({
    exec: async () => { reads += 1; return "{}"; },
  });
  assert.equal(await lifecycle.awaitRunSync("run-sync-3", {}), undefined);
  assert.equal(reads, 0);
});
