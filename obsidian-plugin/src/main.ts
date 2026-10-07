import { FileSystemAdapter, Modal, Notice, Plugin, PluginSettingTab, Setting, SuggestModal, TFile, normalizePath, setIcon, type ButtonComponent } from 'obsidian';
import { join } from 'node:path';
import { writeAtomicJSON } from './mailbox';
import { DEFAULT_QUERY, completion, taskId, toggledTask, withoutMarker, type Command, type SnapshotTask } from './model';
import { anchor, observeNote, relink, resolveIdentities, validId, type Anchor, type IdentityRecord, type IdentityRegistry, type IdentityResolution, type Observation } from './identity';
import { loadRegistry, saveRegistry } from './identity-store';
import { linkSuggestions, taskTitle, type LinkSuggestion } from './link-suggestions';
import { TasksAdapter, type TasksTask } from './tasks-adapter';

interface Settings { query: string; queryPath: string; enabled: boolean }
export default class RemindersCompanion extends Plugin {
  settings: Settings = { query: DEFAULT_QUERY, queryPath: '', enabled: false };
  private busy = false;
  private status!: HTMLElement;
  private tasks!: TasksAdapter;
  private registry?: IdentityRegistry;
  private registryDurable = false;
  private resolution?: IdentityResolution;
  private observations: Observation[] = [];
  private renames: { oldPath: string; path: string }[] = [];
  private syncTimer?: number;
  private checkingCommands = false;
  lastSynced?: Date;
  lastError?: string;
  selectedCount = 0;
  private get directory(): string { return normalizePath(`${this.app.vault.configDir}/plugins/${this.manifest.id}/bridge`); }
  private absolute(path: string): string {
    const adapter = this.app.vault.adapter;
    if (!(adapter instanceof FileSystemAdapter)) throw new Error('Reminders Bridge requires a local desktop vault.');
    return join(adapter.getBasePath(), path);
  }
  async onload() {
    this.settings = { ...this.settings, ...await this.loadData() };
    this.tasks = new TasksAdapter(this.app);
    this.status = this.addStatusBarItem();
    this.status.addClass('reminders-bridge-status', 'mod-clickable');
    this.updateStatus();
    this.status.addEventListener('click', () => this.showLinks());
    this.addSettingTab(new BridgeSettings(this));
    this.addCommand({ id: 'sync-now', name: 'Sync now', callback: () => { void this.sync(); } });
    this.addCommand({ id: 'resolve-links', name: 'Review task links', callback: () => this.showLinks() });
    this.registerObsidianProtocolHandler('reminders-review-links', params => {
      if (params.vault && params.vault !== this.app.vault.getName()) { new Notice(`Open the ${params.vault} vault to review its task links.`); return; }
      this.showLinks();
    });
    this.registerEvent(this.app.vault.on('rename', (file, oldPath) => {
      this.renames.push({ oldPath, path: file.path });
      this.scheduleSync();
    }));
    this.registerEvent(this.app.metadataCache.on('changed', () => this.scheduleSync()));
    this.registerEvent(this.app.vault.on('delete', () => this.scheduleSync()));
    this.registerInterval(window.setInterval(() => { void this.checkCommands(); }, 1_000));
    this.registerInterval(window.setInterval(() => { void this.sync(); }, 10_000));
    this.register(() => { if (this.syncTimer !== undefined) window.clearTimeout(this.syncTimer); });
    this.app.workspace.onLayoutReady(() => { void this.sync(); });
  }
  private scheduleSync() {
    if (this.syncTimer !== undefined) window.clearTimeout(this.syncTimer);
    this.syncTimer = window.setTimeout(() => { this.syncTimer = undefined; void this.sync(); }, 750);
  }
  private async checkCommands() {
    if (this.checkingCommands || this.busy || !this.settings.enabled) return;
    this.checkingCommands = true;
    try {
      const adapter = this.app.vault.adapter;
      if (!await adapter.exists(`${this.directory}/commands`)) return;
      const listing = await adapter.list(`${this.directory}/commands`);
      for (const path of listing.files.filter(path => path.endsWith('.json'))) {
        const id = path.split('/').pop()!.replace(/\.json$/, '');
        if (!await adapter.exists(`${this.directory}/acks/${id}.json`)) { await this.sync(); break; }
      }
    } catch (error) { console.error('Reminders command check:', error); }
    finally { this.checkingCommands = false; }
  }
  async configure() {
    await this.saveData(this.settings);
    if (!this.settings.enabled) {
      this.updateStatus();
      if (await this.app.vault.adapter.exists(this.directory)) await this.writeJSON(`${this.directory}/error.json`, { message: 'Sync is disabled in Obsidian.' });
    }
    await this.sync();
  }
  private async writeJSON(path: string, value: unknown) {
    const payload = path.includes('/acks/') ? { ...(value as object), processedAt: new Date().toISOString() } : value;
    await writeAtomicJSON(this.absolute(path), payload);
  }
  private async persistRegistry(registry: IdentityRegistry) {
    if (this.registryDurable && JSON.stringify(this.registry) === JSON.stringify(registry)) return;
    await saveRegistry(this.absolute(`${this.directory}/identities.json`), registry);
    this.registry = registry;
    this.registryDurable = true;
  }
  private async note(task: TasksTask): Promise<{ file: TFile; text: string }> {
    const file = this.app.vault.getAbstractFileByPath(task.taskLocation.path);
    if (!(file instanceof TFile)) throw new Error(`Missing task file: ${task.taskLocation.path}`);
    const text = await this.app.vault.read(file);
    if (text.split(/\r?\n/)[task.taskLocation.lineNumber] !== task.originalMarkdown) {
      throw new Error('Task changed while syncing; waiting for the Tasks cache.');
    }
    return { file, text };
  }
  private async updateLine(task: TasksTask, transform: (line: string) => string, expectedText?: string) {
    const { file } = await this.note(task);
    await this.app.vault.process(file, text => {
      const newline = text.includes('\r\n') ? '\r\n' : '\n';
      const lines = text.split(/\r?\n/);
      const index = task.taskLocation.lineNumber;
      if (lines[index] !== task.originalMarkdown || (expectedText !== undefined && text !== expectedText)) {
        throw new Error('Task changed while syncing; waiting for the Tasks cache.');
      }
      lines[index] = transform(lines[index]).replace(/\r?\n/g, newline);
      return lines.join(newline);
    });
  }
  private async finishDeletion(): Promise<void> {
    const deletion = this.registry!.pendingDeletion!;
    const file = this.app.vault.getAbstractFileByPath(deletion.path);
    if (!(file instanceof TFile)) throw new Error('Missing note for pending completion deletion.');
    // Replay only the exact journaled edit. Never toggle the successor on retry.
    await this.app.vault.process(file, text => {
      if (text === deletion.after) return text;
      if (text !== deletion.before) throw new Error('Note changed during completion deletion; restore its prior content to retry safely.');
      return deletion.after;
    });
    await this.writeJSON(`${this.directory}/acks/${deletion.commandId}.json`, { id: deletion.commandId, error: null });
    await this.persistRegistry({ version: 1, records: this.registry!.records.filter(r => r.id !== deletion.taskId) });
  }
  private async commands(all: TasksTask[], resolution: IdentityResolution): Promise<boolean> {
    const adapter = this.app.vault.adapter;
    const listing = await adapter.list(`${this.directory}/commands`);
    for (const path of listing.files.filter(path => path.endsWith('.json'))) {
      const command = JSON.parse(await adapter.read(path)) as Command;
      if (command.version !== 1 || !validId(command.id) || !validId(command.taskId) || typeof command.completed !== 'boolean' || typeof command.expectedCompleted !== 'boolean') {
        throw new Error('Invalid bridge completion command.');
      }
      const ack = `${this.directory}/acks/${command.id}.json`;
      if (await adapter.exists(ack)) continue;
      // Keep pending requests durable until the user resolves the uncertain link.
      if (resolution.paused.some(r => r.id === command.taskId)) continue;
      const index = resolution.linked.get(command.taskId);
      const task = index === undefined ? undefined : all[index];
      if (!task) {
        await this.writeJSON(ack, { id: command.id, error: 'Task link was explicitly forgotten or no longer exists.' });
        continue;
      }
      const { text } = await this.note(task);
      const bound = this.registry!.records.find(r => r.id === command.taskId)!.anchor;
      const currentAnchor = anchor(task.taskLocation.path, task.taskLocation.lineNumber, text);
      if (currentAnchor.noteHash !== bound.noteHash || currentAnchor.line !== bound.line || currentAnchor.markdown !== bound.markdown) {
        throw new Error('Task identity context changed before completion; waiting for a fresh match.');
      }
      const current = completion(task.originalMarkdown);
      if (current !== command.completed && current !== command.expectedCompleted) {
        await this.writeJSON(ack, { id: command.id, error: 'Task completion changed concurrently.' });
        continue;
      }
      if (current !== command.completed) {
        const deletesCompleted = command.completed && /🏁\s*delete\b/.test(task.originalMarkdown);
        const result = toggledTask(this.tasks.toggle(task.originalMarkdown, task.taskLocation.path), command.completed, deletesCompleted);
        const lines = text.split(/\r?\n/);
        lines.splice(task.taskLocation.lineNumber, 1, ...(result.markdown === '' ? [] : result.markdown.split('\n')));
        const nextText = lines.join(text.includes('\r\n') ? '\r\n' : '\n');
        if (result.index < 0) {
          await this.persistRegistry({ ...this.registry!, pendingDeletion: {
            taskId: command.taskId, commandId: command.id, path: task.taskLocation.path, before: text, after: nextText,
          } });
          await this.finishDeletion();
          return true;
        }
        const nextAnchor = anchor(task.taskLocation.path, task.taskLocation.lineNumber + result.index, nextText);
        // Journal the resulting completed/reopened instance before editing. A crash
        // before the edit can still match the prior instance by completion fingerprint.
        await this.persistRegistry({ version: 1, records: this.registry!.records.map(r => r.id === command.taskId ? { id: r.id, anchor: nextAnchor } : r) });
        await this.updateLine(task, () => result.markdown, text);
        await this.writeJSON(ack, { id: command.id, error: null });
        return true;
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
        throw new Error('The note set in “Run query as if in note” doesn’t exist.');
      }
      const { all, selected } = await this.tasks.select(this.settings.query, this.settings.queryPath);
      const notes = new Map<string, string>();
      const noteLines = new Map<string, string[]>();
      for (const task of all) {
        if (!notes.has(task.taskLocation.path)) {
          const { text } = await this.note(task);
          notes.set(task.taskLocation.path, text);
          noteLines.set(task.taskLocation.path, text.split(/\r?\n/));
        }
        if (noteLines.get(task.taskLocation.path)![task.taskLocation.lineNumber] !== task.originalMarkdown) {
          throw new Error('Waiting for the Tasks cache to reflect note changes.');
        }
      }
      const observers = new Map([...notes].map(([path, text]) => [path, observeNote(path, text)]));
      this.observations = all.map(task => observers.get(task.taskLocation.path)!(task.taskLocation.lineNumber, selected.has(task)));
      if (!this.registry) {
        const snapshotPath = `${this.directory}/snapshot.json`;
        let existing = await adapter.exists(snapshotPath);
        if (existing) {
          const snapshot = JSON.parse(await adapter.read(snapshotPath)) as { version: number; tasks: SnapshotTask[] };
          const legacyIds = new Set(this.observations.map(o => o.legacyId));
          // Only v1's fully recoverable marker-based snapshot may bootstrap a registry.
          if (snapshot.version === 1 && snapshot.tasks.every(t => legacyIds.has(t.id))) existing = false;
        }
        this.registry = await loadRegistry(this.absolute(`${this.directory}/identities.json`), existing);
      }
      if (this.registry.pendingDeletion) {
        await this.finishDeletion();
        this.scheduleSync();
        return; // Reparse the note before assigning the successor a new identity.
      }
      let registry = this.registry;
      for (const rename of this.renames.splice(0)) {
        registry = { version: 1, records: registry.records.map(r => {
          const path = r.anchor.path === rename.oldPath ? rename.path : r.anchor.path.startsWith(`${rename.oldPath}/`) ? rename.path + r.anchor.path.slice(rename.oldPath.length) : r.anchor.path;
          return { ...r, anchor: { ...r.anchor, path } };
        }) };
      }
      const resolution = resolveIdentities(registry, this.observations, () => crypto.randomUUID());
      this.resolution = resolution;
      await this.persistRegistry(resolution.registry);
      // Both copies are durable before removing comments. Migration never adds lines;
      // each edit revalidates its original line, so partial failures safely resume.
      const legacyTasks = all.filter(task => taskId(task.originalMarkdown));
      if (legacyTasks.length) {
        await this.writeJSON(`${this.directory}/error.json`, { message: 'Migrating legacy task IDs into plugin data. Keep Obsidian open.' });
        for (const task of legacyTasks) await this.updateLine(task, withoutMarker);
        this.updateStatus('Migrating task links…');
        return; // Wait for Tasks to reparse the cleaned Markdown.
      }
      if (await this.commands(all, resolution)) { this.scheduleSync(); return; }
      const result: SnapshotTask[] = [...resolution.linked].map(([id, index]) => {
        const task = all[index];
        return {
          id, path: task.taskLocation.path,
          title: withoutMarker(task.description).replace(/\s+\^[\w-]+$/, '').trim(),
          completed: completion(task.originalMarkdown), selected: selected.has(task),
          due: task.dueDate?.format('YYYY-MM-DD') ?? null,
          scheduled: task.scheduledDate?.format('YYYY-MM-DD') ?? null,
          priority: task.priorityNumber,
        };
      });
      if (!this.settings.enabled) return;
      const ranks = new Map([...selected].map((task, i) => [task, i]));
      const ranksById = new Map([...resolution.linked].map(([id, index]) => [id, ranks.get(all[index]) ?? Infinity]));
      result.sort((a, b) => ranksById.get(a.id)! - ranksById.get(b.id)!);
      // v3 rejects older apps that cannot recover identity from reminder links.
      await this.writeJSON(`${this.directory}/snapshot.json`, {
        version: 3, generatedAt: new Date().toISOString(), vault: this.app.vault.getName(), tasks: result,
        pausedTaskIDs: resolution.paused.map(r => r.id),
        pausedTasks: resolution.paused.map(r => ({ id: r.id, path: r.anchor.path, title: r.anchor.markdown.replace(/^\s*(?:[-*+]|\d+[.)])\s+\[[^\]]\]\s*/, '') })),
      });
      if (await adapter.exists(`${this.directory}/error.json`)) await adapter.remove(`${this.directory}/error.json`);
      this.selectedCount = result.filter(t => t.selected).length;
      this.lastSynced = new Date(); this.lastError = undefined;
      this.updateStatus();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.lastError = message;
      this.updateStatus();
      try { await this.writeJSON(`${this.directory}/error.json`, { message }); } catch { /* Directory may be unavailable. */ }
      console.error('Reminders Bridge:', error);
    } finally { this.busy = false; }
  }
  /** One wording for the status bar and settings, matching the Mac app's menu. */
  statusLabel(): string {
    const review = this.uncertainLinks.length;
    if (!this.settings.enabled) return 'Sync paused';
    if (this.lastError) return 'Sync needs attention';
    if (review) return `${review} ${review === 1 ? 'task' : 'tasks'} to review`;
    return this.lastSynced ? 'Up to date' : 'Waiting for first sync';
  }
  statusDetail(): string {
    if (this.settings.enabled && this.lastError) return this.lastError;
    if (this.lastSynced) return `Last synced at ${this.lastSynced.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`;
    return 'Keep Obsidian and Reminders Bridge for Mac running.';
  }
  statusTone(): 'ok' | 'warning' | 'idle' {
    if (!this.settings.enabled) return 'idle';
    if (this.lastError || this.uncertainLinks.length) return 'warning';
    return this.lastSynced ? 'ok' : 'idle';
  }
  private updateStatus(label = this.statusLabel()) {
    this.status.empty();
    setIcon(this.status.createSpan({ cls: 'reminders-bridge-status-icon' }), 'list-checks');
    this.status.createSpan({ text: label });
    this.status.setAttr('aria-label', `Reminders Bridge: ${label}. ${this.statusDetail()}`);
    this.status.setAttr('data-tooltip-position', 'top');
  }
  showLinks() {
    const modal = new LinkModal(this);
    modal.open();
    return modal;
  }
  get uncertainLinks() { return this.resolution?.paused ?? []; }
  get linkCandidates() { return (this.resolution?.available ?? []).map(i => this.observations[i]); }
  async chooseLink(id: string, target?: Observation) {
    if (this.busy || !this.registry || !this.resolution?.paused.some(r => r.id === id)) throw new Error('Sync is busy or the link changed. Refresh and try again.');
    this.busy = true;
    try {
      if (target) {
        if (!this.linkCandidates.some(o => o.anchor.path === target.anchor.path && o.anchor.line === target.anchor.line && o.anchor.noteHash === target.anchor.noteHash && o.anchor.markdown === target.anchor.markdown)) throw new Error('Target is already linked or changed. Refresh and try again.');
        const file = this.app.vault.getAbstractFileByPath(target.anchor.path);
        if (!(file instanceof TFile)) throw new Error('Target note no longer exists.');
        const current = anchor(file.path, target.anchor.line, await this.app.vault.read(file));
        if (current.noteHash !== target.anchor.noteHash || current.markdown !== target.anchor.markdown) throw new Error('Target note changed. Sync and refresh before relinking.');
        await this.persistRegistry(relink(this.registry, id, target));
      } else {
        await this.persistRegistry({ version: 1, records: this.registry.records.filter(r => r.id !== id) });
      }
    } finally { this.busy = false; }
    await this.sync();
  }
}
function renderLinkContext(container: HTMLElement, task: Anchor, label?: string, open?: () => void) {
  if (label) container.createDiv({ cls: 'reminders-bridge-context-label', text: label });
  container.createDiv({ cls: 'reminders-bridge-context-title', text: taskTitle(task.markdown) });
  const location = container.createDiv({ cls: 'reminders-bridge-context-location' });
  const where = `${task.path} · line ${task.line + 1}`;
  if (open) location.createEl('a', { text: where, href: '#' }).addEventListener('click', event => { event.preventDefault(); open(); });
  else location.setText(where);
  if (task.before || task.after) {
    const context = container.createDiv({ cls: 'reminders-bridge-context-lines' });
    if (task.before) context.createDiv({ text: `Before: ${task.before}` });
    if (task.after) context.createDiv({ text: `After: ${task.after}` });
  }
}
/** Only a suggestion strong enough to name is offered up front; the user still confirms it. */
function likelyMatch(record: IdentityRecord, candidates: Observation[]): LinkSuggestion | undefined {
  const best = linkSuggestions(record, candidates)[0];
  return best?.reasons.some(r => r === 'Unchanged task' || r === 'Same title' || r === 'Similar title') ? best : undefined;
}
class LinkModal extends Modal {
  /** Tasks the user picked by hand, kept across re-renders until they link or close. */
  private chosen = new Map<string, Observation>();
  constructor(private plugin: RemindersCompanion) { super(plugin.app); }
  onOpen() { this.modalEl.addClass('reminders-bridge-review'); this.render(); }
  private render() {
    const { contentEl } = this;
    contentEl.empty();
    const records = this.plugin.uncertainLinks;
    this.titleEl.setText(records.length ? `Review ${records.length} ${records.length === 1 ? 'task' : 'tasks'}` : 'Review tasks');
    if (!records.length) {
      contentEl.createEl('p', { text: 'Every task is linked to its reminder. Nothing to review.' });
      new Setting(contentEl).addButton(b => b.setButtonText('Done').setCta().onClick(() => this.close()));
      return;
    }
    contentEl.createEl('p', { cls: 'reminders-bridge-review-intro', text: records.length === 1
      ? 'This task changed or moved, so Reminders Bridge isn’t sure which task it is now. Its reminder is on hold until you choose.'
      : 'These tasks changed or moved, so Reminders Bridge isn’t sure which tasks they are now. Their reminders are on hold until you choose. Other tasks keep syncing.' });
    for (const record of records) this.renderCard(contentEl.createDiv({ cls: 'reminders-bridge-link-card' }), record);
    new Setting(contentEl).setDesc('Edited a note in the meantime? Check again to update the suggestions.')
      .addButton(b => b.setButtonText('Check again').onClick(async () => { await this.plugin.sync(); this.render(); }));
  }
  private renderCard(card: HTMLElement, record: IdentityRecord) {
    card.empty();
    const picked = this.chosen.get(record.id);
    const suggestion = picked ? undefined : likelyMatch(record, this.plugin.linkCandidates);
    const target = picked ?? suggestion?.target;

    const original = card.createDiv({ cls: 'reminders-bridge-original-task' });
    const originalExists = this.app.vault.getAbstractFileByPath(record.anchor.path) instanceof TFile;
    renderLinkContext(original, record.anchor, 'Task', originalExists ? () => this.openNote(record.anchor) : undefined);

    const current = card.createDiv({ cls: 'reminders-bridge-current-task' });
    if (target) {
      renderLinkContext(current, target.anchor, picked ? 'You chose' : 'Probably now', () => this.openNote(target.anchor));
      if (suggestion?.reasons.length) current.createDiv({ cls: 'reminders-bridge-match-reasons', text: suggestion.reasons.join(' · ') });
    } else {
      current.createDiv({ cls: 'reminders-bridge-context-label', text: 'Probably now' });
      current.createDiv({ cls: 'reminders-bridge-no-match', text: 'No similar task found. If it still exists, choose it. Otherwise mark it as deleted.' });
    }

    let confirmingDelete = false;
    const actions = new Setting(card).setClass('reminders-bridge-card-actions');
    if (target) actions.addButton(b => b.setButtonText('Link to this task').setCta().onClick(() => this.act(record, target)));
    actions.addButton(b => b.setButtonText(target ? 'Choose another…' : 'Choose task…').onClick(() => {
      new TaskLinkPicker(this.plugin, record, value => { this.chosen.set(record.id, value); this.renderCard(card, record); }).open();
    }));
    actions.addButton(b => b.setButtonText('Task was deleted').onClick(() => {
      if (!confirmingDelete) {
        confirmingDelete = true;
        b.setButtonText('Delete its reminder').setWarning();
        actions.setDesc('Its reminder will be removed from Reminders.');
        return;
      }
      void this.act(record);
    }));
  }
  private async act(record: IdentityRecord, target?: Observation) {
    try {
      await this.plugin.chooseLink(record.id, target);
      this.chosen.delete(record.id);
      this.render();
    } catch (e) { new Notice(e instanceof Error ? e.message : String(e)); }
  }
  private async openNote(task: Anchor) {
    const file = this.app.vault.getAbstractFileByPath(task.path);
    if (!(file instanceof TFile)) { new Notice('That note no longer exists.'); return; }
    this.close();
    await this.app.workspace.getLeaf('tab').openFile(file, { eState: { line: task.line } });
  }
  onClose() { this.contentEl.empty(); }
}
class TaskLinkPicker extends SuggestModal<LinkSuggestion> {
  constructor(private plugin: RemindersCompanion, private original: IdentityRecord, private choose: (target: Observation) => void) {
    super(plugin.app);
    this.modalEl.addClass('reminders-bridge-picker');
    this.setPlaceholder('Search task, note, or surrounding text…');
    this.emptyStateText = 'No matching tasks. Try fewer words.';
    // SuggestModal owns and clears contentEl while populating suggestions.
    // Keep the comparison header outside that managed content.
    const context = this.modalEl.createDiv({ cls: 'reminders-bridge-picker-original' });
    renderLinkContext(context, original.anchor, 'Which task is this now?');
    this.modalEl.prepend(context);
    this.setInstructions([{ command: '↑↓', purpose: 'navigate' }, { command: '↵', purpose: 'choose' }, { command: 'esc', purpose: 'cancel' }]);
  }
  getSuggestions(query: string) { return linkSuggestions(this.original, this.plugin.linkCandidates, query); }
  renderSuggestion(item: LinkSuggestion, el: HTMLElement) {
    renderLinkContext(el, item.target.anchor);
    if (item.reasons.length) el.createDiv({ cls: 'reminders-bridge-match-reasons', text: item.reasons.join(' · ') });
  }
  onChooseSuggestion(item: LinkSuggestion) { this.choose(item.target); }
}
class BridgeSettings extends PluginSettingTab {
  constructor(private plugin: RemindersCompanion) { super(plugin.app, plugin); }
  display() {
    const { plugin } = this;
    const container = this.containerEl;
    container.empty(); container.addClass('reminders-bridge-settings');

    // Status first, worded like the Mac app's menu.
    const summary = container.createDiv({ cls: 'reminders-bridge-summary' });
    const text = summary.createDiv({ cls: 'reminders-bridge-summary-text' });
    const title = text.createDiv({ cls: 'reminders-bridge-summary-title' });
    title.createSpan({ cls: `reminders-bridge-dot mod-${plugin.statusTone()}` });
    title.createSpan({ text: plugin.statusLabel() });
    text.createDiv({ cls: 'reminders-bridge-summary-detail', text: plugin.statusDetail() });
    const syncButton = summary.createEl('button', { text: plugin.lastError ? 'Try again' : 'Sync now' });
    syncButton.disabled = !plugin.settings.enabled;
    syncButton.addEventListener('click', async () => { await plugin.sync(); this.display(); });

    new Setting(container).setName('Sync automatically').setDesc('Syncs after edits and when you complete reminders.').addToggle(toggle => toggle.setValue(plugin.settings.enabled).onChange(async enabled => {
      plugin.settings.enabled = enabled; await plugin.configure(); this.display();
    }));

    new Setting(container).setName('Tasks to sync').setHeading();
    const query = container.createEl('textarea', { cls: 'reminders-bridge-query', attr: { rows: '10', spellcheck: 'false', 'aria-label': 'Tasks query' } });
    query.value = plugin.settings.query;
    new Setting(container).setClass('reminders-bridge-query-footer')
      .setDesc('Written like a Tasks query block. Matching tasks are added to Reminders.')
      .addButton(b => {
        b.setButtonText('Save').setCta().setDisabled(true).onClick(async () => {
          plugin.settings.query = query.value; await plugin.configure(); this.display();
        });
        query.addEventListener('input', () => b.setDisabled(query.value === plugin.settings.query));
      });

    const review = plugin.uncertainLinks.length;
    new Setting(container).setName('Task links')
      .setDesc(review
        ? `${review} ${review === 1 ? 'task needs' : 'tasks need'} review. Other tasks keep syncing.`
        : 'Each reminder stays linked to its task. Links are kept in the plugin folder, not in your notes.')
      .addButton(b => { b.setButtonText('Review…').onClick(() => plugin.showLinks()); if (review) b.setCta(); });

    const advanced = container.createEl('details', { cls: 'reminders-bridge-advanced' });
    advanced.createEl('summary', { text: 'Advanced' });
    new Setting(advanced).setName('Run query as if in note').setDesc('Only needed if your query refers to its own note, like {{query.file.folder}}. Leave empty otherwise.').addText(text => text.setPlaceholder('Folder/Note.md').setValue(plugin.settings.queryPath).onChange(async value => {
      plugin.settings.queryPath = value; await plugin.saveData(plugin.settings);
    }));
  }
}
