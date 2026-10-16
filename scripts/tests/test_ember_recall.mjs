// SPDX-License-Identifier: MIT
// Run with: node --test scripts/tests/test_ember_recall.mjs
// These tests execute the shipped extension, with the public Ember API mocked.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const entry = new URL('../../Examples/Plugins/EmberRecall.hwattakplugin/main.js', import.meta.url);
const pluginSource = await readFile(entry, 'utf8');
const NO_OVERRIDE = Symbol('no override');
const START = Date.parse('2026-10-16T12:00:00.000Z');
const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const bytes = value => Buffer.byteLength(JSON.stringify(value), 'utf8');
const apiError = code => Object.assign(new Error(code), { code });

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
  return value;
}

function store(value = null) {
  return { value: clone(value), writes: [], conflicts: 0, beforeCAS: null, failure: null };
}

function fixedDate(clock) {
  return class extends Date {
    constructor(...args) { super(...(args.length ? args : [clock.now])); }
    static now() { return clock.now; }
  };
}

function validateView(view) {
  assert.ok(bytes(view) <= 64 * 1024, 'render must respect the native 64 KiB limit');
  assert.ok((view.actions?.length ?? 0) <= 24, 'native panel supports at most 24 actions');
  assert.ok((view.items?.length ?? 0) <= 100, 'native panel supports at most 100 items');
  assert.ok((view.fields?.length ?? 0) <= 12, 'native panel supports at most 12 fields');
  const actions = view.actions ?? [];
  assert.equal(new Set(actions.map(action => action.id)).size, actions.length);
  for (const action of actions) {
    assert.match(action.id, /^[A-Za-z0-9._-]{1,80}$/);
    assert.ok(action.label.length <= 160);
  }
  for (const field of view.fields ?? []) {
    assert.ok(Buffer.byteLength(field.value ?? '', 'utf8') <= 4096, 'field exceeds native 4 KiB limit');
  }
}

