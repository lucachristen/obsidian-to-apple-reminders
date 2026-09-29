import assert from 'node:assert/strict';
import { test } from 'node:test';
import { completion, DEFAULT_QUERY, taskId, toggledLines, withId, withoutMarker } from '../src/model';

const id = '11111111-1111-4111-a111-111111111111';
test('stable IDs preserve indentation, dates and terminal block references', () => {
  const line = '  - [ ] Test 📅 2026-10-01 ^my-task';
  const tagged = withId(line, id);
  assert.equal(taskId(tagged), id);
  assert.equal(tagged.endsWith('^my-task'), true);
  assert.equal(withoutMarker(tagged), line);
  assert.equal(withId(tagged, id), tagged);
});
test('completion accepts standard and uppercase completed checkboxes', () => {
  assert.equal(completion('- [ ] Pending'), false);
  assert.equal(completion('  * [x] Done'), true);
  assert.equal(completion('1. [X] Done'), true);
  assert.throws(() => completion('- [/] Doing'), /standard/);
  assert.throws(() => completion('not a task'), /standard/);
});
test('recurring completion keeps identity only on completed instance', () => {
  const result = toggledLines(`- [ ] Repeat 🔁 every day <!-- reminders:${id} -->\n- [x] Repeat 🔁 every day <!-- reminders:${id} --> ✅ 2026-09-29`, id, true);
  const [next, done] = result.split('\n');
  assert.equal(taskId(next), undefined);
  assert.equal(taskId(done), id);
  assert.match(done, /✅ 2026-09-29/);
});
test('recurring completion also supports completed-first user ordering', () => {
  const result = toggledLines('- [x] Done\n- [ ] Next', id, true).split('\n');
  assert.equal(taskId(result[0]), id);
  assert.equal(taskId(result[1]), undefined);
});
test('reopening preserves identity and rejects invalid status cycles', () => {
  assert.equal(taskId(toggledLines('- [ ] Reopened', id, false)), id);
  assert.throws(() => toggledLines('- [ ] Not completed', id, true), /requested/);
});
test('default query matches requested function, horizon, paths and sorting', () => {
  assert.equal(DEFAULT_QUERY, `not done
filter by function ['project', 'area', 'person'].includes(task.file.property('type'))
(due before in 15 days) OR (scheduled before in 15 days)
path does not include _ meta/templates
path does not include 9 Archive
sort by due
sort by scheduled
sort by priority`);
});
