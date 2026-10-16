// SPDX-License-Identifier: MIT
// Run with: node scripts/tests/smoke_ember_recall_worker.mjs
// Execute the shipped plugin in the existing JavaScriptCore worker. No build,
// app installation or user data is involved; only host JSON APIs are mocked.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const root = new URL('../../', import.meta.url);
const executable = fileURLToPath(new URL('.build/arm64-apple-macosx/debug/EmberPluginWorker', root));
const source = await readFile(new URL('Examples/Plugins/EmberRecall.hwattakplugin/main.js', root), 'utf8');
const clone = value => JSON.parse(JSON.stringify(value));
const same = (first, second) => JSON.stringify(first) === JSON.stringify(second);
const quote = 'Retrieval practice strengthens memory through repeated recall.';
const question = 'What strengthens memory?';
const answer = 'SECRET_ANSWER: Repeated retrieval practice.';

class WorkerHost {
  constructor(storage) {
    this.storage = storage;
    this.commands = [];
    this.views = [];
    this.calls = [];
    this.navigations = [];
    this.outgoing = [];
    this.awaitingIdle = false;
    this.open = false;
    this.failure = null;
    this.exited = false;
    this.stopping = false;
    this.stderr = '';
    this.context = { apiVersion: 1, windowID: 'window-smoke', workspaceID: 'workspace-smoke', tabID: 'tab-smoke', hasDocument: true };
    this.info = { name: 'Worker smoke study.pdf', pageNumber: 7, pageCount: 30,
      revision: 'revision-smoke', workspaceID: this.context.workspaceID, tabID: this.context.tabID, copyAllowed: true };
    this.child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.on('error', error => { this.failure = error; });
    this.child.stdin.on('error', error => { if (!this.stopping) this.failure = error; });
    this.child.stderr.on('data', data => { this.stderr += data; });
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on('line', line => {
      try { this.receive(JSON.parse(line)); }
      catch (error) { this.failure = error; }
    });
    this.exitPromise = new Promise(resolve => this.child.on('close', (code, signal) => {
      this.exited = true;
      if (!this.stopping) this.failure = new Error(`Worker exited: ${code ?? signal}; ${this.stderr}`);
      resolve({ code, signal });
    }));
  }

  get view() { return this.views.at(-1); }
  get rendered() { return JSON.stringify(this.view); }

  send(message) {
    this.outgoing.push(message);
    this.pump();
  }

  pump() {
    if (this.awaitingIdle || !this.outgoing.length || this.failure || this.exited) return;
    this.awaitingIdle = true;
    this.child.stdin.write(`${JSON.stringify(this.outgoing.shift())}\n`);
  }

  receive(message) {
    if (message.type === 'idle') {
      assert.ok(this.awaitingIdle, 'worker must emit one idle per dispatched message');
      this.awaitingIdle = false;
      this.pump();
      return;
    }
    if (message.type === 'error') throw new Error(`JavaScriptCore: ${message.message}`);
    assert.equal(message.type, 'request');
    this.calls.push(clone(message));
    const result = this.api(message.method, message.params);
    this.send({ type: 'response', id: message.id, result });
  }

  api(method, params) {
    switch (method) {
      case 'ui.commands': this.commands = clone(params.commands); return null;
      case 'ui.render': {
        const view = params.view;
        assert.ok(Buffer.byteLength(JSON.stringify(view), 'utf8') <= 64 * 1024);
        assert.ok((view.items?.length ?? 0) <= 100);
        assert.ok((view.fields?.length ?? 0) <= 12);
        assert.ok((view.actions?.length ?? 0) <= 24);
        for (const field of view.fields ?? []) assert.ok(Buffer.byteLength(field.value ?? '', 'utf8') <= 4096);
        this.views.push(clone(view));
        return null;
      }
      case 'ui.open': this.open = true; return null;
      case 'ui.close': this.open = false; return null;
      case 'app.getContext': return clone(this.context);
      case 'document.getInfo': return clone(this.info);
      case 'document.getSelection': return { text: quote, revision: this.info.revision, truncated: false };
      case 'document.getPageText': return { text: `Study introduction. ${quote} End of lesson.`,
        revision: this.info.revision, truncated: false, pageNumber: this.info.pageNumber };
      case 'workspace.listDocuments': return { documents: [{ ...clone(this.info), active: true, workspaceName: 'Smoke study' }], truncated: false };
      case 'workspace.search': return { documents: [{ workspaceID: this.info.workspaceID, tabID: this.info.tabID,
        name: this.info.name, matches: [{ pageNumber: this.info.pageNumber, snippet: quote }] }], partial: false, scannedDocuments: 1 };
      case 'workspace.navigate': this.navigations.push(clone(params)); return clone(params);
      case 'storage.get': return { value: clone(this.storage.value) };
      case 'storage.compareAndSet': {
        assert.ok(Buffer.byteLength(JSON.stringify(params.value), 'utf8') <= 64 * 1024);
        if (!same(this.storage.value, params.expected)) return { saved: false };
        this.storage.value = clone(params.value);
        this.storage.writes++;
        return { saved: true };
      }
      case 'runtime.error': throw new Error(`Plugin callback: ${params.message}`);
      default: throw new Error(`Unexpected host API: ${method}`);
    }
  }