async function harness({ storage = store(), now = START, name = 'French lesson.pdf',
  text = 'La mémoire s’améliore avec la répétition.', windowID = 'window-one' } = {}) {
  const clock = { now };
  const state = {
    context: { apiVersion: 1, windowID, workspaceID: 'workspace-one', tabID: 'tab-one', hasDocument: true },
    info: { name, pageNumber: 7, pageCount: 30, revision: 'revision-one', documentID: 'document-one',
      workspaceID: 'workspace-one', tabID: 'tab-one', copyAllowed: true },
    selection: { text, truncated: false, revision: 'revision-one', pageNumber: 7 },
    page: { text: `Lesson notes. ${text} End of lesson.`, truncated: false, revision: 'revision-one', pageNumber: 7 },
    documents: [], search: null, calls: [], views: [], navigations: [], open: false, hook: null,
  };
  state.documents = [{ ...clone(state.info), active: true, workspaceName: 'Study' }];
  state.search = { documents: [{ workspaceID: state.info.workspaceID, tabID: state.info.tabID,
    name, matches: [{ pageNumber: 7, snippet: state.page.text }] }], partial: false, scannedDocuments: 1 };
  const commands = new Map();
  const handlers = new Map();
  const cleanups = [];
  async function call(method, params = {}) {
    state.calls.push({ method, params: clone(params) });
    if (state.hook) {
      const result = await state.hook(method, params, state);
      if (result !== NO_OVERRIDE) return clone(result);
    }
    switch (method) {
      case 'app.getContext': return clone(state.context);
      case 'document.getInfo': return clone(state.info);
      case 'document.getSelection': return clone(state.selection);
      case 'document.getPageText': return clone(state.page);
      case 'workspace.listDocuments': return { documents: clone(state.documents), truncated: false };
      case 'workspace.search': return clone(state.search);
      case 'workspace.navigate':
        state.navigations.push(clone(params));
        return clone(params);
      case 'storage.get':
        if (storage.failure === 'get') throw apiError('STORAGE_FAILED');
        return { value: clone(storage.sortedKeys ? sorted(storage.value) : storage.value) };
      case 'storage.compareAndSet': {
        if (storage.failure === 'write') throw apiError('STORAGE_FAILED');
        assert.ok(bytes(params.expected) <= 64 * 1024, 'CAS expected value exceeds storage limit');
        assert.ok(bytes(params.value) <= 64 * 1024, 'CAS replacement exceeds storage limit');
        if (storage.beforeCAS) storage.beforeCAS(params, storage);
        if (JSON.stringify(sorted(params.expected)) !== JSON.stringify(sorted(storage.value))) {
          storage.conflicts++;
          return { saved: false };
        }
        storage.value = clone(storage.sortedKeys ? sorted(params.value) : params.value);
        storage.writes.push(clone(params.value));
        return { saved: true };
      }
      case 'storage.set': throw new Error('Recall must merge writes with storage.compareAndSet');
      default: throw new Error(`Unexpected public API call: ${method}`);
    }
  }
  const ember = {
    apiVersion: 1,
    call,
    commands: { register(command) {
      assert.ok(!commands.has(command.id), `duplicate command ${command.id}`);
      commands.set(command.id, command);
      return () => commands.delete(command.id);
    } },
    on(name, handler) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name).push(handler);
      return () => handlers.set(name, handlers.get(name).filter(item => item !== handler));
    },
    dispose(callback) { cleanups.push(callback); return () => {}; },
    ui: {
      async render(view) { validateView(view); state.views.push(clone(view)); },
      async open() { state.open = true; },
      async close() { state.open = false; },
    },
  };
  const context = vm.createContext({ ember, Date: fixedDate(clock), console });
  vm.runInContext(pluginSource, context, { filename: entry.pathname, timeout: 1000 });
  const result = {
    state, storage, clock, commands,
    get view() { return state.views.at(-1); },
    get rendered() { return JSON.stringify(state.views.at(-1)); },
    async emit(name, payload = {}) {
      for (const handler of handlers.get(name) ?? []) await handler(clone(payload));
    },
    async command(id) {
      assert.ok(commands.has(id), `missing command ${id}`);
      await commands.get(id).run();
    },
    async action(id, values = {}) { await this.emit('view.action', { id, values }); },
    dispose() { for (const cleanup of cleanups) cleanup(); },
  };
  await result.emit('load');
  await result.emit('app.ready', state.context);
  return result;
}

const fields = host => Object.fromEntries((host.view?.fields ?? []).map(field => [field.id, field.value]));
const actionIDs = host => (host.view?.actions ?? []).map(action => action.id);
const cards = host => host.storage.value?.cards ?? [];
const onlyCard = host => {
  assert.equal(cards(host).length, 1);
  return cards(host)[0];
};

function card(overrides = {}) {
  return {
    id: 'card-seeded', question: 'How does memory improve?', answer: 'SECRET_ANSWER_42',
    quote: 'SECRET_QUOTE_73',
    source: { windowID: 'window-one', workspaceID: 'workspace-one', tabID: 'tab-one',
      name: 'French lesson.pdf', pageNumber: 7, pageCount: 30 },
    createdAt: START - 1000, updatedAt: START - 1000, dueAt: START,
    intervalDays: 0, reviews: 0, lapses: 0, ...overrides,
  };
}

async function createCard(host, values = {}) {
  await host.command('recall-create');
  await host.action('save', { question: 'How does memory improve?', answer: fields(host).answer, ...values });
}

function nextMidnight(now, days) {
  const date = new Date(now);
  date.setHours(0, 0, 0, 0);
  date.setDate(date.getDate() + days);
  return date.getTime();
}

