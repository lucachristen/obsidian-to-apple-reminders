import type { App, MarkdownRenderChild, MarkdownPostProcessorContext } from 'obsidian';

export interface TasksTask {
  originalMarkdown: string;
  description: string;
  taskLocation: { path: string; lineNumber: number };
  isDone: boolean;
  priorityNumber: number;
  dueDate: { format(pattern: string): string } | null;
  scheduledDate: { format(pattern: string): string } | null;
}
interface Query {
  error?: string;
  applyQueryToTasks(tasks: TasksTask[]): {
    searchErrorMessage?: string;
    groups: { tasks: TasksTask[] }[];
  };
}
interface TasksPlugin {
  manifest: { version: string };
  getState(): string;
  getTasks(): TasksTask[];
  apiV1: { executeToggleTaskDoneCommand(line: string, path: string): string };
  queryRenderer: {
    addQueryRenderChild(source: string, element: HTMLElement, context: MarkdownPostProcessorContext): Promise<void>;
  };
}

/** All unsupported Tasks internals are isolated here. Never fall back to an approximate query. */
export class TasksAdapter {
  constructor(private app: App) {}
  plugin(): TasksPlugin {
    const plugin = (this.app as App & { plugins: { getPlugin(id: string): unknown } }).plugins.getPlugin('obsidian-tasks-plugin') as TasksPlugin | undefined;
    if (!plugin?.getTasks || !plugin?.queryRenderer?.addQueryRenderChild || !plugin?.apiV1) {
      throw new Error('Enable a compatible Obsidian Tasks plugin (adapter checked against Tasks 8.4.0 source; see README).');
    }
    if (plugin.getState() !== 'Warm') throw new Error('Waiting for the Tasks cache to finish loading.');
    return plugin;
  }
  async select(source: string, sourcePath: string): Promise<{ all: TasksTask[]; selected: Set<TasksTask> }> {
    const plugin = this.plugin();
    let child: (MarkdownRenderChild & { queryResultsRenderer?: { query: Query } }) | undefined;
    const element = document.createElement('div');
    const context = {
      sourcePath,
      addChild: (value: MarkdownRenderChild) => {
        child = value;
        // We only need the constructor-created query, not a live renderer, observers,
        // cache subscriptions, or a second evaluation of JavaScript filters.
        value.load = () => {};
      },
      getSectionInfo: () => null,
      frontmatter: null,
    } as unknown as MarkdownPostProcessorContext;
    try {
      await plugin.queryRenderer.addQueryRenderChild(source, element, context);
      const query = child?.queryResultsRenderer?.query;
      if (!query?.applyQueryToTasks) throw new Error('Tasks query internals changed; syncing paused.');
      if (query.error) throw new Error(query.error);
      const all = plugin.getTasks();
      const result = query.applyQueryToTasks(all);
      if (result.searchErrorMessage) throw new Error(result.searchErrorMessage);
      if (!Array.isArray(result.groups) || result.groups.some(group => !Array.isArray(group.tasks))) {
        throw new Error('Unexpected Tasks query result; syncing paused.');
      }
      return { all, selected: new Set(result.groups.flatMap(group => group.tasks)) };
    } finally {
      child?.unload();
      element.remove();
    }
  }
  toggle(line: string, path: string): string {
    return this.plugin().apiV1.executeToggleTaskDoneCommand(line, path);
  }
}
