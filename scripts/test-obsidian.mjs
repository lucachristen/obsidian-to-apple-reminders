// Real Obsidian/Tasks integration test. Only runs against the disposable dist/integration-vault.
// Start Obsidian with an isolated profile and --remote-debugging-port=9237; see README.
import assert from 'node:assert/strict';
import { resolve } from 'node:path';

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
    waiter.reject(new Error(response.error?.message ?? response.result.result.description));
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
    const bridge = app.plugins.getPlugin('obsidian-reminders-companion');
    const tasks = app.plugins.getPlugin('obsidian-tasks-plugin');
    if (!bridge || !tasks) throw new Error('Enable both plugins in the isolated vault.');
    const query = bridge.settings.query;
    bridge.settings.enabled = false;
    const a = app.vault.adapter;
    const mailbox = app.vault.configDir + '/plugins/obsidian-reminders-companion/bridge';
    const check = (condition, message) => { if (!condition) throw new Error(message); };
    const pause = ms => new Promise(r => setTimeout(r, ms));
    const until = async (predicate, message) => {
      for (let i = 0; i < 100; i++) { if (await predicate()) return; await pause(100); }
      throw new Error('Timed out: ' + message);
    };
    const sync = async () => { bridge.settings.enabled = true; try { await bridge.sync(); } finally { bridge.settings.enabled = false; } };
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
      await writeNote('Project.md', '---\\ntype: project\\n---\\n\\n- [ ] Integration due 📅 ' + tomorrow + '\\n- [ ] Integration scheduled ⏳ ' + tomorrow + '\\n- [ ] Integration recurring 🔁 every day 📅 ' + tomorrow + '\\n- [ ] Outside window 📅 2030-01-01\\n');
      await writeNote('_ meta/templates/Fixture.md', '---\\ntype: project\\n---\\n- [ ] Excluded template 📅 ' + tomorrow + '\\n');
      await writeNote('9 Archive/Fixture.md', '---\\ntype: project\\n---\\n- [ ] Excluded archive 📅 ' + tomorrow + '\\n');
      await writeNote('Excluded.md', '---\\ntype: excluded\\n---\\n- [ ] Excluded type 📅 ' + tomorrow + '\\n');
      await until(() => tasks.getTasks().some(t => t.description === 'Integration due' && t.dueDate), 'fresh fixture parse');
      await sync();
      await until(() => tasks.getTasks().filter(t => t.description.includes('Integration ') && t.originalMarkdown.includes('<!-- reminders:')).length === 3, 'identity insertion');
      await sync();
      let s = await snapshot();
      check(!await a.exists(mailbox + '/error.json'), 'Bridge reported an error');
      check(s.tasks.filter(t => t.selected).length === 3, 'Query should select due, scheduled and recurring only');
      let due = s.tasks.find(t => t.title === 'Integration due');
      check(due?.due === tomorrow && due.selected, 'REGRESSION: ID insertion broke the real Tasks due-date parser');
      check(s.tasks.find(t => t.title === 'Integration scheduled')?.scheduled === tomorrow, 'Scheduled date lost');
      report.push('PASS real function/date/OR/path query and metadata preservation');
      const firstTimestamp = s.generatedAt;
      await pause(30); await sync(); s = await snapshot();
      check(s.generatedAt > firstTimestamp, 'REGRESSION: repeated snapshot replacement failed');
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
      await until(() => tasks.getTasks().some(t => t.originalMarkdown.includes(due.id) && t.isDone), 'completed cache');
      await sync(); s = await snapshot();
      check(s.tasks.find(t => t.id === due.id)?.completed && !s.tasks.find(t => t.id === due.id)?.selected, 'Completed task must stay linked outside not-done query');
      await send(due, false, true);
      await until(() => tasks.getTasks().some(t => t.originalMarkdown.includes(due.id) && !t.isDone), 'reopened cache');
      await sync(); s = await snapshot();
      check(s.tasks.find(t => t.id === due.id)?.selected, 'Reopened task should rejoin the query');
      report.push('PASS completion/reopening through the real Tasks toggle interface');
      const recurring = s.tasks.find(t => t.title === 'Integration recurring');
      await send(recurring, true, false);
      await until(() => tasks.getTasks().filter(t => t.description.includes('Integration recurring')).length === 2, 'recurrence successor');
      await sync();
      await until(() => tasks.getTasks().filter(t => t.description.includes('Integration recurring') && t.originalMarkdown.includes('<!-- reminders:')).length === 2, 'successor identity');
      await sync(); s = await snapshot();
      const repeated = s.tasks.filter(t => t.title === 'Integration recurring');
      check(repeated.length === 2 && new Set(repeated.map(t => t.id)).size === 2, 'Recurring instances need distinct IDs');
      check(repeated.find(t => t.id === recurring.id)?.completed, 'Completed instance must retain original identity');
      report.push('PASS recurring instance identity separation');
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