test('registers the three public commands and creates an editable card from the selected sentence', async () => {
  const host = await harness();
  for (const id of ['recall-create', 'recall-today', 'recall-library']) assert.ok(host.commands.has(id));
  await host.command('recall-create');
  assert.equal(fields(host).answer, host.state.selection.text);
  assert.ok(Object.hasOwn(fields(host), 'question'));
  assert.equal(host.storage.writes.length, 0, 'opening the editor must not create a card');
  await host.action('save', { question: 'What improves memory?', answer: 'Active recall and repetition.' });
  const saved = onlyCard(host);
  assert.equal(host.storage.value.version, 1);
  assert.equal(saved.question, 'What improves memory?');
  assert.equal(saved.answer, 'Active recall and repetition.');
  assert.equal(saved.quote, host.state.selection.text);
  assert.equal(saved.source.pageNumber, 7);
  assert.equal(saved.source.name, 'French lesson.pdf');
  assert.equal(saved.createdAt, START);
  assert.equal(saved.dueAt, START);
  assert.equal(saved.intervalDays, 0);
  assert.equal(saved.reviews, 0);
  assert.equal(saved.lapses, 0);
});

test('cancel leaves no card and saved cards survive a fresh worker', async () => {
  const storage = store();
  const first = await harness({ storage });
  await first.command('recall-create');
  await first.action('cancel');
  assert.equal(storage.writes.length, 0);
  await createCard(first, { question: 'Persistent question', answer: 'Persistent answer' });
  const second = await harness({ storage });
  await second.command('recall-today');
  assert.match(second.rendered, /Persistent question/);
  assert.doesNotMatch(second.rendered, /Persistent answer/);
});

test('input events do not rerender the editor and action values win over debounced input', async () => {
  const host = await harness();
  await host.command('recall-create');
  const renderCount = host.state.views.length;
  await host.emit('view.input', { id: 'question', value: 'Older debounced question' });
  await host.emit('view.input', { id: 'answer', value: 'Older answer' });
  assert.equal(host.state.views.length, renderCount, 'rendering every input would replace native field contents');
  await host.emit('page.changed', host.state.context);
  await host.emit('selection.changed', host.state.context);
  assert.equal(host.state.views.length, renderCount, 'background reading events must preserve the active draft');
  await host.action('save', { question: 'Latest field question', answer: 'Latest field answer' });
  assert.equal(onlyCard(host).question, 'Latest field question');
  assert.equal(onlyCard(host).answer, 'Latest field answer');
});

test('commands issued while composing preserve native input by leaving draft fields unrendered', async () => {
  const host = await harness();
  await host.command('recall-create');
  const renderCount = host.state.views.length;
  // The native field may contain a keystroke whose debounce has not fired yet.
  // Re-rendering here would restore stale JS values over that keystroke.
  for (const command of ['recall-today', 'recall-library', 'recall-create']) {
    await host.command(command);
    assert.equal(host.state.views.length, renderCount, `${command} must leave the current fields intact`);
  }
  await host.action('save', { question: 'Unsent native question', answer: 'Unsent native answer' });
  assert.equal(onlyCard(host).question, 'Unsent native question');
  assert.equal(onlyCard(host).answer, 'Unsent native answer');
});

test('the review front hides both answer and original quotation, and hide restores the front', async () => {
  const host = await harness({ storage: store({ version: 1, cards: [card()] }) });
  await host.command('recall-today');
  assert.match(host.rendered, /How does memory improve/);
  assert.doesNotMatch(host.rendered, /SECRET_ANSWER_42|SECRET_QUOTE_73/);
  assert.ok(actionIDs(host).includes('reveal'));
  await host.action('reveal');
  assert.match(host.rendered, /SECRET_ANSWER_42/);
  assert.ok(actionIDs(host).includes('hide'));
  await host.action('hide');
  assert.doesNotMatch(host.rendered, /SECRET_ANSWER_42|SECRET_QUOTE_73/);
  assert.equal(host.storage.writes.length, 0, 'turning the card does not modify its schedule');
});

test('today shows due cards and excludes cards whose due time has not arrived', async () => {
  const host = await harness({ storage: store({ version: 1, cards: [
    card({ id: 'future', question: 'FUTURE_QUESTION', dueAt: START + 60_000 }),
    card({ id: 'due', question: 'DUE_QUESTION', dueAt: START }),
  ] }) });
  await host.command('recall-today');
  assert.match(host.rendered, /DUE_QUESTION/);
  assert.doesNotMatch(host.rendered, /FUTURE_QUESTION|SECRET_ANSWER_42|SECRET_QUOTE_73/);
  const empty = await harness({ storage: store({ version: 1, cards: [card({ dueAt: START + 1 })] }) });
  await empty.command('recall-today');
  assert.ok(!actionIDs(empty).includes('reveal'));
});

