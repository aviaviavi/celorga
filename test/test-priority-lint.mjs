import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { lintPriorityCookies, parsePriorityConfig } from '../dist/priorityLint.js';
import { buildPublishDiagnosticsParams } from '../dist/lsp-diagnostics.js';

const rules = (issues) => issues.map((issue) => [issue.line, issue.rule]);

// Default range is A–C.
const defaults = [
  '* TODO [#A] Fine',
  '* [#B] Fine without keyword',
  '* TODO [#D] Too low',
  '* WAIT [#Z] Unknown keyword is title text',
  '* TODO [#-1] Negative',
  '* TODO [#AA] Two letters',
  '* TODO [#A Missing bracket',
  '* TODO [#a] Lowercase',
  '* Title mentions [#D] later',
  '#+begin_src org',
  '* TODO [#Q] Inside a block',
  '#+end_src',
  '* TODO [#5] Number in letter range',
  '* COMMENT TODO [#Q] Commented metadata is title text',
  '* TODO [#] Empty',
  '',
].join('\n');
const issues = lintPriorityCookies(defaults);
assert.deepEqual(rules(issues), [
  [3, 'priority-out-of-range'],
  [5, 'priority-cookie-invalid'],
  [6, 'priority-cookie-invalid'],
  [7, 'priority-cookie-malformed'],
  [8, 'priority-out-of-range'],
  [13, 'priority-out-of-range'],
  [15, 'priority-cookie-invalid'],
]);
assert.equal(issues[0].column, 8);
assert.equal(issues[0].endColumn, 12);
assert.match(issues[0].message, /\[#D\] is outside A–C \(the default range\)/);
assert.match(issues[3].message, /'\[#A' is not closed/);
assert.match(issues[4].message, /did you mean \[#A\]/);

// A file range applies to every cookie; custom TODO keywords are recognized.
const custom = [
  '#+PRIORITIES: A E C',
  '#+TODO: WAIT | DONE',
  '* WAIT [#E] In range',
  '* WAIT [#F] Out of range',
  '',
].join('\n');
assert.deepEqual(parsePriorityConfig(custom).config, { kind: 'letter', highest: 'A', lowest: 'E', default: 'C', line: 1 });
const customIssues = lintPriorityCookies(custom);
assert.deepEqual(rules(customIssues), [[4, 'priority-out-of-range']]);
assert.match(customIssues[0].message, /outside A–E \(#\+PRIORITIES on line 1\)/);

// Numeric ranges.
assert.deepEqual(rules(lintPriorityCookies('#+PRIORITIES: 1 5 3\n* TODO [#4] ok\n* TODO [#7] high\n* TODO [#B] letter\n')), [
  [3, 'priority-out-of-range'],
  [4, 'priority-out-of-range'],
]);

// Invalid configuration falls back to A–C and is reported.
for (const bad of ['#+PRIORITIES: C A B', '#+PRIORITIES: A C', '#+PRIORITIES: A C D', '#+PRIORITIES: A 3 B']) {
  const result = lintPriorityCookies(`${bad}\n* TODO [#C] Still fine\n`);
  assert.deepEqual(rules(result), [[1, 'priority-config-invalid']], bad);
}

// The shared LSP diagnostics path reports the same issues as warnings.
const lsp = buildPublishDiagnosticsParams('file:///synthetic/notes.org', '* TODO [#D] Too low\n* TODO [#AA] Wrong\n');
const priorityDiagnostics = lsp.diagnostics.filter((diagnostic) => String(diagnostic.code).startsWith('org2-priority'));
assert.deepEqual(priorityDiagnostics.map((diagnostic) => [diagnostic.range.start.line, diagnostic.range.start.character, diagnostic.range.end.character, diagnostic.severity, diagnostic.code]), [
  [0, 7, 11, 2, 'org2-priority-out-of-range'],
  [1, 7, 12, 2, 'org2-priority-cookie-invalid'],
]);

// And `celorga lint` reports them across a directory.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'celorga-priority-lint-'));
try {
  fs.writeFileSync(path.join(dir, 'tasks.org'), '* TODO [#A] Fine\n* TODO [#A Broken\n* TODO [#X] Out\n');
  const lint = JSON.parse(execFileSync(process.execPath, ['dist/cli.js', 'lint', '--dir', dir, '--format', 'json'], { encoding: 'utf8' }));
  const priority = lint.issues.filter((issue) => issue.rule.startsWith('priority-'));
  assert.deepEqual(priority.map((issue) => [path.basename(issue.file), issue.line, issue.rule, issue.severity]), [
    ['tasks.org', 2, 'priority-cookie-malformed', 'warning'],
    ['tasks.org', 3, 'priority-out-of-range', 'warning'],
  ]);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}

console.log('✓ priority lint');
