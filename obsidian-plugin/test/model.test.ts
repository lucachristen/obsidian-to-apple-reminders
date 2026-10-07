import assert from 'node:assert/strict';
import { test } from 'node:test';
import { completion, DEFAULT_QUERY, taskId, toggledTask, withoutMarker } from '../src/model';

const id = '11111111-1111-4111-a111-111111111111';
test('legacy marker removal preserves indentation, dates and terminal block references', () => {
  const tagged = `  - [ ] <!-- reminders:${id} --> Test 📅 2026-10-01 ^my-task`;
  assert.equal(taskId(tagged), id);
  assert.equal(withoutMarker(tagged), '  - [ ] Test 📅 2026-10-01 ^my-task');
});
test('old trailing identity markers are removed without changing task metadata', () => {
  const old = `- [ ] Repeat 🔁 every day 📅 2026-10-01 <!-- reminders:${id} -->`;
  assert.equal(withoutMarker(old), '- [ ] Repeat 🔁 every day 📅 2026-10-01');
});
test('multiple legacy identities on one line fail closed', () => {
  assert.throws(() => taskId(`- [ ] <!-- reminders:${id} --> Same <!-- reminders:${id} -->`), /multiple legacy/);
});
test('completion accepts standard and uppercase completed checkboxes', () => {
  assert.equal(completion('- [ ] Pending'), false);
  assert.equal(completion('  * [x] Done'), true);
  assert.equal(completion('1. [X] Done'), true);
  assert.throws(() => completion('- [/] Doing'), /standard/);
  assert.throws(() => completion('not a task'), /standard/);
});
test('recurring completion reports completed instance location without writing any IDs', () => {
  const result = toggledTask(`- [ ] Repeat 🔁 every day <!-- reminders:${id} -->\n- [x] Repeat 🔁 every day <!-- reminders:${id} --> ✅ 2026-09-29`, true);
  const [next, done] = result.markdown.split('\n');
  assert.equal(result.index, 1);
  assert.equal(taskId(next), undefined);
  assert.equal(taskId(done), undefined);
  assert.match(done, /✅ 2026-09-29/);
});
test('recurring completion also supports completed-first user ordering', () => {
  const result = toggledTask('- [x] Done\n- [ ] Next', true);
  assert.equal(result.index, 0);
  assert.equal(result.markdown, '- [x] Done\n- [ ] Next');
});
test('reopening leaves clean Markdown and rejects invalid status cycles', () => {
  assert.deepEqual(toggledTask('- [ ] Reopened', false), { markdown: '- [ ] Reopened', index: 0 });
  assert.throws(() => toggledTask('- [ ] Not completed', true), /requested/);
});
test('delete-on-completion accepts a successor without a completed instance only when explicitly requested', () => {
  const next = '- [ ] Organize padel for next sunday 🔁 every week on Sunday 🏁 delete 📅 2026-10-11';
  assert.deepEqual(toggledTask(next, true, true), { markdown: next, index: -1 });
  assert.deepEqual(toggledTask('', true, true), { markdown: '', index: -1 });
  assert.throws(() => toggledTask(next, true), /requested/);
  assert.throws(() => toggledTask(next, false, true), /delete/);
});
test('default query is generic: open tasks due or scheduled in the next two weeks', () => {
  assert.equal(DEFAULT_QUERY, `not done
(due before in 14 days) OR (scheduled before in 14 days)
sort by due
sort by priority`);
});
