import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { cancelRepeatersInText, stripTimestampRepeaters } from '../dist/planning.js';

assert.deepEqual(stripTimestampRepeaters('2026-05-20 Wed 09:00 .+2d/4d -1d'), { body: '2026-05-20 Wed 09:00 -1d', removed: ['.+2d/4d'] });
assert.deepEqual(stripTimestampRepeaters('2026-05-20 Wed'), { body: '2026-05-20 Wed', removed: [] });

const source = [
  '* Before',
  'SCHEDULED: <2026-05-01 Fri +1d>',
  '* TODO Water plants <2026-05-19 Tue +1m>',
  'SCHEDULED: <2026-05-20 Wed ++1w> DEADLINE: <2026-05-22 Fri 10:00 .+1m -2d>',
  ':PROPERTIES:',
  ':STYLE: habit',
  ':END:',
  'Habit window <2026-05-23 Sat .+2d/4d> and inactive [2026-05-24 Sun +1w] stays.',
  'Range <2026-05-25 Mon +1w>--<2026-05-26 Tue +1w>.',
  '#+begin_src org',
  'SCHEDULED: <2026-06-01 Mon +1d>',
  '#+end_src',
  '** Child entry',
  'SCHEDULED: <2026-05-27 Wed +1w>',
  '',
].join('\n');

const res = cancelRepeatersInText(source, { filePath: 'synthetic.org', lineNumber: 6 });
assert.equal(res.headingLineNumber, 3);
assert.equal(res.changed, true);
assert.deepEqual(res.cancelled.map((item) => [item.line, item.repeater]), [
  [3, '+1m'],
  [4, '++1w'],
  [4, '.+1m'],
  [8, '.+2d/4d'],
  [9, '+1w'],
  [9, '+1w'],
]);
const out = res.text.split('\n');
assert.equal(out[1], 'SCHEDULED: <2026-05-01 Fri +1d>', 'previous entry untouched');
assert.equal(out[2], '* TODO Water plants <2026-05-19 Tue>');
assert.equal(out[3], 'SCHEDULED: <2026-05-20 Wed> DEADLINE: <2026-05-22 Fri 10:00 -2d>', 'warning delay kept');
assert.equal(out[7], 'Habit window <2026-05-23 Sat> and inactive [2026-05-24 Sun +1w] stays.');
assert.equal(out[8], 'Range <2026-05-25 Mon>--<2026-05-26 Tue>.');
assert.equal(out[10], 'SCHEDULED: <2026-06-01 Mon +1d>', 'literal blocks untouched');
assert.equal(out[13], 'SCHEDULED: <2026-05-27 Wed +1w>', 'child entries untouched');

const noop = cancelRepeatersInText(res.text, { filePath: 'synthetic.org', lineNumber: 3 });
assert.equal(noop.changed, false);
assert.equal(noop.text, res.text);

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'celorga-cancel-repeaters-'));
try {
  const file = path.join(dir, 'tasks.org');
  fs.writeFileSync(file, source);
  const preview = JSON.parse(execFileSync(process.execPath, ['dist/cli.js', 'plan', 'cancel-repeaters', '--file', file, '--pos', '4'], { encoding: 'utf8' }));
  assert.equal(preview.action, 'cancel-repeaters');
  assert.equal(preview.applied, false);
  assert.equal(preview.cancelled.length, 6);
  assert.equal(fs.readFileSync(file, 'utf8'), source, 'preview does not write');

  const diff = execFileSync(process.execPath, ['dist/cli.js', 'plan', 'cancel-repeaters', '--file', file, '--pos', '4', '--format', 'diff'], { encoding: 'utf8' });
  assert.match(diff, /^-SCHEDULED: <2026-05-20 Wed \+\+1w>/m);
  assert.match(diff, /^\+SCHEDULED: <2026-05-20 Wed> DEADLINE/m);

  execFileSync(process.execPath, ['dist/cli.js', 'plan', 'cancel-repeaters', '--file', file, '--pos', '4', '--apply'], { encoding: 'utf8' });
  assert.equal(fs.readFileSync(file, 'utf8'), res.text);
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}

console.log('✓ plan cancel-repeaters');
