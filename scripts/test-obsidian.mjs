// Real Obsidian/Tasks integration test. Only runs against the disposable dist/integration-vault.
// Start Obsidian with an isolated profile and --remote-debugging-port=9237; see README.
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
const FIXTURE_QUERY = `not done
filter by function ['project', 'area', 'person'].includes(task.file.property('type'))
(due before in 15 days) OR (scheduled before in 15 days)
path does not include _ meta/templates
path does not include 9 Archive
sort by due
sort by scheduled
sort by priority`;

const port = process.env.OBSIDIAN_TEST_PORT ?? '9237';
const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = pages.find(p => p.url === 'app://obsidian.md/index.html');
assert.ok(page, 'No isolated Obsidian vault page found');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
let sequence = 0;
const pending = new Map();
ws.onmessage = event => {
  const response = JSON.parse(event.data);
  const waiter = pending.get(response.id);
  if (!waiter) return;
  pending.delete(response.id);
  if (response.error || response.result?.exceptionDetails) {
    waiter.reject(new Error(response.error?.message ?? response.result?.exceptionDetails?.exception?.description ?? response.result?.exceptionDetails?.text ?? response.result?.result?.description));
  } else { waiter.resolve(response.result.result.value); }
};
function evaluate(expression) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error('Obsidian integration timed out')); }, 60_000);
    pending.set(id, { resolve: value => { clearTimeout(timeout); resolve(value); }, reject: error => { clearTimeout(timeout); reject(error); } });
    ws.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }));
  });
}
try {
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    ready = await evaluate("typeof app !== 'undefined' && !!app.vault && !!app.plugins?.getPlugin('obsidian-tasks-plugin') && !!app.plugins?.getPlugin('obsidian-reminders-companion')");
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  assert.ok(ready, 'Obsidian and both plugins did not finish loading');
  const path = await evaluate('app.vault.adapter.getBasePath()');
  assert.equal(path, resolve('dist/integration-vault'), 'Refusing to test against anything except this repo’s disposable vault');
  if (await evaluate("app.loadLocalStorage('enableJsInTasksQueries')") !== true) {
    await evaluate(`(async () => {
      app.saveLocalStorage('enableJsInTasksQueries', true);
      await app.plugins.disablePlugin('obsidian-reminders-companion');
      await app.plugins.disablePlugin('obsidian-tasks-plugin');
      await app.plugins.enablePlugin('obsidian-tasks-plugin');
      await app.plugins.enablePlugin('obsidian-reminders-companion');
    })()`);
  }
  const report = await evaluate(`(async () => {
    let bridge = app.plugins.getPlugin('obsidian-reminders-companion');
    const tasks = app.plugins.getPlugin('obsidian-tasks-plugin');
    if (!bridge || !tasks) throw new Error('Enable both plugins in the isolated vault.');
    // The fixture needs function, date, OR and path filters; the plugin default is deliberately simpler.
    const query = ${JSON.stringify(FIXTURE_QUERY)};
    bridge.settings.query = query;
    bridge.settings.enabled = false;
    const a = app.vault.adapter;
    const mailbox = app.vault.configDir + '/plugins/obsidian-reminders-companion/bridge';
    const check = (condition, message) => { if (!condition) throw new Error(message); };
    const pause = ms => new Promise(r => setTimeout(r, ms));
    const until = async (predicate, message) => {
      for (let i = 0; i < 100; i++) { if (await predicate()) return; await pause(100); }
      throw new Error('Timed out: ' + message);
    };
    const sync = async () => {
      await until(() => !bridge.busy && tasks.getState() === 'Warm', 'idle bridge and warm Tasks cache');
      bridge.settings.enabled = true;
      try { await bridge.sync(); } finally { bridge.settings.enabled = false; }
    };
    const snapshot = async () => JSON.parse(await a.read(mailbox + '/snapshot.json'));
    const tomorrow = window.moment().add(1, 'day').format('YYYY-MM-DD');
    const writeNote = async (path, text) => {
      const parts = path.split('/'); parts.pop();
      let folder = '';
      for (const part of parts) { folder = folder ? folder + '/' + part : part; if (!await a.exists(folder)) await app.vault.createFolder(folder); }
      const file = app.vault.getAbstractFileByPath(path);
      if (file) await app.vault.modify(file, text); else await app.vault.create(path, text);
    };
    const report = [];
    try {
      const legacyId = '11111111-1111-4111-a111-111111111111';
      await writeNote('Project.md', '---\\ntype: project\\n---\\n\\n- [ ] <!-- reminders:' + legacyId + ' --> Integration due 📅 ' + tomorrow + '\\n- [ ] Integration scheduled ⏳ ' + tomorrow + '\\n- [ ] Integration recurring 🔁 every day 📅 ' + tomorrow + '\\n- [ ] Outside window 📅 2030-01-01\\n');
      await writeNote('_ meta/templates/Fixture.md', '---\\ntype: project\\n---\\n- [ ] Excluded template 📅 ' + tomorrow + '\\n');
      await writeNote('9 Archive/Fixture.md', '---\\ntype: project\\n---\\n- [ ] Excluded archive 📅 ' + tomorrow + '\\n');
      await writeNote('Excluded.md', '---\\ntype: excluded\\n---\\n- [ ] Excluded type 📅 ' + tomorrow + '\\n');
      await until(() => tasks.getTasks().some(t => t.description.includes('Integration due') && t.dueDate), 'fresh fixture parse');
      await sync();
      await until(() => tasks.getTasks().filter(t => t.description.includes('Integration ')).every(t => !t.originalMarkdown.includes('<!-- reminders:')), 'legacy marker removal');
      await sync();
      let s = await snapshot();
      check(!await a.exists(mailbox + '/error.json'), 'Bridge reported an error');
      check(s.tasks.filter(t => t.selected).length === 3, 'Query should select due, scheduled and recurring only');
      let due = s.tasks.find(t => t.title === 'Integration due');
      check(due?.due === tomorrow && due.selected && due.id === legacyId, 'Migration must retain the original identity and due date');
      check(s.version === 3 && s.pausedTaskIDs.length === 0 && s.pausedTasks.length === 0, 'Clean sidecar snapshot with review details expected');
      const originalNote = await a.read('Project.md');
      check(!originalNote.includes('<!-- reminders:'), 'Sync must leave Markdown free of IDs');
      check(JSON.parse(await a.read(mailbox + '/identities.json')).records.some(r => r.id === legacyId), 'Migrated ID missing from registry');
      check(JSON.parse(await a.read(mailbox + '/identities.json.bak')).records.some(r => r.id === legacyId), 'Migrated ID missing from backup');
      report.push('PASS real legacy migration, stable sidecar IDs and clean Markdown');
      check(s.tasks.find(t => t.title === 'Integration scheduled')?.scheduled === tomorrow, 'Scheduled date lost');
      const ordered = await bridge.tasks.select(bridge.settings.query, bridge.settings.queryPath);
      check(JSON.stringify(s.tasks.filter(t => t.selected).map(t => t.title)) === JSON.stringify([...ordered.selected].map(t => t.description)), 'Snapshot must preserve the actual Tasks query order');
      report.push('PASS real function/date/OR/path query, metadata preservation and query ordering');
      const firstTimestamp = s.generatedAt;
      await pause(30); await sync(); s = await snapshot();
      check(s.generatedAt > firstTimestamp, 'REGRESSION: repeated snapshot replacement failed');
      check(await a.read('Project.md') === originalNote, 'Ordinary sync must not rewrite Markdown');
      report.push('PASS repeated atomic snapshot replacement');
      const send = async (task, completed, expectedCompleted) => {
        const id = crypto.randomUUID();
        await a.write(mailbox + '/commands/' + id + '.json', JSON.stringify({ version: 1, id, taskId: task.id, completed, expectedCompleted }));
        await sync();
        await until(async () => await a.exists(mailbox + '/acks/' + id + '.json'), 'command acknowledgement');
        const ack = JSON.parse(await a.read(mailbox + '/acks/' + id + '.json'));
        check(!ack.error, 'Completion rejected: ' + ack.error);
        await a.remove(mailbox + '/commands/' + id + '.json'); await a.remove(mailbox + '/acks/' + id + '.json');
      };
      await send(due, true, false);
      await until(() => tasks.getTasks().some(t => t.description === 'Integration due' && t.isDone), 'completed cache');
      await sync(); s = await snapshot();
      check(s.tasks.find(t => t.id === due.id)?.completed && !s.tasks.find(t => t.id === due.id)?.selected, 'Completed task must stay linked outside not-done query');
      await send(due, false, true);
      await until(() => tasks.getTasks().some(t => t.description === 'Integration due' && !t.isDone), 'reopened cache');
      await sync(); s = await snapshot();
      check(s.tasks.find(t => t.id === due.id)?.selected, 'Reopened task should rejoin the query');
      report.push('PASS completion/reopening through the real Tasks toggle interface');
      const recurring = s.tasks.find(t => t.title === 'Integration recurring');
      await send(recurring, true, false);
      await until(() => tasks.getTasks().filter(t => t.description.includes('Integration recurring')).length === 2, 'recurrence successor');
      await sync();
      s = await snapshot();
      const repeated = s.tasks.filter(t => t.title === 'Integration recurring');
      check(repeated.length === 2 && new Set(repeated.map(t => t.id)).size === 2, 'Recurring instances need distinct IDs');
      check(repeated.find(t => t.id === recurring.id)?.completed, 'Completed instance must retain original identity');
      check(!(await a.read('Project.md')).includes('<!-- reminders:'), 'Completion/recurrence must not insert IDs');
      report.push('PASS recurring instance identity separation');
      await writeNote('DeleteRecurring.md', '---\\ntype: excluded\\n---\\n- [ ] Organize padel for next sunday 🔁 every week on Sunday 🏁 delete 📅 2026-10-04\\n');
      await until(() => tasks.getTasks().some(t => t.taskLocation.path === 'DeleteRecurring.md'), 'delete recurrence fixture');
      bridge.settings.query = 'path includes DeleteRecurring.md';
      await sync(); s = await snapshot();
      const deleteRecurring = s.tasks.find(t => t.path === 'DeleteRecurring.md');
      await send(deleteRecurring, true, false);
      await until(() => tasks.getTasks().some(t => t.taskLocation.path === 'DeleteRecurring.md' && t.dueDate?.format('YYYY-MM-DD') === '2026-10-11'), 'delete recurrence successor');
      await sync(); s = await snapshot();
      const deleteInstances = s.tasks.filter(t => t.path === 'DeleteRecurring.md');
      check(deleteInstances.length === 1 && !deleteInstances[0].completed && deleteInstances[0].due === '2026-10-11', 'Delete recurrence must leave only the next unfinished instance');
      check(!(await a.read('DeleteRecurring.md')).includes('2026-10-04'), 'Delete recurrence must remove the original instance');
      check(!s.pausedTaskIDs.includes(deleteRecurring.id), 'Deleted recurring instance must not need manual review');
      report.push('PASS recurring delete completion advances to next Sunday');
      // Simulate interruption on either side of the Markdown write, then reload
      // the plugin so recovery must use the durable deletion journal.
      for (const alreadyWritten of [false, true]) {
        const oldTask = (await snapshot()).tasks.find(t => t.path === 'DeleteRecurring.md');
        const before = await a.read('DeleteRecurring.md');
        const after = before.replace(oldTask.due, window.moment(oldTask.due).add(7, 'days').format('YYYY-MM-DD'));
        const commandId = crypto.randomUUID();
        await bridge.persistRegistry({ ...bridge.registry, pendingDeletion: { taskId: oldTask.id, commandId, path: 'DeleteRecurring.md', before, after } });
        if (alreadyWritten) await writeNote('DeleteRecurring.md', after);
        await bridge.saveData(bridge.settings);
        await app.plugins.disablePlugin('obsidian-reminders-companion');
        await app.plugins.enablePlugin('obsidian-reminders-companion');
        bridge = app.plugins.getPlugin('obsidian-reminders-companion');
        await sync();
        check(await a.read('DeleteRecurring.md') === after, 'Deletion recovery must apply the successor exactly once');
        check(!JSON.parse(await a.read(mailbox + '/acks/' + commandId + '.json')).error, 'Recovered deletion must acknowledge success');
        await until(() => tasks.getTasks().some(t => t.originalMarkdown === after.trim().split('\\n').at(-1)), 'recovered successor cache');
        await sync(); s = await snapshot();
        check(!s.pausedTaskIDs.includes(oldTask.id) && !s.tasks.some(t => t.id === oldTask.id), 'Recovery must retire the deleted identity');
        await a.remove(mailbox + '/acks/' + commandId + '.json');
      }
      bridge.settings.query = query;
      report.push('PASS deletion journal recovery before and after Markdown write');
      // Restart the companion: identities must survive solely in plugin data.
      bridge.settings.enabled = false;
      await bridge.saveData(bridge.settings);
      await app.plugins.disablePlugin('obsidian-reminders-companion');
      await app.plugins.enablePlugin('obsidian-reminders-companion');
      const restarted = app.plugins.getPlugin('obsidian-reminders-companion');
      restarted.settings.enabled = true;
      await restarted.sync();
      check((await snapshot()).tasks.some(t => t.id === due.id), 'Restart lost sidecar identity');
      restarted.settings.enabled = false;
      // Continue below with the new instance.
      bridge = restarted;
      report.push('PASS plugin restart restores sidecar identities');
      await writeNote('IdentityExperiment.md', '---\\ntype: project\\n---\\n# Original context\\n- [ ] Identity experiment 📅 ' + tomorrow);
      await until(() => tasks.getTasks().some(t => t.description === 'Identity experiment'), 'identity experiment parse');
      await sync();
      const experiment = (await snapshot()).tasks.find(t => t.title === 'Identity experiment');
      check(experiment, 'Experiment task was not assigned a sidecar ID');
      await app.vault.delete(app.vault.getAbstractFileByPath('IdentityExperiment.md'));
      await writeNote('RelinkTarget.md', '---\\ntype: project\\n---\\n# Different context\\n- [ ] Entirely rewritten 📅 ' + tomorrow);
      await until(() => !tasks.getTasks().some(t => t.description === 'Identity experiment') && tasks.getTasks().some(t => t.description === 'Entirely rewritten'), 'ambiguous move parse');
      await sync(); s = await snapshot();
      check(s.pausedTaskIDs.includes(experiment.id), 'Uncertain identity must be paused, not dropped');
      check(s.pausedTasks.find(t => t.id === experiment.id)?.title.includes('Identity experiment'), 'Uncertain snapshot must identify the task by name');
      const reviewDialog = bridge.showLinks();
      const reviewCard = document.querySelector('.reminders-bridge-link-card');
      check(reviewCard?.textContent.includes('Identity experiment') && reviewCard.textContent.includes('Choose task'), 'Review dialog must show the task and an actionable choice');
      check(reviewCard.textContent.includes('Original context') && reviewCard.textContent.includes('IdentityExperiment.md'), 'Original task context must remain visible');
      const linkButton = () => [...reviewCard.querySelectorAll('button')].find(b => b.textContent === 'Link to this task');
      check(!linkButton(), 'Without a likely match, linking must require an explicit target');
      [...reviewCard.querySelectorAll('button')].find(b => b.textContent === 'Choose task…').click();
      await until(() => document.querySelector('.reminders-bridge-picker .prompt-input'), 'task picker opens');
      const picker = document.querySelector('.reminders-bridge-picker');
      check(picker.textContent.includes('Identity experiment') && picker.textContent.includes('Original context'), 'Picker must keep the original visible');
      const search = picker.querySelector('.prompt-input');
      search.value = 'rewritten Different'; search.dispatchEvent(new Event('input', { bubbles: true }));
      await until(() => picker.querySelector('.suggestion-item')?.textContent.includes('Entirely rewritten'), 'search by task and surrounding context');
      check(picker.querySelector('.suggestion-item').textContent.includes('RelinkTarget.md'), 'Candidate note must be visible');
      picker.querySelector('.suggestion-item').click();
      await until(() => reviewCard.querySelector('.reminders-bridge-current-task')?.textContent.includes('Entirely rewritten'), 'selected target comparison');
      check(linkButton() && !linkButton().disabled, 'Explicit selection must offer linking');
      check((await snapshot()).pausedTaskIDs.includes(experiment.id), 'Selecting a suggestion must not relink automatically');
      reviewDialog.close();
      report.push('PASS contextual relinking picker, multi-field search and explicit comparison');
      check(!s.tasks.some(t => t.title === 'Entirely rewritten'), 'Unmatched newcomer must not create a duplicate reminder');
      check(s.tasks.some(t => t.id === due.id), 'Unaffected identities must keep syncing');
      const heldCommand = crypto.randomUUID();
      await a.write(mailbox + '/commands/' + heldCommand + '.json', JSON.stringify({ version: 1, id: heldCommand, taskId: experiment.id, completed: true, expectedCompleted: false }));
      await sync();
      check(!await a.exists(mailbox + '/acks/' + heldCommand + '.json'), 'Uncertain completion must remain pending');
      check(!tasks.getTasks().find(t => t.description === 'Entirely rewritten').isDone, 'Uncertain command must not modify Markdown');
      const target = bridge.linkCandidates.find(o => o.anchor.path === 'RelinkTarget.md');
      check(target, 'Relinking UI must offer the unclaimed target');
      await bridge.chooseLink(experiment.id, target);
      await sync();
      await until(() => tasks.getTasks().some(t => t.description === 'Entirely rewritten' && t.isDone), 'relinked completion parse');
      await sync(); s = await snapshot();
      check(s.tasks.find(t => t.id === experiment.id)?.completed, 'Explicit relink must preserve UUID and apply held completion');
      await a.remove(mailbox + '/commands/' + heldCommand + '.json');
      await a.remove(mailbox + '/acks/' + heldCommand + '.json');
      await app.vault.delete(app.vault.getAbstractFileByPath('RelinkTarget.md'));
      await until(() => !tasks.getTasks().some(t => t.taskLocation.path === 'RelinkTarget.md'), 'deleted relink target cache');
      await sync();
      await bridge.chooseLink(experiment.id);
      await sync();
      check(!(await snapshot()).pausedTaskIDs.includes(experiment.id), 'Explicit forget must release the deleted identity');
      report.push('PASS uncertain links freeze commands, explicit relink preserves UUID, explicit forget removes identity');
      const file = app.vault.getAbstractFileByPath('Project.md');
      await app.vault.process(file, text => text.replace('type: project', 'type: excluded'));
      await until(() => tasks.getTasks().filter(t => t.taskLocation.path === 'Project.md').every(t => t.file.property('type') === 'excluded'), 'property cache');
      await sync(); s = await snapshot();
      check(s.tasks.every(t => !t.selected), 'Property changes must update selection');
      report.push('PASS query departure after frontmatter changes');
      const beforeInvalid = s.generatedAt;
      bridge.settings.query = 'this is not a valid Tasks instruction';
      await sync();
      check(await a.exists(mailbox + '/error.json'), 'Invalid query must report an error');
      check((await snapshot()).generatedAt === beforeInvalid, 'Invalid query must not replace snapshot with empty results');
      report.push('PASS invalid queries fail closed');
      // Leave a healthy, selected fixture for the native EventKit test that follows.
      bridge.settings.query = query;
      await app.vault.process(file, text => text.replace('type: excluded', 'type: project'));
      await until(() => tasks.getTasks().filter(t => t.taskLocation.path === 'Project.md').every(t => t.file.property('type') === 'project'), 'restored property cache');
      await sync();
      check((await snapshot()).tasks.filter(t => t.selected).length === 3, 'Native fixture must have three selected tasks');
      return report;
    } finally {
      bridge.settings.query = query;
      bridge.settings.enabled = true;
      await bridge.sync();
    }
  })()`);
  console.log(report.join('\n'));
} finally { ws.close(); }