test('again schedules ten minutes later and cannot be applied twice by a repeated click', async () => {
  const host = await harness({ storage: store({ version: 1, cards: [card()] }) });
  await host.command('recall-today');
  await host.action('reveal');
  await Promise.all([host.action('again'), host.action('again')]);
  const saved = onlyCard(host);
  assert.equal(saved.dueAt, START + 10 * 60 * 1000);
  assert.equal(saved.intervalDays, 0);
  assert.equal(saved.lapses, 1);
  assert.equal(host.storage.writes.length, 1);
});

test('known advances through 1, 3, 7, 14 and 30 day intervals at local midnight', async () => {
  const host = await harness({ storage: store({ version: 1, cards: [card()] }) });
  let reviews = 0;
  for (const interval of [1, 3, 7, 14, 30, 30]) {
    const reviewedAt = host.clock.now;
    await host.command('recall-today');
    await host.action('reveal');
    await host.action('known');
    const saved = onlyCard(host);
    assert.equal(saved.intervalDays, interval);
    assert.equal(saved.dueAt, nextMidnight(reviewedAt, interval));
    assert.equal(saved.reviews, ++reviews);
    host.clock.now = saved.dueAt;
  }
});

test('grading requires a revealed answer and repeated known clicks produce one review', async () => {
  const host = await harness({ storage: store({ version: 1, cards: [card()] }) });
  await host.command('recall-today');
  await host.action('known');
  await host.action('again');
  assert.equal(host.storage.writes.length, 0);
  await host.action('reveal');
  await Promise.all([host.action('known'), host.action('known')]);
  assert.equal(onlyCard(host).reviews, 1);
  assert.equal(host.storage.writes.length, 1);
});

test('editing keeps the original quotation and source while saving the submitted question and answer', async () => {
  const original = card();
  const host = await harness({ storage: store({ version: 1, cards: [original] }) });
  await host.command('recall-library');
  await host.action('edit');
  assert.equal(fields(host).question, original.question);
  assert.equal(fields(host).answer, original.answer);
  host.clock.now += 1000;
  await host.action('save', { question: 'Edited prompt', answer: 'Edited response' });
  const saved = onlyCard(host);
  assert.equal(saved.id, original.id);
  assert.equal(saved.question, 'Edited prompt');
  assert.equal(saved.answer, 'Edited response');
  assert.equal(saved.quote, original.quote);
  assert.deepEqual(saved.source, original.source);
  assert.equal(saved.createdAt, original.createdAt);
  assert.equal(saved.updatedAt, host.clock.now);
});

test('deleting requires the confirmation action and cancellation preserves the card', async () => {
  const host = await harness({ storage: store({ version: 1, cards: [card()] }) });
  await host.command('recall-library');
  await host.action('delete');
  assert.equal(cards(host).length, 1);
  assert.equal(host.storage.writes.length, 0);
  assert.ok(actionIDs(host).includes('confirm-delete'));
  await host.action('back');
  assert.equal(cards(host).length, 1);
  await host.action('delete');
  await host.action('confirm-delete');
  assert.equal(cards(host).length, 0);
});

test('concurrent windows merge independently created cards through atomic CAS', async () => {
  const storage = store();
  const one = await harness({ storage, windowID: 'window-one' });
  const two = await harness({ storage, windowID: 'window-two' });
  await Promise.all([one.command('recall-create'), two.command('recall-create')]);
  await Promise.all([
    one.action('save', { question: 'Question from window one', answer: 'Answer one' }),
    two.action('save', { question: 'Question from window two', answer: 'Answer two' }),
  ]);
  assert.equal(cards(one).length, 2);
  assert.deepEqual(cards(one).map(item => item.question).sort(), ['Question from window one', 'Question from window two']);
  assert.equal(new Set(cards(one).map(item => item.id)).size, 2);
  assert.ok(storage.conflicts >= 1, 'the test must exercise the CAS conflict path');
});

