import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { datetreeHierarchy, fileEntryInDatetree, findOrCreateDatetree, isoWeekOf, parseDatetreeLevels } from '../dist/datetree.js';

const d = (iso) => { const [year, month, day] = iso.split('-').map(Number); return { year, month, day }; };
const titles = (iso, levels) => datetreeHierarchy(d(iso), parseDatetreeLevels(levels)).map((heading) => heading.title);

// Level parsing: canonical order, dedupe, validation.
assert.deepEqual(parseDatetreeLevels('day, year,month,day'), ['year', 'month', 'day']);
assert.throws(() => parseDatetreeLevels(''), /at least one/);
assert.throws(() => parseDatetreeLevels('year,fortnight'), /unknown datetree level\(s\): fortnight/);

// ISO weeks, including week 53 and year boundaries.
assert.deepEqual([isoWeekOf(d('2026-12-31')).isoYear, isoWeekOf(d('2026-12-31')).week], [2026, 53]);
assert.deepEqual([isoWeekOf(d('2027-01-03')).isoYear, isoWeekOf(d('2027-01-03')).week], [2026, 53]);
assert.deepEqual([isoWeekOf(d('2027-01-04')).isoYear, isoWeekOf(d('2027-01-04')).week], [2027, 1]);
assert.deepEqual([isoWeekOf(d('2024-12-30')).isoYear, isoWeekOf(d('2024-12-30')).week], [2025, 1]);
assert.deepEqual([isoWeekOf(d('2021-01-01')).isoYear, isoWeekOf(d('2021-01-01')).week], [2020, 53]);

// Classic year/month/day and the month tree.
assert.deepEqual(titles('2026-10-26', 'year,month,day'), ['2026', '2026-10 October', '2026-10-26 Monday']);
assert.deepEqual(titles('2026-10-26', 'year,month'), ['2026', '2026-10 October']);
// Quarters are 3-month periods without weeks.
assert.deepEqual(titles('2026-10-26', 'year,quarter,month,day'), ['2026', '2026-Q4', '2026-10 October', '2026-10-26 Monday']);
// Week trees use the ISO year; the day heading keeps the real date.
assert.deepEqual(titles('2027-01-01', 'year,week,day'), ['2026', '2026-W53', '2027-01-01 Friday']);
assert.deepEqual(titles('2024-12-30', 'year,week,day'), ['2025', '2025-W01', '2024-12-30 Monday']);
// With month and week, a week belongs to the month containing its Thursday.
assert.deepEqual(titles('2027-01-01', 'year,month,week,day'), ['2026', '2026-12 December', '2026-W53', '2027-01-01 Friday']);
assert.deepEqual(titles('2026-03-30', 'year,month,week'), ['2026', '2026-04 April', '2026-W14']);
// Quarters are 13-week periods with week but no month; week 53 stays in Q4.
assert.deepEqual(titles('2026-03-30', 'year,quarter,week'), ['2026', '2026-Q2', '2026-W14']);
assert.deepEqual(titles('2026-03-29', 'year,quarter,week'), ['2026', '2026-Q1', '2026-W13']);
assert.deepEqual(titles('2026-12-31', 'year,quarter,week'), ['2026', '2026-Q4', '2026-W53']);
// But with month present, the quarter follows the (Thursday) month.
assert.deepEqual(titles('2026-03-30', 'year,quarter,month,week'), ['2026', '2026-Q2', '2026-04 April', '2026-W14']);
// Any subset works, including a lone day level.
assert.deepEqual(titles('2026-10-26', 'day'), ['2026-10-26 Monday']);

// Find-or-create keeps siblings ordered and ignores unrelated headings and blocks.
const existing = [
  '#+title: Journal',
  '',
  '* Inbox',
  '* 2025',
  '** 2025-12 December',
  '* 2026',
  '** 2026-09 September',
  '*** 2026-09-01 Tuesday',
  '** Ideas',
  '#+begin_src org',
  '** 2026-10 October',
  '#+end_src',
  '** 2026-11 November',
  '*** 2026-11-02 Monday',
  '* 2028',
];
const located = findOrCreateDatetree(existing, d('2026-10-26'), parseDatetreeLevels('year,month,day'));
assert.deepEqual(located.created, ['2026-10 October', '2026-10-26 Monday']);
assert.deepEqual(located.lines.slice(5, 16), [
  '* 2026',
  '** 2026-09 September',
  '*** 2026-09-01 Tuesday',
  '** Ideas',
  '#+begin_src org',
  '** 2026-10 October',
  '#+end_src',
  '** 2026-10 October',
  '*** 2026-10-26 Monday',
  '** 2026-11 November',
  '*** 2026-11-02 Monday',
]);
assert.equal(located.headingIndex, 13);
assert.equal(located.depth, 3);

