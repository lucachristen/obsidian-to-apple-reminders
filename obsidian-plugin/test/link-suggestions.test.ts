import assert from 'node:assert/strict';
import { test } from 'node:test';
import { observation, type IdentityRecord } from '../src/identity';
import { linkSuggestions } from '../src/link-suggestions';

const original: IdentityRecord = {
  id: '11111111-1111-4111-a111-111111111111',
  anchor: observation('Areas/Sport.md', 1, '# Weekend plans\n- [ ] Organize padel for next sunday 🔁 every week on Sunday 🏁 delete 📅 2026-10-04\nInvite friends', true).anchor,
};
const candidate = (path: string, title: string, before = '# Other', after = '') =>
  observation(path, 1, `${before}\n- [ ] ${title}\n${after}`, false);

test('ranks a moved unchanged task before same-note unrelated tasks without linking anything', () => {
  const moved = candidate('Projects/Weekend.md', original.anchor.markdown.replace('- [ ] ', ''));
  const unrelated = candidate('Areas/Sport.md', 'Buy shoes');
  const candidates = [unrelated, moved];
  const before = JSON.stringify({ original, candidates });
  const suggestions = linkSuggestions(original, candidates);
  assert.equal(suggestions[0].target, moved);
  assert.ok(suggestions[0].reasons.includes('Unchanged task'));
  assert.equal(JSON.stringify({ original, candidates }), before);
});
test('ranks rewritten titles and shared context ahead of unrelated tasks', () => {
  const related = candidate('Projects/Weekend.md', 'Arrange padel for next sunday 📅 2026-10-11', '# Weekend plans', 'Invite friends');
  const unrelated = candidate('Areas/Sport.md', 'Buy shoes');
  const suggestions = linkSuggestions(original, [unrelated, related]);
  assert.equal(suggestions[0].target, related);
  assert.ok(suggestions[0].reasons.includes('Similar title'));
  assert.ok(suggestions[0].reasons.includes('Same surrounding context'));
});
test('search combines terms from title, full note path and neighboring lines, ignoring case and accents', () => {
  const target = candidate('People/José.md', 'Organize padel 📅 2026-10-11', '# Weekend plans', 'Invite friends');
  for (const query of ['JOSE padel', 'padel friends', 'weekend people', '2026-10-11']) {
    assert.equal(linkSuggestions(original, [target], query)[0]?.target, target, query);
  }
  assert.deepEqual(linkSuggestions(original, [target], 'padel dentist'), []);
});
test('equally likely duplicates stay visible and sort deterministically by path and line', () => {
  const a = candidate('A.md', 'Organize padel');
  const b = candidate('B.md', 'Organize padel');
  assert.deepEqual(linkSuggestions(original, [b, a]).map(s => s.target), [a, b]);
  assert.deepEqual(linkSuggestions(original, [a, b]).map(s => s.target), [a, b]);
});
test('suggestions expose full task and context for comparison, including tasks outside the query', () => {
  const target = candidate('Projects/Weekend.md', 'Organize padel 📅 2026-10-11', '# Weekend plans', 'Invite friends');
  const suggestion = linkSuggestions(original, [target])[0];
  assert.equal(suggestion.title, 'Organize padel 📅 2026-10-11');
  assert.equal(suggestion.location, 'Projects/Weekend.md · line 2');
  assert.equal(suggestion.before, '# Weekend plans');
  assert.equal(suggestion.after, 'Invite friends');
  assert.equal(suggestion.target.selected, false);
});
