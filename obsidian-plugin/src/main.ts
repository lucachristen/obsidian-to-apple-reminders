import { Notice, Plugin, PluginSettingTab, Setting, TFile, normalizePath } from 'obsidian';
import { DEFAULT_QUERY, completion, taskId, toggledLines, withId, withoutMarker, type Command, type SnapshotTask } from './model';
import { TasksAdapter, type TasksTask } from './tasks-adapter';

interface Settings { query: string; queryPath: string; enabled: boolean }
export default class RemindersCompanion extends Plugin {
  settings: Settings = { query: DEFAULT_QUERY, queryPath: '', enabled: false };
  private busy = false;
  private status!: HTMLElement;
  private tasks!: TasksAdapter;
  private get directory(): string { return normalizePath(`${this.app.vault.configDir}/plugins/${this.manifest.id}/bridge`); }
  async onload() {
    this.settings = { ...this.settings, ...await this.loadData() };
    this.tasks = new TasksAdapter(this.app);
    this.status = this.addStatusBarItem();
    this.status.setText('Reminders: disabled');
    this.addSettingTab(new BridgeSettings(this));
    this.addCommand({ id: 'sync-now', name: 'Sync now', callback: () => { void this.sync(); } });
    this.registerInterval(window.setInterval(() => { void this.sync(); }, 10_000));
    this.app.workspace.onLayoutReady(() => { void this.sync(); });
  }
  async configure() {
    await this.saveData(this.settings);
    if (!this.settings.enabled && await this.app.vault.adapter.exists(this.directory)) {
      await this.writeJSON(`${this.directory}/error.json`, { message: 'Sync is disabled in Obsidian.' });
    }
    await this.sync();
  }
  private async writeJSON(path: string, value: unknown) {
    const adapter = this.app.vault.adapter;
    const temporary = `${path}.tmp`;
    await adapter.write(temporary, JSON.stringify(value, null, 2));
    // Desktop filesystem adapter rename replaces the destination atomically.
    await adapter.rename(temporary, path);
  }
  private async updateLine(task: TasksTask, transform: (line: string) => string) {
    const file = this.app.vault.getAbstractFileByPath(task.taskLocation.path);
    if (!(file instanceof TFile)) throw new Error(`Missing task file: ${task.taskLocation.path}`);
    await this.app.vault.process(file, text => {
      const newline = text.includes('\r\n') ? '\r\n' : '\n';
      const lines = text.split(/\r?\n/);
      const index = task.taskLocation.lineNumber;
      if (lines[index] !== task.originalMarkdown) throw new Error('Task changed while syncing; retrying after cache refresh.');
      lines[index] = transform(lines[index]).replace(/\r?\n/g, newline);
      return lines.join(newline);
    });
  }
  private async commands(all: TasksTask[]): Promise<boolean> {
    const adapter = this.app.vault.adapter;
    const listing = await adapter.list(`${this.directory}/commands`);
    for (const path of listing.files.filter(path => path.endsWith('.json'))) {
      const command = JSON.parse(await adapter.read(path)) as Command;
      if (command.version !== 1 || !/^[a-f0-9-]{36}$/.test(command.id) || typeof command.completed !== 'boolean' || typeof command.expectedCompleted !== 'boolean') {
        throw new Error('Invalid bridge completion command.');
      }
      const ack = `${this.directory}/acks/${command.id}.json`;
      if (await adapter.exists(ack)) continue;
      const task = all.find(task => taskId(task.originalMarkdown) === command.taskId);
      if (!task) {
        await this.writeJSON(ack, { id: command.id, error: 'Task no longer exists in the Tasks cache.' });
        continue;
      }
      const current = completion(task.originalMarkdown);
      if (current !== command.completed && current !== command.expectedCompleted) {
        await this.writeJSON(ack, { id: command.id, error: 'Task completion changed concurrently.' });
        continue;
      }
      if (current !== command.completed) {
        await this.updateLine(task, line => toggledLines(this.tasks.toggle(line, task.taskLocation.path), command.taskId, command.completed));
        await this.writeJSON(ack, { id: command.id, error: null });
        return true; // Do not publish stale Tasks cache data after editing.
      }
      await this.writeJSON(ack, { id: command.id, error: null });
    }
    return false;
  }
  async sync() {
    if (this.busy || !this.settings.enabled) return;
    this.busy = true;
    try {
      const adapter = this.app.vault.adapter;
      for (const path of [this.directory, `${this.directory}/commands`, `${this.directory}/acks`]) {
        if (!await adapter.exists(path)) await adapter.mkdir(path);
      }
      if (this.settings.queryPath && !(this.app.vault.getAbstractFileByPath(this.settings.queryPath) instanceof TFile)) {
        throw new Error('The query context note does not exist.');
      }
      const { all, selected } = await this.tasks.select(this.settings.query, this.settings.queryPath);
      const ids = new Set<string>();
      for (const task of all) {
        const id = taskId(task.originalMarkdown);
        if (!id) continue;
        if (ids.has(id)) throw new Error(`Duplicate reminders ID in ${task.taskLocation.path}. Remove the copied marker before syncing.`);
        ids.add(id);
      }
      if (await this.commands(all)) return;
      // ID insertion never adds lines. Verify each original line inside vault.process.
      let assigned = false;
      for (const task of selected) {
        completion(task.originalMarkdown);
        if (!taskId(task.originalMarkdown)) {
          await this.updateLine(task, line => withId(line, crypto.randomUUID()));
          assigned = true;
        }
      }
      if (assigned) return; // Wait for Tasks to reparse the inserted markers.
      const result: SnapshotTask[] = all.filter(task => taskId(task.originalMarkdown)).map(task => ({
        id: taskId(task.originalMarkdown)!, path: task.taskLocation.path,
        title: withoutMarker(task.description).replace(/\s+\^[\w-]+$/, '').trim(),
        completed: completion(task.originalMarkdown), selected: selected.has(task),
        due: task.dueDate?.format('YYYY-MM-DD') ?? null,
        scheduled: task.scheduledDate?.format('YYYY-MM-DD') ?? null,
        priority: task.priorityNumber,
      }));
      await this.writeJSON(`${this.directory}/snapshot.json`, {
        version: 1, generatedAt: new Date().toISOString(), vault: this.app.vault.getName(), tasks: result,
      });
      if (await adapter.exists(`${this.directory}/error.json`)) await adapter.remove(`${this.directory}/error.json`);
      this.status.setText(`Reminders: ${selected.size} selected`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.status.setText(`Reminders: ${message}`);
      try { await this.writeJSON(`${this.directory}/error.json`, { message }); } catch { /* Directory may be unavailable. */ }
      console.error('Reminders Bridge:', error);
    } finally { this.busy = false; }
  }
}
class BridgeSettings extends PluginSettingTab {
  constructor(private plugin: RemindersCompanion) { super(plugin.app, plugin); }
  display() {
    this.containerEl.empty();
    this.containerEl.createEl('h2', { text: 'Apple Reminders Bridge' });
    this.containerEl.createEl('p', { text: 'Tasks must be enabled. Allow JavaScript queries in Tasks for function filters. Both Obsidian and the Mac app must be running.' });
    new Setting(this.containerEl).setName('Enable sync').addToggle(toggle => toggle.setValue(this.plugin.settings.enabled).onChange(async enabled => {
      this.plugin.settings.enabled = enabled; await this.plugin.configure();
    }));
    new Setting(this.containerEl).setName('Query context note').setDesc('Optional vault-relative note path, for query.file properties and placeholders.').addText(text => text.setValue(this.plugin.settings.queryPath).onChange(async value => {
      this.plugin.settings.queryPath = value; await this.plugin.saveData(this.plugin.settings);
    }));
    new Setting(this.containerEl).setName('Tasks query').setDesc('Executed by Tasks itself, including its global query. Unsupported versions fail closed.').addTextArea(text => {
      text.setValue(this.plugin.settings.query); text.inputEl.rows = 12; text.inputEl.cols = 70;
      text.onChange(async value => { this.plugin.settings.query = value; await this.plugin.saveData(this.plugin.settings); });
    });
    new Setting(this.containerEl).setName('Sync now').addButton(button => button.setButtonText('Sync').onClick(async () => {
      await this.plugin.sync(); new Notice('Bridge sync attempted. Check the status bar for results.');
    }));
  }
}
