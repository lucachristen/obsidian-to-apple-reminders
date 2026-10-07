import assert from 'node:assert/strict';
import { test } from 'node:test';
import { emptyRegistry, observation, relink, resolveIdentities, validateRegistry, type IdentityRegistry } from '../src/identity';

const id = '11111111-1111-4111-a111-111111111111';
let sequence = 0;
const uuid = () => `22222222-2222-4222-a222-${String(++sequence).padStart(12, '0')}`;
const observe = (text: string, path = 'Tasks.md') => text.split('\n').flatMap((line, i) => /^- \[[ xX]\]/.test(line) ? [observation(path, i, text, !line.startsWith('- [x]'))] : []);
const start = (text: string) => resolveIdentities(emptyRegistry(), observe(text), uuid);

test('assigns sidecar IDs without modifying Markdown, retaining them across restart', () => {
  const text = '# Tasks\n- [ ] Call Alex 📅 2026-10-01\n';
  const first = start(text);
  assert.equal(first.linked.size, 1);
  assert.equal(first.registry.records[0].anchor.markdown, text.split('\n')[1]);
  const second = resolveIdentities(validateRegistry(JSON.parse(JSON.stringify(first.registry))), observe(text), uuid);
  assert.deepEqual(second.registry, first.registry);
});
test('tracks unique tasks through line shifts, renames and moves', () => {
  const first = start('# Tasks\n- [ ] Call Alex\n');
  const moved = observe('# Other\n\n\n- [ ] Call Alex\n', 'Elsewhere.md');
  const next = resolveIdentities(first.registry, moved, uuid);
  assert.equal(next.linked.get(first.registry.records[0].id), 0);
  assert.equal(next.registry.records[0].anchor.path, 'Elsewhere.md');
  assert.equal(next.paused.length, 0);
});
test('uses surrounding context for same-position title/date edits, never position alone', () => {
  const first = start('# Calls\n- [ ] Call Alex 📅 2026-10-01\nNotes');
  const edited = resolveIdentities(first.registry, observe('# Calls\n- [ ] Phone Alex 📅 2026-10-02\nNotes'), uuid);
  assert.equal(edited.linked.size, 1);
  const replaced = resolveIdentities(first.registry, observe('# Shopping\n- [ ] Buy milk\nDifferent'), uuid);
  assert.equal(replaced.linked.size, 0);
  assert.equal(replaced.paused.length, 1);
  assert.equal(replaced.registry.records.length, 1);
});
test('completion/reopening retain identity but recurrence successors get a new ID', () => {
  const first = start('# Daily\n- [ ] Repeat 🔁 every day 📅 2026-10-01\n');
  const next = resolveIdentities(first.registry, observe('# Daily\n- [ ] Repeat 🔁 every day 📅 2026-10-02\n- [x] Repeat 🔁 every day 📅 2026-10-01 ✅ 2026-10-01\n'), uuid);
  const oldId = first.registry.records[0].id;
  assert.equal(next.linked.get(oldId), 1);
  assert.equal(next.registry.records.length, 2);
  const reopened = resolveIdentities(next.registry, observe('# Daily\n- [ ] Repeat 🔁 every day 📅 2026-10-02\n- [ ] Repeat 🔁 every day 📅 2026-10-01\n'), uuid);
  assert.equal(reopened.linked.get(oldId), 1);
});
test('identical tasks are stable in an unchanged note but ambiguous after edits', () => {
  const first = start('- [ ] Same\n- [ ] Same');
  const unchanged = resolveIdentities(first.registry, observe('- [ ] Same\n- [ ] Same'), uuid);
  assert.equal(unchanged.linked.size, 2);
  const moved = resolveIdentities(first.registry, observe('# New\n- [ ] Same\n- [ ] Same', 'Moved.md'), uuid);
  assert.equal(moved.paused.length, 2);
  assert.equal(moved.linked.size, 0);
  assert.equal(moved.registry.records.length, 2);
});
test('competing old identities cannot both claim one new task', () => {
  const first = start('- [ ] Same\n- [ ] Same');
  const next = resolveIdentities(first.registry, observe('- [ ] Same', 'Moved.md'), uuid);
  assert.equal(next.linked.size, 0);
  assert.equal(next.paused.length, 2);
});
test('unresolved/deleted tasks are retained, unaffected links still work, new tasks wait', () => {
  const first = start('# Work\n- [ ] Keep\n- [ ] Missing');
  const next = resolveIdentities(first.registry, observe('# Work\n- [ ] Keep\n- [ ] New\nChanged'), uuid);
  assert.equal(next.linked.size, 1);
  assert.equal(next.paused.length, 1);
  assert.equal(next.registry.records.length, 2);
  assert.equal(next.available.length, 1);
});
test('explicit relink preserves original UUID and forget allows genuinely new identities', () => {
  const first = start('- [ ] Original');
  const target = observe('- [ ] Entirely rewritten', 'Moved.md');
  const next = resolveIdentities(relink(first.registry, first.registry.records[0].id, target[0]), target, uuid);
  assert.equal(next.linked.get(first.registry.records[0].id), 0);
  const forgotten: IdentityRegistry = { version: 1, records: [] };
  const fresh = resolveIdentities(forgotten, target, uuid);
  assert.notEqual(fresh.registry.records[0].id, first.registry.records[0].id);
});
test('legacy migration retains UUID, tolerates partially stripped comments and rejects copies', () => {
  const legacy = observe(`# Tasks\n- [ ] <!-- reminders:${id} --> Call Alex 📅 2026-10-01`);
  const first = resolveIdentities(emptyRegistry(), legacy, uuid);
  assert.equal(first.registry.records[0].id, id);
  assert.equal(first.registry.records[0].anchor.markdown, '- [ ] Call Alex 📅 2026-10-01');
  const next = resolveIdentities(first.registry, observe('# Tasks\n- [ ] Call Alex 📅 2026-10-01'), uuid);
  assert.equal(next.linked.get(id), 0);
  assert.throws(() => resolveIdentities(emptyRegistry(), [...legacy, ...legacy], uuid), /Duplicate legacy/);
});
test('legacy markers cannot hijack a different registry identity', () => {
  const first = start('- [ ] Same');
  const next = resolveIdentities(first.registry, observe(`- [ ] <!-- reminders:${id} --> Same`), uuid);
  assert.equal(next.linked.get(id), 0);
  assert.equal(next.paused.length, 1);
});
test('invalid registry versions, duplicate IDs and malformed anchors fail closed', () => {
  assert.throws(() => validateRegistry({ version: 2, records: [] }));
  const first = start('- [ ] Task').registry;
  assert.throws(() => validateRegistry({ version: 1, records: [...first.records, ...first.records] }));
  assert.throws(() => validateRegistry({ version: 1, records: [{ id, anchor: {} }] }));
});
