export const DEFAULT_QUERY = `not done
(due before in 14 days) OR (scheduled before in 14 days)
sort by due
sort by priority`;

export const MARKER = /<!-- reminders:([a-f0-9-]{36}) -->/g;
export function taskId(line: string): string | undefined {
  const matches = [...line.matchAll(MARKER)];
  if (matches.length > 1) throw new Error('Task has multiple legacy reminders IDs. Resolve its comments before migration.');
  return matches[0]?.[1];
}
export function withoutMarker(line: string): string {
  return line.replace(/[ \t]*<!-- reminders:[a-f0-9-]{36} -->/g, '').trimEnd();
}
export function completion(line: string): boolean {
  const symbol = line.match(/^\s*(?:[-*+]|\d+[.)])\s+\[([^\]])\]/)?.[1];
  if (symbol !== ' ' && symbol?.toLowerCase() !== 'x') {
    throw new Error('V1 supports only standard [ ] and [x] task statuses.');
  }
  return symbol !== ' ';
}
export function toggledTask(result: string, desired: boolean, deletesCompleted = false): { markdown: string; index: number } {
  if (deletesCompleted && !desired) throw new Error('Cannot reopen a delete-on-completion task.');
  const lines = result === '' ? [] : result.split(/\r?\n/).map(withoutMarker);
  const index = lines.findIndex(line => completion(line) === desired);
  if (index < 0 && !deletesCompleted) throw new Error('Tasks toggle did not produce the requested completion status. Check custom status cycling.');
  return { markdown: lines.join('\n'), index };
}

export interface SnapshotTask {
  id: string; path: string; title: string; completed: boolean; selected: boolean;
  due: string | null; scheduled: string | null; priority: number;
}
export interface Command {
  version: number; id: string; taskId: string; completed: boolean; expectedCompleted: boolean;
}