test('native sortedKeys storage preserves immediate grading, editing and deletion after a save', async () => {
  for (const operation of ['grade', 'edit', 'delete']) {
    const storage = store();
    storage.sortedKeys = true;
    const host = await harness({ storage });
    await createCard(host);
    assert.deepEqual(Object.keys(storage.value).sort(), Object.keys(storage.value), 'simulate native sorted JSON keys');
    if (operation === 'grade') {
      await host.action('reveal');
      await host.action('known');
      assert.equal(onlyCard(host).reviews, 1);
    } else if (operation === 'edit') {
      await host.action('edit');
      await host.action('save', { question: 'Edited after native serialization', answer: 'New answer' });
      assert.equal(onlyCard(host).question, 'Edited after native serialization');
    } else {
      await host.action('delete');
      await host.action('confirm-delete');
      assert.equal(cards(host).length, 0);
    }
  }
});

test('two windows reviewing the same snapshot apply one grade without overwriting the winning schedule', async () => {
  const storage = store({ version: 1, cards: [card()] });
  const one = await harness({ storage });
  const two = await harness({ storage, windowID: 'window-two' });
  await Promise.all([one.command('recall-today'), two.command('recall-today')]);
  await Promise.all([one.action('reveal'), two.action('reveal')]);
  await Promise.all([one.action('known'), two.action('known')]);
  assert.equal(onlyCard(one).reviews, 1);
  assert.equal(onlyCard(one).intervalDays, 1);
  assert.equal(storage.writes.length, 1);
});

test('a stale editor cannot overwrite a review completed in another window', async () => {
  const storage = store({ version: 1, cards: [card()] });
  const editor = await harness({ storage });
  const reviewer = await harness({ storage, windowID: 'window-two' });
  await editor.command('recall-library');
  await editor.action('edit');
  await reviewer.command('recall-today');
  await reviewer.action('reveal');
  await reviewer.action('known');
  await editor.action('save', { question: 'Stale edit', answer: 'Keep my draft' });
  assert.equal(onlyCard(editor).question, 'How does memory improve?');
  assert.equal(onlyCard(editor).reviews, 1);
  assert.equal(storage.writes.length, 1);
  assert.equal(fields(editor).question, 'Stale edit');
  assert.equal(fields(editor).answer, 'Keep my draft');
});

test('bounded CAS retries preserve the draft and allow a later retry', async () => {
  const storage = store({ version: 1, cards: [] });
  const host = await harness({ storage });
  await host.command('recall-create');
  let revision = 0;
  storage.beforeCAS = (_params, shared) => { shared.value = { ...shared.value, conflictStamp: ++revision }; };
  await host.action('save', { question: 'Retry after contention', answer: 'Preserve this answer' });
  assert.equal(storage.writes.length, 0);
  assert.ok(storage.conflicts > 0 && storage.conflicts <= 8, 'CAS contention must stop after a bounded retry count');
  assert.equal(fields(host).question, 'Retry after contention');
  storage.beforeCAS = null;
  await host.action('save', fields(host));
  assert.equal(onlyCard(host).question, 'Retry after contention');
});

test('repeated save clicks create one card and do not duplicate its ID', async () => {
  const host = await harness();
  await host.command('recall-create');
  const values = { question: 'One card only', answer: 'One answer only' };
  await Promise.all([host.action('save', values), host.action('save', values)]);
  assert.equal(cards(host).length, 1);
  assert.equal(host.storage.writes.length, 1);
});

test('storage write failures retain the draft for retry without claiming a saved card', async () => {
  const host = await harness();
  await host.command('recall-create');
  host.storage.failure = 'write';
  await host.action('save', { question: 'Unsaved question', answer: 'Unsaved answer' });
  assert.equal(cards(host).length, 0);
  assert.equal(host.storage.writes.length, 0);
  assert.deepEqual(fields(host), { question: 'Unsaved question', answer: 'Unsaved answer' });
  host.storage.failure = null;
  await host.action('save', fields(host));
  assert.equal(onlyCard(host).question, 'Unsaved question');
});