const newYear = findOrCreateDatetree(existing, d('2027-01-01'), parseDatetreeLevels('year,week,day'));
assert.deepEqual(newYear.created, ['2026-W53', '2027-01-01 Friday'], 'ISO year 2026 reuses the existing 2026 heading');
const between = findOrCreateDatetree(existing, d('2027-06-01'), parseDatetreeLevels('year'));
assert.deepEqual(between.created, ['2027']);
assert.equal(between.lines[between.headingIndex + 1], '* 2028', '2027 is inserted before 2028');

// Filing is deterministic and idempotent for the hierarchy.
const entry = '* Standup\nCAPTURED: <2026-10-26 Mon 09:00>\n\nNotes\n';
const first = fileEntryInDatetree('', entry, d('2026-10-26'), parseDatetreeLevels('year,month,day'));
assert.equal(first.text, '* 2026\n** 2026-10 October\n*** 2026-10-26 Monday\n**** Standup\nCAPTURED: <2026-10-26 Mon 09:00>\n\nNotes\n');
assert.equal(first.entryLine1, 4);
const second = fileEntryInDatetree(first.text, entry.replace('Standup', 'Review'), d('2026-10-26'), parseDatetreeLevels('year,month,day'));
assert.deepEqual(second.created, []);
assert.equal(second.text, `${first.text}\n**** Review\nCAPTURED: <2026-10-26 Mon 09:00>\n\nNotes\n`);
assert.equal(second.entryLine1, 9);
const nested = fileEntryInDatetree('', '* Parent\n** Child\n#+begin_example\n* not a heading\n#+end_example\n', d('2026-10-26'), parseDatetreeLevels('year,week'));
assert.equal(nested.text, '* 2026\n** 2026-W44\n*** Parent\n**** Child\n#+begin_example\n* not a heading\n#+end_example\n');

// CLI: preview, then apply into a datetree.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'celorga-datetree-'));
try {
  const file = path.join(dir, 'journal.org');
  fs.writeFileSync(file, '#+title: Journal\n\n* 2026\n** 2026-10 October\n*** 2026-10-27 Tuesday\nLater.\n');
  const args = ['dist/cli.js', 'capture', '--file', file, '--title', 'Standup', '--body', 'Notes', '--datetree', 'year,month,day', '--now', '2026-10-26T09:00:00'];
  const preview = JSON.parse(execFileSync(process.execPath, [...args, '--format', 'json'], { encoding: 'utf8' }));
  assert.deepEqual(preview.datetree, {
    levels: ['year', 'month', 'day'],
    date: '2026-10-26',
    path: ['2026', '2026-10 October', '2026-10-26 Monday'],
    created: ['2026-10-26 Monday'],
    headingLine1: 5,
  });
  assert.equal(preview.headingLine1, 6);
  assert.equal(fs.readFileSync(file, 'utf8').includes('Standup'), false, 'preview does not write');
  execFileSync(process.execPath, [...args, '--apply'], { encoding: 'utf8' });
  assert.equal(fs.readFileSync(file, 'utf8'), '#+title: Journal\n\n* 2026\n** 2026-10 October\n*** 2026-10-26 Monday\n**** Standup\nCAPTURED: <2026-10-26 Mon 09:00>\n\nNotes\n\n*** 2026-10-27 Tuesday\nLater.\n');

  let failed = false;
  try {
    execFileSync(process.execPath, ['dist/cli.js', 'capture', '--file', file, '--title', 'X', '--datetree', 'decade'], { encoding: 'utf8', stdio: 'pipe' });
  } catch (error) {
    failed = true;
    assert.match(String(error.stderr), /invalid --datetree: unknown datetree level\(s\): decade/);
  }
  assert.ok(failed, 'unknown levels are rejected');
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}

console.log('✓ datetree');
