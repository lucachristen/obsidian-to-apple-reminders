import { readFile } from 'node:fs/promises';
import { writeAtomicJSON } from './mailbox';
import { emptyRegistry, validateRegistry, type IdentityRegistry } from './identity';

async function readRegistry(path: string): Promise<IdentityRegistry | undefined> {
  try { return validateRegistry(JSON.parse(await readFile(path, 'utf8'))); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw error;
  }
}

export async function loadRegistry(path: string, hasExistingSnapshot: boolean): Promise<IdentityRegistry> {
  let primaryError: unknown;
  try {
    const primary = await readRegistry(path);
    if (primary) return primary;
  } catch (error) { primaryError = error; }
  const backup = await readRegistry(`${path}.bak`);
  if (backup) {
    await writeAtomicJSON(path, backup);
    return backup;
  }
  if (primaryError) throw primaryError;
  if (hasExistingSnapshot) throw new Error('Identity registry is missing. Restore identities.json or its backup; sync cannot safely start over.');
  return emptyRegistry();
}

/** Both copies are durable before callers edit Markdown or publish snapshots. */
export async function saveRegistry(path: string, registry: IdentityRegistry): Promise<void> {
  validateRegistry(registry);
  await writeAtomicJSON(path, registry);
  await writeAtomicJSON(`${path}.bak`, registry);
}