test('storage read failures never overwrite an unreadable library', async () => {
  const storage = store({ version: 1, cards: [card()] });
  const host = await harness({ storage });
  await host.command('recall-create');
  storage.failure = 'get';
  await host.action('save', { question: 'Do not overwrite', answer: 'Keep original card' });
  assert.equal(storage.writes.length, 0);
  assert.equal(onlyCard(host).id, 'card-seeded');
});

test('empty selections and missing documents do not offer a usable card editor', async () => {
  const empty = await harness({ text: '   \n\t' });
  await empty.command('recall-create');
  assert.ok(!actionIDs(empty).includes('save'));
  assert.equal(empty.storage.writes.length, 0);
  const missing = await harness();
  missing.state.context.hasDocument = false;
  await missing.command('recall-create');
  assert.ok(!actionIDs(missing).includes('save'));
  assert.equal(missing.storage.writes.length, 0);
});

test('copy permission failure is surfaced without creating or leaking a draft', async () => {
  const host = await harness();
  host.state.hook = method => {
    if (method === 'document.getSelection') throw apiError('PERMISSION_DENIED');
    return NO_OVERRIDE;
  };
  await host.command('recall-create');
  assert.ok(!actionIDs(host).includes('save'));
  assert.equal(host.storage.writes.length, 0);
  assert.doesNotMatch(host.rendered, /La mémoire/);
});

test('a page or revision change during capture refuses an incorrectly attributed quote', async () => {
  for (const mutation of [
    state => { state.info.pageNumber = 8; state.page.pageNumber = 8; },
    state => { state.info.revision = 'revision-two'; state.page.revision = 'revision-two'; },
    state => { state.context.tabID = 'tab-two'; },
  ]) {
    const host = await harness();
    host.state.hook = (method, _params, state) => {
      if (method === 'document.getSelection') mutation(state);
      return NO_OVERRIDE;
    };
    await host.command('recall-create');
    assert.ok(!actionIDs(host).includes('save'));
    assert.equal(host.storage.writes.length, 0);
  }
});

test('a selection absent from the current page is not attributed to that page', async () => {
  const host = await harness();
  host.state.page.text = 'Unrelated text from another PDF page.';
  await host.command('recall-create');
  assert.ok(!actionIDs(host).includes('save'));
  assert.equal(host.storage.writes.length, 0);
});

test('oversized and truncated selections are refused without silently changing the quoted source', async () => {
  for (const configure of [
    state => { state.selection.text = '가'.repeat(1001); state.page.text = state.selection.text; },
    state => { state.selection.truncated = true; },
  ]) {
    const host = await harness();
    configure(host.state);
    await host.command('recall-create');
    assert.ok(!actionIDs(host).includes('save'));
    assert.equal(host.storage.writes.length, 0);
  }
});

test('the source action verifies the open tab and quotation before navigating to its saved page', async () => {
  const host = await harness();
  await createCard(host);
  await host.command('recall-today');
  await host.action('source');
  assert.deepEqual(host.state.navigations, [{ workspaceID: 'workspace-one', tabID: 'tab-one', pageNumber: 7 }]);
  const searched = host.state.calls.find(call => call.method === 'workspace.search');
  assert.ok(searched, 'source text must be checked before navigation');
  assert.ok(Buffer.byteLength(searched.params.query, 'utf8') <= 1024);
});

test('a context event during source verification invalidates the search proof before navigation', async () => {
  const host = await harness();
  await createCard(host);
  await host.command('recall-today');
  host.state.hook = async method => {
    if (method === 'workspace.search') await host.emit('page.changed', host.state.context);
    return NO_OVERRIDE;
  };
  await host.action('source');
  assert.equal(host.state.navigations.length, 0);
});

