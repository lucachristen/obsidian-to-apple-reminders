import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { emptyRegistry, observation, resolveIdentities } from '../src/identity';
import { loadRegistry, saveRegistry } from '../src/identity-store';

const id = '11111111-1111-4111-a111-111111111111';
test('registry and backup survive restart, missing primary and corrupted primary', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bridge-identities-'));
  const path = join(directory, 'identities.json');
  try {
    const registry = resolveIdentities(emptyRegistry(), [observation('Tasks.md', 0, '- [ ] Test', true)], () => id).registry;
    await saveRegistry(path, registry);
    assert.deepEqual(await loadRegistry(path, true), registry);
    assert.deepEqual(JSON.parse(await readFile(`${path}.bak`, 'utf8')), registry);
    await rm(path);
    assert.deepEqual(await loadRegistry(path, true), registry);
    await writeFile(path, '{broken');
    assert.deepEqual(await loadRegistry(path, true), registry);
    assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), registry);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('missing/corrupt identity data never silently resets an existing bridge', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bridge-identities-'));
  const path = join(directory, 'identities.json');
  try {
    assert.deepEqual(await loadRegistry(path, false), emptyRegistry());
    await assert.rejects(loadRegistry(path, true), /registry is missing/);
    await writeFile(path, '{broken');
    await assert.rejects(loadRegistry(path, false));
    await writeFile(`${path}.bak`, '{also broken');
    await assert.rejects(loadRegistry(path, true));
  } finally { await rm(directory, { recursive: true, force: true }); }
});
