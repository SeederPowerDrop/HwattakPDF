// SPDX-License-Identifier: MIT
// Ember Recall uses only the public EmberPDF SDK. No timers, network or files.
const MAX_CARDS = 50;
const MAX_STORAGE_BYTES = 60000;
const AGAIN_MINUTES = 10;
let deck = { version: 1, cards: [] };
let mode = 'home';
let selectedID = null;
let revealed = false;
let draft = null;
let deleting = null;
let status = '';
let contextEpoch = 0;
let sequence = 0;
let queue = Promise.resolve();

function problem(message) { throw new Error(message); }
function normalize(text) {
  return text.normalize('NFKC').replace(/\u00ad/g, '').replace(/-\s*\n\s*/g, '')
    .replace(/\s+/g, ' ').trim().toLowerCase();
}
function utf8Bytes(text) {
  let count = 0;
  for (const character of text) {
    const point = character.codePointAt(0);
    count += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return count;
}
function boundedText(value, characters, bytes) {
  return typeof value === 'string' && !value.includes('\u0000') &&
    Array.from(value).length <= characters && utf8Bytes(value) <= bytes;
}
function validTime(value) { return Number.isSafeInteger(value) && value >= 0 && value <= 8640000000000000; }
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}
function sameCard(first, second) { return JSON.stringify(canonical(first)) === JSON.stringify(canonical(second)); }
function validSource(source) {
  return source && ['windowID', 'workspaceID', 'tabID'].every(key =>
    typeof source[key] === 'string' && /^[A-Za-z0-9-]{1,80}$/.test(source[key])) &&
    boundedText(source.name, 256, 1024) && source.name.trim() &&
    Number.isInteger(source.pageNumber) && source.pageNumber >= 1 &&
    Number.isInteger(source.pageCount) && source.pageCount >= source.pageNumber;
}
function validCard(card) {
  return card && typeof card.id === 'string' && /^[A-Za-z0-9-]{1,80}$/.test(card.id) &&
    boundedText(card.question, 240, 960) && card.question.trim() &&
    boundedText(card.answer, 1000, 4000) && card.answer.trim() &&
    boundedText(card.quote, 1000, 4000) && card.quote.trim() && validSource(card.source) &&
    ['createdAt', 'updatedAt', 'dueAt'].every(key => validTime(card[key])) &&
    Number.isInteger(card.intervalDays) && card.intervalDays >= 0 && card.intervalDays <= 30 &&
    ['reviews', 'lapses'].every(key => Number.isSafeInteger(card[key]) && card[key] >= 0);
}
function readValue(value) {
  if (value === null) return { version: 1, cards: [] };
  if (!value || value.version !== 1 || !Array.isArray(value.cards) ||
      value.cards.length > MAX_CARDS || !value.cards.every(validCard) ||
      new Set(value.cards.map(card => card.id)).size !== value.cards.length) {
    problem('저장된 카드 형식을 읽을 수 없습니다. 기존 데이터는 그대로 보관했습니다.');
  }
  return value;
}
async function refresh() {
  const saved = await ember.call('storage.get');
  deck = readValue(saved.value);
}
async function mutate(transform) {
  // Re-read and merge on every attempt: each app window shares this storage.
  for (let attempt = 0; attempt < 4; attempt++) {
    const saved = await ember.call('storage.get');
    const current = readValue(saved.value);
    const replacement = transform(current);
    // Foundation also escapes slashes. Budget for its JSON representation.
    if (replacement.cards.length > MAX_CARDS ||
        utf8Bytes(JSON.stringify(replacement).replace(/\//g, '\\/')) > MAX_STORAGE_BYTES) {
      problem('카드 저장 공간이 가득 찼습니다. 카드함에서 필요 없는 카드를 삭제하거나 답을 줄여 주세요. 기존 카드는 유지됩니다.');
    }
    const result = await ember.call('storage.compareAndSet', { expected: saved.value, value: replacement });
    if (result.saved) { deck = replacement; return; }
  }
  problem('다른 창에서 카드를 변경하고 있습니다. 입력은 유지했으니 잠시 후 다시 시도해 주세요.');
}
function eligibleCards() {
  const cards = mode === 'today' ? deck.cards.filter(card => card.dueAt <= Date.now()) : deck.cards.slice();
  return cards.sort((a, b) => a.dueAt - b.dueAt || a.createdAt - b.createdAt || a.id.localeCompare(b.id));
}
function currentCard() {
  const cards = eligibleCards();
  return cards.find(card => card.id === selectedID) || cards[0] || null;
}
function dateLabel(timestamp) {
  const date = new Date(timestamp);
  return `${date.getFullYear()}.${date.getMonth() + 1}.${date.getDate()}`;
}
function dueLabel(card) {
  if (card.dueAt <= Date.now()) return '지금 복습';
  const date = new Date(card.dueAt);
  return `${dateLabel(card.dueAt)} ${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}
const action = (id, label) => ({ id, label });
async function render() {
  const view = { title: 'Ember Recall · 복습 카드', text: '', fields: [], items: [], actions: [] };
  if (mode === 'edit' && draft) {
    view.text = `${draft.original ? '카드 수정' : '선택문으로 카드 만들기'}\n${draft.source.name} · ${draft.source.pageNumber}페이지\n질문은 240자, 답은 1,000자까지 입력할 수 있습니다.`;
    view.fields = [
      { id: 'question', label: '질문', value: draft.question },
      { id: 'answer', label: '답 · 선택문을 내 말로 고쳐도 좋아요', value: draft.answer }
    ];
    view.items = [{ title: '선택한 원문', detail: draft.quote }];
    view.actions = [action('save', '카드 저장'), action('cancel', '작성 취소'), action('close', '패널 닫기 · 초안 유지')];
  } else if (mode === 'delete' && deleting) {
    view.text = '이 카드를 삭제할까요? 저장된 복습 기록도 함께 삭제됩니다.';
    view.items = [{ title: deleting.question, detail: `${deleting.source.name} · ${deleting.source.pageNumber}페이지` }];
    view.actions = [action('confirm-delete', '이 카드 삭제'), action('back', '돌아가기')];
  } else if (mode === 'today' || mode === 'library') {
    const cards = eligibleCards();
    const card = currentCard();
    selectedID = card ? card.id : null;
    if (card) {
      view.text = `${mode === 'today' ? '오늘 복습' : '카드함'} · ${cards.findIndex(item => item.id === card.id) + 1}/${cards.length}\n${card.source.name} · ${card.source.pageNumber}페이지\n다음 복습: ${dueLabel(card)} · 복습 ${card.reviews}회`;
      view.items = [{ title: '질문', detail: card.question }];
      if (revealed) {
        view.items.push({ title: '답', detail: card.answer });
        if (card.quote !== card.answer) view.items.push({ title: '선택한 원문', detail: card.quote });
      } else view.text += '\n답을 떠올린 뒤 ‘답 보기’를 눌러 주세요.';
      view.actions = [action(revealed ? 'hide' : 'reveal', revealed ? '답 숨기기' : '답 보기')];
      if (mode === 'today' && revealed) view.actions.push(
        action('again', '다시 복습 · 10분 뒤'), action('known', '알겠음 · 다음 복습일로'));
      view.actions.push(action('source', '원문 페이지로 이동'));
      if (cards.length > 1) view.actions.push(action('previous', '이전 카드'), action('next', '다음 카드'));
      view.actions.push(action('edit', '이 카드 수정'), action('delete', '이 카드 삭제'));
    } else {
      view.text = mode === 'today'
        ? '지금 복습할 카드가 없습니다. 새 카드를 만들거나 잠시 후 새로고침해 주세요.\n‘다시 복습’한 카드는 10분 뒤부터 표시됩니다.'
        : '아직 카드가 없습니다. PDF에서 한 페이지 안의 문장을 선택해 첫 카드를 만들어 보세요.';
    }
    view.actions.push(action('create', '선택문으로 카드 만들기'),
      action(mode === 'today' ? 'library' : 'today', mode === 'today' ? '전체 카드함' : '오늘 복습'),
      action('refresh', '새로고침'), action('close', '계속 읽기'));
  } else {
    const due = deck.cards.filter(card => card.dueAt <= Date.now()).length;
    view.text = `저장한 카드 ${deck.cards.length}개 · 지금 복습 ${due}개\nPDF에서 한 페이지 안의 문장을 선택해 질문과 답을 만들어 보세요. 카드는 이 Mac에 저장됩니다.`;
    view.actions = [action('create', '선택문으로 카드 만들기'), action('today', '오늘 복습'),
      action('library', '전체 카드함'), action('close', '계속 읽기')];
  }
  if (status) view.text += `\n\n${status}`;
  await ember.ui.render(view);
}
function sequential(operation) {
  queue = queue.then(operation).catch(async error => {
    const message = String(error && error.message || '');
    status = error && error.code === 'CONTEXT_CHANGED'
      ? '문서나 선택 영역이 바뀌었습니다. 현재 페이지에서 문장을 다시 선택해 주세요. 초안은 유지됩니다.'
      : /[가-힣]/.test(message) ? message
      : '작업을 완료하지 못했습니다. 플러그인 권한과 문서 상태를 확인한 뒤 다시 시도해 주세요. 저장 전 입력은 유지됩니다.';
    try { await render(); await ember.ui.open(); } catch (_) { /* Host owns permission revocation. */ }
  });
  return queue;
}
function preserveDraft() {
  if (!draft) return false;
  status = '작성 중인 카드가 있습니다. 먼저 저장하거나 작성을 취소해 주세요.';
  return true;
}
async function createCard() {
  if (preserveDraft()) return false;
  await refresh();
  if (deck.cards.length >= MAX_CARDS) problem('카드는 최대 50개까지 보관합니다. 카드함에서 필요 없는 카드를 삭제해 주세요.');
  const epoch = contextEpoch;
  const before = await ember.call('app.getContext');
  if (!before.hasDocument) problem('먼저 PDF를 열고 문장을 선택해 주세요.');
  const info = await ember.call('document.getInfo');
  if (!info.copyAllowed) problem('이 PDF는 텍스트 복사를 허용하지 않습니다.');
  const selection = await ember.call('document.getSelection');
  const quote = typeof selection.text === 'string' ? selection.text.trim() : '';
  if (!quote) problem('PDF에서 복습할 문장을 먼저 선택해 주세요.');
  if (!normalize(quote)) problem('복습할 글자가 포함된 문장을 선택해 주세요.');
  if (selection.truncated || !boundedText(quote, 1000, 4000)) problem('한 페이지 안에서 1,000자 이내의 짧은 문장을 선택해 주세요.');
  const page = await ember.call('document.getPageText', {});
  const latest = await ember.call('document.getInfo');
  const after = await ember.call('app.getContext');
  if (epoch !== contextEpoch || !after.hasDocument ||
      ['windowID', 'workspaceID', 'tabID'].some(key => before[key] !== after[key]) ||
      info.revision !== selection.revision || info.revision !== page.revision || info.revision !== latest.revision ||
      info.pageNumber !== latest.pageNumber || page.pageNumber !== info.pageNumber) {
    problem('문서나 페이지가 바뀌었습니다. 현재 페이지에서 문장을 다시 선택해 주세요.');
  }
  // Selection v1 has no page index. Verify the quote against the current page
  // instead of silently saving the viewport's page for an off-screen selection.
  if (!normalize(page.text).includes(normalize(quote))) {
    problem('선택문을 현재 페이지에서 확인할 수 없습니다. 해당 페이지로 이동해 한 페이지 안의 문장을 다시 선택해 주세요.');
  }
  const source = { windowID: before.windowID, workspaceID: before.workspaceID, tabID: before.tabID,
    name: info.name, pageNumber: info.pageNumber, pageCount: info.pageCount };
  if (!validSource(source)) problem('현재 문서의 출처 정보를 확인할 수 없습니다.');
  draft = { question: '이 문장의 핵심 내용을 설명해 보세요.', answer: quote, quote, source,
    original: null, returnMode: mode, returnID: selectedID };
  mode = 'edit'; status = ''; revealed = false;
  return true;
}
function captureFields(values) {
  if (!draft || !values || typeof values !== 'object') return;
  for (const key of ['question', 'answer']) {
    if (typeof values[key] === 'string') draft[key] = values[key];
  }
}
async function saveCard(values) {
  if (mode !== 'edit' || !draft) return;
  // The native input debounce is shared. The button snapshot is authoritative.
  captureFields(values);
  const question = draft.question.trim();
  const answer = draft.answer.trim();
  if (!question || !answer) problem('질문과 답을 모두 입력해 주세요.');
  if (!boundedText(question, 240, 960)) problem('질문을 240자 이내로 줄여 주세요.');
  if (!boundedText(answer, 1000, 4000)) problem('답을 1,000자 이내로 줄여 주세요.');
  const now = Date.now();
  const card = draft.original
    ? { ...draft.original, question, answer, updatedAt: now }
    : { id: `c${now.toString(36)}-${(++sequence).toString(36)}-${Math.random().toString(36).slice(2, 12)}`,
      question, answer, quote: draft.quote, source: draft.source, createdAt: now, updatedAt: now,
      dueAt: now, intervalDays: 0, reviews: 0, lapses: 0 };
  const original = draft.original;
  await mutate(current => {
    if (!original) {
      if (current.cards.some(item => item.id === card.id)) return current;
      return { version: 1, cards: [...current.cards, card] };
    }
    const existing = current.cards.find(item => item.id === original.id);
    if (!sameCard(existing, original)) problem('다른 창에서 이 카드를 수정하거나 복습했습니다. 입력을 복사해 둔 뒤 취소하고 카드를 다시 열어 주세요.');
    return { version: 1, cards: current.cards.map(item => item.id === card.id ? card : item) };
  });
  draft = null; selectedID = card.id; mode = original ? 'library' : 'today'; revealed = false;
  status = '카드를 저장했습니다.';
}
function knownSchedule(card, now) {
  const intervalDays = card.intervalDays < 1 ? 1 : card.intervalDays < 3 ? 3 : card.intervalDays < 7 ? 7 : card.intervalDays < 14 ? 14 : 30;
  const due = new Date(now);
  // Local calendar days, including DST transitions; never UTC string slicing.
  due.setHours(0, 0, 0, 0);
  due.setDate(due.getDate() + intervalDays);
  return { intervalDays, dueAt: due.getTime() };
}
async function grade(kind) {
  if (mode !== 'today' || !revealed) return;
  const card = currentCard();
  if (!card) return;
  const now = Date.now();
  const schedule = kind === 'again' ? { intervalDays: 0, dueAt: now + AGAIN_MINUTES * 60000 } : knownSchedule(card, now);
  const updated = { ...card, ...schedule, updatedAt: now, reviews: card.reviews + 1,
    lapses: card.lapses + (kind === 'again' ? 1 : 0) };
  await mutate(current => {
    const existing = current.cards.find(item => item.id === card.id);
    if (!sameCard(existing, card)) problem('다른 창에서 이 카드가 변경되었습니다. 새로고침 후 다시 복습해 주세요.');
    return { version: 1, cards: current.cards.map(item => item.id === card.id ? updated : item) };
  });
  revealed = false; selectedID = null;
  status = kind === 'again' ? '10분 뒤에 다시 복습합니다.' : `다음 복습은 ${dateLabel(updated.dueAt)}입니다.`;
}
async function navigateSource() {
  const card = currentCard();
  if (!card) return;
  const epoch = contextEpoch;
  const source = card.source;
  const context = await ember.call('app.getContext');
  const hint = `${source.name} · ${source.pageNumber}페이지`;
  if (context.windowID !== source.windowID) problem(`이 카드의 원문은 다른 창에서 열었거나 앱을 다시 실행했습니다. 원문을 직접 열어 주세요: ${hint}`);
  const listed = await ember.call('workspace.listDocuments');
  const target = listed.documents.find(item => item.workspaceID === source.workspaceID && item.tabID === source.tabID);
  if (!target || target.name !== source.name || target.pageCount !== source.pageCount || target.pageCount < source.pageNumber) {
    problem(`원문 탭이 닫혔거나 문서가 바뀌었습니다. 원문을 직접 열어 주세요: ${hint}`);
  }
  // Prove the saved quote is still on that page before moving an inactive tab.
  // Names alone cannot distinguish different files or a replaced tab.
  const query = Array.from(normalize(card.quote)).slice(0, 100).join('');
  const search = await ember.call('workspace.search', { query });
  const match = search.documents.find(item => item.workspaceID === source.workspaceID && item.tabID === source.tabID);
  if (!match || !match.matches.some(item => item.pageNumber === source.pageNumber && normalize(item.snippet).includes(query))) {
    problem(`열린 문서에서 원문을 확인하지 못했습니다. 검색 범위가 제한되었거나 내용이 바뀌었을 수 있습니다. 원문을 직접 확인해 주세요: ${hint}`);
  }
  if (epoch !== contextEpoch) problem('원문을 확인하는 동안 문서 상태가 바뀌었습니다. 원문 이동을 다시 눌러 주세요.');
  await ember.call('workspace.navigate', { workspaceID: source.workspaceID, tabID: source.tabID, pageNumber: source.pageNumber });
  status = `원문으로 이동했습니다: ${hint}`;
}
async function openMode(nextMode) {
  // Command buttons carry no field snapshot. Re-rendering an existing draft
  // here could reset keystrokes still waiting for the native 250 ms debounce.
  if (preserveDraft()) { await ember.ui.open(); return; }
  await refresh(); mode = nextMode; selectedID = null; revealed = false; status = ''; deleting = null;
  await render(); await ember.ui.open();
}
ember.commands.register({ id: 'recall-create', title: 'Ember Recall · 선택문으로 카드 만들기', run: () => sequential(async () => {
  if (await createCard()) await render();
  await ember.ui.open();
}) });
ember.commands.register({ id: 'recall-today', title: 'Ember Recall · 오늘 복습', run: () => sequential(() => openMode('today')) });
ember.commands.register({ id: 'recall-library', title: 'Ember Recall · 전체 카드함', run: () => sequential(() => openMode('library')) });

ember.on('app.ready', () => sequential(async () => { await refresh(); await render(); }));
// Context events never re-render fields or discard a draft while the user types.
for (const event of ['workspace.changed', 'document.changed', 'documents.changed', 'page.changed', 'selection.changed']) {
  ember.on(event, () => { contextEpoch++; });
}
ember.on('view.input', ({ id, value }) => {
  if (mode === 'edit' && draft && ['question', 'answer'].includes(id) && typeof value === 'string') draft[id] = value;
});
ember.on('view.action', ({ id, values }) => sequential(async () => {
  status = '';
  if (id === 'close') { captureFields(values); await ember.ui.close(); return; }
  if (id === 'create') { captureFields(values); await createCard(); }
  else if (id === 'today' || id === 'library') { await openMode(id); return; }
  else if (id === 'save') await saveCard(values);
  else if (id === 'cancel' && draft) {
    mode = draft.returnMode === 'edit' ? 'home' : draft.returnMode;
    selectedID = draft.returnID; draft = null; revealed = false;
  } else if (id === 'reveal' && (mode === 'today' || mode === 'library')) revealed = true;
  else if (id === 'hide') revealed = false;
  else if (id === 'again' || id === 'known') await grade(id);
  else if (id === 'source' && (mode === 'today' || mode === 'library')) await navigateSource();
  else if ((id === 'next' || id === 'previous') && (mode === 'today' || mode === 'library')) {
    const cards = eligibleCards();
    const index = cards.findIndex(card => card.id === selectedID);
    selectedID = cards.length ? cards[(Math.max(index, 0) + (id === 'next' ? 1 : cards.length - 1)) % cards.length].id : null;
    revealed = false;
  } else if (id === 'edit' && (mode === 'today' || mode === 'library')) {
    const card = currentCard();
    if (card) { draft = { ...card, original: card, returnMode: mode, returnID: card.id }; mode = 'edit'; revealed = false; }
  } else if (id === 'delete' && (mode === 'today' || mode === 'library')) {
    const card = currentCard();
    if (card) { deleting = card; mode = 'delete'; revealed = false; }
  } else if (id === 'back' && mode === 'delete') { mode = 'library'; deleting = null; }
  else if (id === 'confirm-delete' && mode === 'delete' && deleting) {
    const card = deleting;
    await mutate(current => {
      const existing = current.cards.find(item => item.id === card.id);
      if (existing && !sameCard(existing, card)) problem('다른 창에서 카드가 변경되었습니다. 돌아가서 새로고침해 주세요.');
      return { version: 1, cards: current.cards.filter(item => item.id !== card.id) };
    });
    mode = 'library'; selectedID = null; deleting = null; status = '카드를 삭제했습니다.';
  } else if (id === 'refresh' && !draft) { await refresh(); revealed = false; }
  await render();
}));
ember.dispose(() => { draft = null; deleting = null; deck = { version: 1, cards: [] }; });