test('a closed source or a source from another app window is explained without navigating', async () => {
  const original = await harness();
  await createCard(original);
  original.state.documents = [];
  await original.command('recall-today');
  await original.action('source');
  assert.equal(original.state.navigations.length, 0);
  assert.match(original.rendered, /열|닫|open|closed/i);
  const other = await harness({ storage: original.storage, windowID: 'window-two' });
  await other.command('recall-today');
  await other.action('source');
  assert.equal(other.state.navigations.length, 0);
});

test('a reused tab with the same file name and page count cannot navigate without matching quotation evidence', async () => {
  const host = await harness();
  await createCard(host);
  host.state.search = { documents: [], partial: false, scannedDocuments: 1 };
  await host.command('recall-today');
  await host.action('source');
  assert.equal(host.state.navigations.length, 0);
  assert.match(host.rendered, /원문|확인|source|verify/i);
});

test('a matching quote in a different tab or page is never used as source navigation evidence', async () => {
  for (const mutate of [
    result => { result.documents[0].tabID = 'different-tab'; },
    result => { result.documents[0].matches[0].pageNumber = 8; },
  ]) {
    const host = await harness();
    await createCard(host);
    mutate(host.state.search);
    await host.command('recall-today');
    await host.action('source');
    assert.equal(host.state.navigations.length, 0);
  }
});

test('source metadata mismatches refuse navigation even when search returns the original quote', async () => {
  for (const mutate of [
    document => { document.name = 'Different lesson.pdf'; },
    document => { document.pageCount = 31; },
    document => { document.workspaceID = 'workspace-two'; },
  ]) {
    const host = await harness();
    await createCard(host);
    mutate(host.state.documents[0]);
    await host.command('recall-today');
    await host.action('source');
    assert.equal(host.state.navigations.length, 0);
  }
});

test('oversized or empty question and answer input cannot bypass card field limits', async () => {
  for (const values of [
    { question: '', answer: 'Answer' },
    { question: 'Question', answer: ' \n ' },
    { question: 'Q'.repeat(241), answer: 'Answer' },
    { question: 'Question', answer: '😀'.repeat(1001) },
  ]) {
    const host = await harness();
    await host.command('recall-create');
    await host.action('save', values);
    for (const saved of cards(host)) {
      assert.ok([...saved.question].length <= 240);
      assert.ok(Buffer.byteLength(saved.question, 'utf8') <= 960);
      assert.ok([...saved.answer].length <= 1000);
      assert.ok(Buffer.byteLength(saved.answer, 'utf8') <= 4000);
      assert.ok(saved.question.trim());
      assert.ok(saved.answer.trim());
    }
    if (!values.question.trim() || !values.answer.trim()) assert.equal(cards(host).length, 0);
  }
});

test('library capacity preserves existing cards and respects the 60,000 byte envelope', async () => {
  const existing = Array.from({ length: 50 }, (_value, index) => card({ id: `card-${index}`, question: `Existing ${index}` }));
  const host = await harness({ storage: store({ version: 1, cards: existing }) });
  await createCard(host, { question: 'Over capacity', answer: 'Do not evict anything' });
  assert.equal(cards(host).length, 50);
  assert.deepEqual(cards(host).map(item => item.id).sort(), existing.map(item => item.id).sort());
  assert.ok(bytes(host.storage.value) <= 60000);
  const large = Array.from({ length: 12 }, (_value, index) => card({ id: `large-${index}`,
    question: `Existing ${index}`, answer: '가'.repeat(850), quote: '나'.repeat(650) }));
  const nearLimit = await harness({ storage: store({ version: 1, cards: large }) });
  assert.ok(bytes(nearLimit.storage.value) < 60000);
  await createCard(nearLimit, { question: 'Fits card count but exceeds byte limit', answer: '다'.repeat(1000) });
  assert.ok(bytes(nearLimit.storage.value) <= 60000);
  assert.ok(cards(nearLimit).length >= large.length, 'capacity must not silently evict existing cards');
  for (const write of nearLimit.storage.writes) assert.ok(bytes(write) <= 60000);
});
