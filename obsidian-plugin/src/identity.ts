import { createHash } from 'node:crypto';
import { taskId, withoutMarker } from './model';

export interface Anchor {
  path: string; line: number; markdown: string; before: string; after: string; noteHash: string;
}
export interface IdentityRecord { id: string; anchor: Anchor }
export interface CompletionDeletion {
  taskId: string; commandId: string; path: string; before: string; after: string;
}
export interface IdentityRegistry { version: 1; records: IdentityRecord[]; pendingDeletion?: CompletionDeletion }
export interface Observation { anchor: Anchor; legacyId?: string; selected: boolean }
export interface IdentityResolution {
  registry: IdentityRegistry;
  linked: Map<string, number>;
  paused: IdentityRecord[];
  available: number[];
}
export const emptyRegistry = (): IdentityRegistry => ({ version: 1, records: [] });
export const validId = (id: unknown): id is string => typeof id === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(id);

/** Ignore completion metadata, not deadlines/recurrence: successors are different tasks. */
export function fingerprint(line: string): string {
  return withoutMarker(line).replace(/^(\s*(?:[-*+]|\d+[.)])\s+)\[[ xX]\]/, '$1[ ]')
    .replace(/\s*✅\s*\d{4}-\d{2}-\d{2}/g, '').trim();
}
export function observeNote(path: string, text: string): (line: number, selected: boolean) => Observation {
  const original = text.split(/\r?\n/);
  const lines = original.map(withoutMarker);
  const noteHash = createHash('sha256').update(lines.join('\n')).digest('hex');
  return (line, selected) => ({
    anchor: { path, line, markdown: lines[line], before: fingerprint(lines[line - 1] ?? ''), after: fingerprint(lines[line + 1] ?? ''), noteHash },
    legacyId: taskId(original[line]), selected,
  });
}
export function anchor(path: string, line: number, text: string): Anchor {
  return observeNote(path, text)(line, false).anchor;
}
export function observation(path: string, line: number, text: string, selected: boolean): Observation {
  return observeNote(path, text)(line, selected);
}
export function validateRegistry(value: unknown): IdentityRegistry {
  const data = value as IdentityRegistry;
  if (data?.version !== 1 || !Array.isArray(data.records)) throw new Error('Invalid identity registry. Restore its backup.');
  const deletion = data.pendingDeletion;
  if (deletion && (!validId(deletion.taskId) || !validId(deletion.commandId) ||
      typeof deletion.path !== 'string' || typeof deletion.before !== 'string' || typeof deletion.after !== 'string')) {
    throw new Error('Invalid completion deletion journal. Restore its backup.');
  }
  const ids = new Set<string>();
  for (const record of data.records) {
    const a = record?.anchor;
    if (!validId(record?.id) || ids.has(record.id) || !a || typeof a.path !== 'string' ||
        !Number.isInteger(a.line) || a.line < 0 || typeof a.markdown !== 'string' ||
        typeof a.before !== 'string' || typeof a.after !== 'string' || typeof a.noteHash !== 'string') {
      throw new Error('Invalid identity registry. Restore its backup.');
    }
    ids.add(record.id);
  }
  return data;
}

/** Conservative, reciprocal matching. Never use line number alone or fuzzy title similarity. */
export function resolveIdentities(registry: IdentityRegistry, observations: Observation[], uuid: () => string): IdentityResolution {
  const records = registry.records.map(record => ({ ...record, anchor: { ...record.anchor } }));
  const legacy = new Set<string>();
  for (const o of observations) {
    if (!o.legacyId) continue;
    if (!validId(o.legacyId) || legacy.has(o.legacyId)) throw new Error('Duplicate legacy task ID. Remove the copied comment before migrating.');
    legacy.add(o.legacyId);
    if (!records.some(r => r.id === o.legacyId)) records.push({ id: o.legacyId, anchor: o.anchor });
  }
  const linked = new Map<string, number>();
  const used = new Set<number>();
  const rules: ((r: IdentityRecord, o: Observation) => boolean)[] = [
    (r, o) => o.legacyId === r.id,
    (r, o) => r.anchor.path === o.anchor.path && r.anchor.noteHash === o.anchor.noteHash && r.anchor.line === o.anchor.line && r.anchor.markdown === o.anchor.markdown,
    (r, o) => r.anchor.path === o.anchor.path && r.anchor.markdown === o.anchor.markdown,
    (r, o) => r.anchor.path === o.anchor.path && fingerprint(r.anchor.markdown) === fingerprint(o.anchor.markdown),
    (r, o) => fingerprint(r.anchor.markdown) === fingerprint(o.anchor.markdown),
    (r, o) => r.anchor.path === o.anchor.path && r.anchor.line === o.anchor.line &&
      !!(r.anchor.before || r.anchor.after) && r.anchor.before === o.anchor.before && r.anchor.after === o.anchor.after,
  ];
  for (const rule of rules) {
    const proposals = records.filter(r => !linked.has(r.id)).map(record => ({
      record, candidates: observations.flatMap((o, i) => !used.has(i) && (!o.legacyId || o.legacyId === record.id) && rule(record, o) ? [i] : []),
    }));
    for (const { record, candidates } of proposals) {
      if (candidates.length !== 1) continue;
      const index = candidates[0];
      if (proposals.some(p => p.record !== record && p.candidates.includes(index))) continue;
      linked.set(record.id, index); used.add(index);
    }
  }
  const paused = records.filter(r => !linked.has(r.id));
  const available = observations.flatMap((_, i) => used.has(i) ? [] : [i]);
  // With missing identities, unmatched tasks could be moved/rewritten originals.
  // Hold these newcomers too; confidently linked tasks continue to sync normally.
  if (!paused.length) {
    for (const index of available) {
      if (!observations[index].selected) continue;
      const id = uuid();
      records.push({ id, anchor: observations[index].anchor }); linked.set(id, index);
    }
  }
  for (const record of records) {
    const index = linked.get(record.id);
    if (index !== undefined) record.anchor = observations[index].anchor;
  }
  return { registry: { version: 1, records }, linked, paused, available: available.filter(i => ![...linked.values()].includes(i)) };
}

/** Explicit user choice; the next resolver pass verifies this exact note revision. */
export function relink(registry: IdentityRegistry, id: string, target: Observation): IdentityRegistry {
  if (!registry.records.some(r => r.id === id)) throw new Error('Unknown identity. Refresh the relinking screen.');
  return { version: 1, records: registry.records.map(r => r.id === id ? { id, anchor: target.anchor } : r) };
}
