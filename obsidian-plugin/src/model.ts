export const DEFAULT_QUERY = `not done
filter by function ['project', 'area', 'person'].includes(task.file.property('type'))
(due before in 15 days) OR (scheduled before in 15 days)
path does not include _ meta/templates
path does not include 9 Archive
sort by due
sort by scheduled
sort by priority`;

export const MARKER = /<!-- reminders:([a-f0-9-]{36}) -->/g;
export function taskId(line: string): string | undefined {
  return [...line.matchAll(MARKER)][0]?.[1];
}
export function withoutMarker(line: string): string {
  return line.replace(/[ \t]*<!-- reminders:[a-f0-9-]{36} -->/g, '').trimEnd();
}
export function withId(line: string, id: string): string {
  // Block references must stay at the end of the line.
  const clean = withoutMarker(line);
  const block = clean.match(/\s+\^[\w-]+$/)?.[0] ?? '';
  return `${clean.slice(0, clean.length - block.length)} <!-- reminders:${id} -->${block}`;
}
export function completion(line: string): boolean {
  const symbol = line.match(/^\s*(?:[-*+]|\d+[.)])\s+\[([^\]])\]/)?.[1];
  if (symbol !== ' ' && symbol?.toLowerCase() !== 'x') {
    throw new Error('V1 supports only standard [ ] and [x] task statuses.');
  }
  return symbol !== ' ';
}
export function toggledLines(result: string, id: string, desired: boolean): string {
  const lines = result.split('\n').map(withoutMarker);
  const index = lines.findIndex(line => completion(line) === desired);
  if (index < 0) throw new Error('Tasks toggle did not produce the requested completion status. Check custom status cycling.');
  lines[index] = withId(lines[index], id);
  return lines.join('\n');
}

export interface SnapshotTask {
  id: string; path: string; title: string; completed: boolean; selected: boolean;
  due: string | null; scheduled: string | null; priority: number;
}
export interface Command {
  version: number; id: string; taskId: string; completed: boolean; expectedCompleted: boolean;
}
