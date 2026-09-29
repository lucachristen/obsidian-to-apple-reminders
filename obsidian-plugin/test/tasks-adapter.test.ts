import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { App } from 'obsidian';
import { TasksAdapter, type TasksTask } from '../src/tasks-adapter';

// Contract tests for the private integration seam, not an Obsidian runtime test.
const task = { originalMarkdown: '- [ ] Example' } as TasksTask;
function fixture(options: { error?: string; searchError?: string; cold?: boolean; changed?: boolean } = {}) {
  let loads = 0;
  let unloaded = false;
  let received = '';
  Object.defineProperty(globalThis, 'document', { configurable: true, value: {
    createElement: () => ({ remove() {} }),
  } });
  const plugin = {
    getState: () => options.cold ? 'Cold' : 'Warm',
    getTasks: () => [task],
    apiV1: { executeToggleTaskDoneCommand: (line: string) => line.replace('[ ]', '[x]') },
    queryRenderer: {
      async addQueryRenderChild(source: string, _element: unknown, context: { addChild(child: unknown): void }) {
        received = source;
        const child = {
          load: () => { loads++; },
          unload: () => { unloaded = true; },
          queryResultsRenderer: options.changed ? undefined : { query: {
            error: options.error,
            applyQueryToTasks: () => ({ searchErrorMessage: options.searchError, groups: [{ tasks: [task] }] }),
          } },
        };
        context.addChild(child);
        child.load();
      },
    },
  };
  const adapter = new TasksAdapter({ plugins: { getPlugin: () => plugin } } as unknown as App);
  return { adapter, get received() { return received; }, get loads() { return loads; }, get unloaded() { return unloaded; } };
}
test('delegates the query unchanged and returns real task identities without starting renderer', async () => {
  const f = fixture();
  const source = "filter by function task.file.property('type') === 'project'";
  const result = await f.adapter.select(source, 'Sync.md');
  assert.equal(f.received, source);
  assert.equal(f.loads, 0);
  assert.equal(f.unloaded, true);
  assert.equal(result.selected.has(task), true);
});
test('fails closed on cold cache, syntax errors, function errors and changed internals', async () => {
  await assert.rejects(fixture({ cold: true }).adapter.select('not done', ''), /cache/);
  const syntax = fixture({ error: 'bad syntax' });
  await assert.rejects(syntax.adapter.select('bad', ''), /bad syntax/);
  assert.equal(syntax.unloaded, true);
  await assert.rejects(fixture({ searchError: 'function failed' }).adapter.select('filter', ''), /function failed/);
  await assert.rejects(fixture({ changed: true }).adapter.select('not done', ''), /internals changed/);
});