  async waitFor(predicate, label) {
    const deadline = Date.now() + 4000;
    while (!predicate()) {
      if (this.failure) throw this.failure;
      assert.ok(Date.now() < deadline, `Timed out: ${label}; stderr=${this.stderr}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    if (this.failure) throw this.failure;
  }

  async flush() {
    await this.waitFor(() => !this.awaitingIdle && this.outgoing.length === 0, 'worker idle');
    // stdout is read asynchronously; give the final idle a full event-loop turn.
    await new Promise(resolve => setImmediate(resolve));
    if (this.failure) throw this.failure;
  }

  async start() {
    this.send({ type: 'load', source });
    await this.waitFor(() => this.commands.length === 3, 'three commands');
    await this.flush();
    this.send({ type: 'event', name: 'load', payload: {} });
    this.send({ type: 'event', name: 'app.ready', payload: clone(this.context) });
    await this.waitFor(() => this.views.length > 0, 'initial panel');
    await this.flush();
  }

  async command(id) {
    assert.ok(this.commands.some(command => command.id === id), `Command is registered: ${id}`);
    const count = this.views.length;
    this.send({ type: 'command', id });
    await this.waitFor(() => this.views.length > count, `command ${id}`);
    await this.flush();
  }

  async action(id, values = {}) {
    assert.ok(this.view.actions.some(action => action.id === id), `Action is visible: ${id}`);
    const count = this.views.length;
    this.send({ type: 'event', name: 'view.action', payload: { id, values } });
    await this.waitFor(() => this.views.length > count, `action ${id}`);
    await this.flush();
  }

  async stop() {
    this.stopping = true;
    this.child.stdin.end();
    const timeout = setTimeout(() => this.child.kill('SIGKILL'), 2000);
    try { return await this.exitPromise; }
    finally { clearTimeout(timeout); this.lines.close(); }
  }
}

const storage = { value: null, writes: 0 };
let host;
try {
  host = new WorkerHost(storage);
  await host.start();
  assert.deepEqual(host.commands.map(command => command.id).sort(), ['recall-create', 'recall-library', 'recall-today']);
  console.log('PASS actual JavaScriptCore worker loads shipped source and registers three commands');

  await host.command('recall-create');
  assert.equal(host.view.fields.find(field => field.id === 'answer').value, quote);
  assert.equal(storage.writes, 0);
  // No view.input event: a click must save the authoritative native values.
  await host.action('save', { question, answer });
  assert.equal(storage.value.cards.length, 1);
  assert.equal(storage.value.cards[0].question, question);
  assert.equal(storage.value.cards[0].answer, answer);
  assert.equal(storage.value.cards[0].quote, quote);
  assert.equal(storage.value.cards[0].source.pageNumber, 7);
  console.log('PASS selected text creates a card using action.values without input events');

  await host.command('recall-today');
  assert.ok(host.rendered.includes(question));
  assert.ok(!host.rendered.includes(answer));
  assert.ok(!host.rendered.includes(quote));
  await host.action('reveal');
  assert.ok(host.rendered.includes(answer));
  assert.ok(host.rendered.includes(quote));
  await host.action('hide');
  assert.ok(!host.rendered.includes(answer));
  assert.ok(!host.rendered.includes(quote));
  console.log('PASS today review hides both answer and quote; reveal and hide work');

  const sourceStart = host.calls.length;
  await host.action('source');
  assert.deepEqual(host.calls.slice(sourceStart).filter(call => call.method.startsWith('workspace.')).map(call => call.method),
    ['workspace.listDocuments', 'workspace.search', 'workspace.navigate']);
  assert.deepEqual(host.navigations.at(-1), { workspaceID: 'workspace-smoke', tabID: 'tab-smoke', pageNumber: 7 });
  console.log('PASS source navigation verifies the listed tab and quote before moving');

  await host.action('reveal');
  const beforeGrade = Date.now();
  await host.action('known');
  const card = clone(storage.value.cards[0]);
  assert.equal(card.intervalDays, 1);
  assert.equal(card.reviews, 1);
  assert.equal(card.lapses, 0);
  assert.ok(card.dueAt > beforeGrade);
  assert.ok(host.rendered.includes('지금 복습할 카드가 없습니다'));
  const due = new Date(card.dueAt);
  assert.equal(due.getHours(), 0);
  assert.equal(due.getMinutes(), 0);
  console.log('PASS known grade persists the next local midnight and removes the due card');

  assert.equal((await host.stop()).code, 0);
  host = new WorkerHost(storage);
  await host.start();
  await host.command('recall-library');
  assert.ok(host.rendered.includes(question));
  assert.ok(!host.rendered.includes(answer));
  assert.deepEqual(storage.value.cards[0], card);
  await host.action('reveal');
  assert.ok(host.rendered.includes(answer));
  console.log('PASS a fresh JavaScriptCore process restores the shared stored deck and review schedule');
  console.log(`Ember Recall worker smoke: 6 checks passed; ${storage.writes} storage writes.`);
} finally {
  if (host && !host.exited) await host.stop();
}
