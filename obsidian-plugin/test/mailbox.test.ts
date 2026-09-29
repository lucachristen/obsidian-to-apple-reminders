import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { writeAtomicJSON } from '../src/mailbox';

test('successive snapshots replace an existing mailbox file without leaving temporary files', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'reminders-mailbox-test-'));
  try {
    const path = join(directory, 'snapshot.json');
    await writeAtomicJSON(path, { tasks: ['first'], version: 1 });
    await writeAtomicJSON(path, { tasks: ['second', 'third'], version: 1 });
    assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), { tasks: ['second', 'third'], version: 1 });
    assert.deepEqual(await readdir(directory), ['snapshot.json']);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
