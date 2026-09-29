import { rename, writeFile } from 'node:fs/promises';

/** Desktop-only atomic replacement. Obsidian adapter.rename rejects existing targets. */
export async function writeAtomicJSON(path: string, value: unknown): Promise<void> {
  const temporary = `${path}.tmp`;
  await writeFile(temporary, JSON.stringify(value, null, 2), 'utf8');
  await rename(temporary, path);
}
