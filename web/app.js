(function () {
"use strict";

const $ = (selector) => document.querySelector(selector);
const esc = (value = "") => String(value).replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
const pad = (value) => String(value).padStart(2, "0");
const categoryColors = ["#477b70", "#c75543", "#9b7432", "#5c668f", "#7b587d", "#416b7c", "#8a6a4f", "#6d7a45"];
const body = $("#memoBody"), panel = $("#memoPanel");
const sortOptions = [["updated", "更新が新しい順"], ["created-desc", "作成が新しい順"], ["created-asc", "作成が古い順"], ["title", "見出し順"], ["tag", "タグ別にまとめる"]];

function stored(key, fallback) { try { return localStorage.getItem(key) || fallback; } catch { return fallback; } }
function store(key, value) { try { localStorage.setItem(key, value); } catch { /* 保存できなくても動作には影響しない */ } }

const state = {
  tags: [], categories: [], destinations: null, destinationPrompted: false,
  memoId: null, revision: 0, createdAt: "", title: "", titleEdited: false,
  tagIds: [], files: [], uploads: [],
  mode: null, dirty: false, saving: null, retryTimer: null, savedRange: null,
  tagQuery: "", tagIndex: -1,
  listQuery: "", listItems: [], listIndex: 0, listSort: stored("popnote.listSort", "updated"), listTagFilter: new Set(),
  calendarMonth: null, calendarDay: "", calendarItems: [],
  destinationIndex: 0, pendingFolder: null,
};
let saveTimer = null, listTimer = null;

async function request(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", ...options, headers: { ...(options.body ? { "Content-Type": "application/json" } : {}), ...(options.headers || {}) } });
  let result;
  try { result = await response.json(); } catch { result = {}; }
  if (!response.ok) { const error = new Error(result.error || `処理に失敗しました (${response.status})`); Object.assign(error, { status: response.status, detail: result }); throw error; }
  return result;
}

// ---- 表示 ----

function defaultTitle(createdAt) {
  const date = new Date(createdAt);
  return `${pad(date.getMonth() + 1)}月${pad(date.getDate())}日${pad(date.getHours())}時${pad(date.getMinutes())}分${pad(date.getSeconds())}秒のノート`;
}
function dateLabel(value) {
  const date = new Date(value);
  return `${date.getFullYear()}/${pad(date.getMonth() + 1)}/${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
function dayKey(value) { const date = new Date(value); return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`; }
function currentTitle() { return state.title.trim() || defaultTitle(state.createdAt); }
function tagById(id) { return state.tags.find((tag) => tag.id === id); }
// タグごとに色を固定する（PopNote!で作るタグはすべて「その他」分類になるため、分類ではなくタグで塗り分ける）。
function tagColor(tag) { let hash = 0; for (const character of String(tag?.id || "")) hash = (hash * 31 + character.codePointAt(0)) >>> 0; return categoryColors[hash % categoryColors.length]; }
function tagChip(id, removable = false) {
  const tag = tagById(id);
  if (!tag) return "";
  return `<span class="memo-chip" style="--chip:${tagColor(tag)}">${esc(tag.name)}${removable ? `<button type="button" data-remove-tag="${esc(id)}" aria-label="${esc(tag.name)}を外す">×</button>` : ""}</span>`;
}

function setStatus(text, error = false) {
  const node = $("#memoStatus");
  node.textContent = text;
  node.classList.toggle("error", error);
}

function renderHeader() {
  $("#memoTitle").textContent = currentTitle();
  document.title = `${currentTitle()} - PopNote!`;
  $("#memoCreated").textContent = `作成 ${dateLabel(state.createdAt)}`;
  $("#memoTags").innerHTML = state.tagIds.length ? state.tagIds.map((id) => tagChip(id)).join("") : '<span class="memo-tags-empty">＋ タグ（⌘T）</span>';
  const count = state.files.length + state.uploads.length;
  $("#memoAttachmentCount").textContent = count ? `📎 添付 ${count}件` : "📎 添付なし";
  renderDestinationChip();
}

function renderDestinationChip() {
  const chip = $("#memoDestination"), current = state.destinations?.current;
  chip.classList.toggle("missing", !current);
  chip.classList.toggle("linked", state.destinations?.mode === "ticktocktome");
  chip.innerHTML = current ? `<span>📁 ${esc(current.id || current.name)}</span>${state.destinations.mode === "ticktocktome" ? "<small>Tomeletと同じ基準パス</small>" : ""}` : "<span>📁 保存先を選ぶ</span>";
  chip.title = current ? `保存先：${current.path}` : "メモの保存先を選んでください";
}

function isBlank() {
  return !state.memoId && !state.titleEdited && !state.tagIds.length && !state.files.length && !state.uploads.length && !body.textContent.trim() && !body.querySelector("img");
}

// ---- 保存（入力を止めて0.4秒後に自動保存。閉じる直前はflushで待つ） ----

function payload() {
  return { title: currentTitle(), bodyHtml: body.innerHTML, tagIds: state.tagIds, managedFileIds: state.files.map((file) => file.id), uploadIds: state.uploads.map((upload) => upload.id) };
}

function changed() {
  state.dirty = true;
  renderHeader();
  setStatus(isBlank() ? "新しいメモ" : "編集中…");
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 400);
}

function applyServerItem(item) {
  // 添付一覧は保存中に追加された分を失わないよう、画面側の状態を正とする。
  state.memoId = item.id; state.revision = item.revision;
  if (new URLSearchParams(location.search).get("id") !== item.id) history.replaceState(null, "", `/index.html?id=${encodeURIComponent(item.id)}`);
}

// 保存先が無い・使用中の場合は、書きかけの内容を画面に残したまま案内する。
function saveFailed(error) {
  state.dirty = true;
  if (error.detail?.destinationRequired) {
    setStatus("保存先を選ぶと、ここまでの内容を保存します", true);
    if (!state.destinationPrompted && state.mode !== "destination") { state.destinationPrompted = true; toggleMode("destination"); }
    return;
  }
  setStatus(`保存できません：${error.message}`, true);
  if (error.status !== 409) { clearTimeout(state.retryTimer); state.retryTimer = setTimeout(save, 3000); }
}

async function save() {
  clearTimeout(saveTimer);
  if (state.saving || !state.dirty) return;
  if (isBlank()) { state.dirty = false; return; }
  state.dirty = false;
  const memoId = state.memoId, data = payload();
  state.saving = (async () => {
    try {
      const result = memoId
        ? await request(`/api/memos/${encodeURIComponent(memoId)}`, { method: "PUT", body: JSON.stringify({ ...data, revision: state.revision }) })
        : await request("/api/memos", { method: "POST", body: JSON.stringify({ ...data, createdAt: state.createdAt }) });
      if (state.memoId === memoId || !memoId) applyServerItem(result.item);
      setStatus(state.dirty ? "編集中…" : `保存済み ${dateLabel(result.item.updatedAt).slice(11)}`);
      renderHeader();
    } catch (error) { saveFailed(error); }
    finally { state.saving = null; }
  })();
  await state.saving;
  if (state.dirty && state.destinations?.current) { clearTimeout(saveTimer); saveTimer = setTimeout(save, 400); }
}

async function flush() {
  clearTimeout(saveTimer);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    if (state.saving) await state.saving;
    else if (state.dirty && !isBlank() && state.destinations?.current) await save();
    else break;
  }
}

// ---- 保存先と、その保存先のタグ ----

async function loadDestinations() {
  try { state.destinations = await request("/api/destinations"); }
  catch (error) { setStatus(error.message, true); }
  renderDestinationChip();
}

async function loadContext() {
  if (!state.destinations?.current) { state.tags = []; state.categories = []; return; }
  try {
    const context = await request("/api/context");
    Object.assign(state, { tags: context.tags, categories: context.tagCategories });
  } catch (error) { setStatus(error.message, true); }
}

async function selectDestination(path, datasetId) {
  const previous = state.destinations?.current?.path;
  if (previous && previous !== path) await flush();
  try {
    state.destinations = await request("/api/destinations:select", { method: "POST", body: JSON.stringify({ path, ...(datasetId ? { datasetId } : {}) }) });
  } catch (error) { setStatus(error.message, true); return; }
  state.pendingFolder = null;
  await loadContext();
  closeMode(false);
  if (previous !== path && state.memoId) startNewMemo();
  else {
    // まだ保存していない書きかけは、新しい保存先へそのまま保存する（タグは保存先ごとに違うので外す）。
    state.tagIds = state.tagIds.filter((id) => tagById(id));
    renderHeader();
    if (!isBlank()) changed(); else setStatus("新しいメモ");
    body.focus();
  }
}

// ---- メモの切替 ----

function startNewMemo() {
  Object.assign(state, { memoId: null, revision: 0, createdAt: new Date().toISOString(), title: "", titleEdited: false, tagIds: [], files: [], uploads: [], dirty: false, savedRange: null });
  body.innerHTML = "";
  history.replaceState(null, "", "/index.html?new=1");
  renderHeader();
  setStatus("新しいメモ");
  closeMode(false);
  body.focus();
}

function loadMemo(item) {
  Object.assign(state, { memoId: item.id, revision: item.revision, createdAt: item.createdAt, title: item.title, titleEdited: item.title !== defaultTitle(item.createdAt), tagIds: item.tagIds, files: item.files, uploads: item.uploads, dirty: false, savedRange: null });
  body.innerHTML = item.bodyHtml;
  history.replaceState(null, "", `/index.html?id=${encodeURIComponent(item.id)}`);
  renderHeader();
  setStatus(`保存済み ${dateLabel(item.updatedAt).slice(11)}`);
  closeMode(false);
  focusBodyEnd();
}

async function openTarget(target) {
  await flush();
  if (!target || target === "new") return startNewMemo();
  try { loadMemo((await request(`/api/memos/${encodeURIComponent(target)}`)).item); }
  catch (error) { startNewMemo(); setStatus(error.message, true); }
}

function focusBodyEnd() {
  body.focus();
  const range = document.createRange();
  range.selectNodeContents(body); range.collapse(false);
  const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
}

// ---- モード（タグ・見出し・添付・一覧・カレンダー・保存先） ----

function rememberSelection() {
  const selection = window.getSelection();
  if (selection.rangeCount && body.contains(selection.getRangeAt(0).commonAncestorContainer)) state.savedRange = selection.getRangeAt(0).cloneRange();
}
function restoreSelection() {
  body.focus();
  if (!state.savedRange) return;
  const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(state.savedRange);
}

function toggleMode(mode) {
  if (state.mode === mode) return closeMode();
  if (!state.mode) rememberSelection();
  state.mode = mode;
  if (mode === "tag") { state.tagQuery = ""; state.tagIndex = -1; }
  if (mode === "list") { state.listQuery = ""; state.listIndex = 0; state.listItems = []; state.listTagFilter = new Set(); loadList(); }
  if (mode === "calendar") {
    const base = state.memoId ? new Date(state.createdAt) : new Date();
    state.calendarMonth = new Date(base.getFullYear(), base.getMonth(), 1); state.calendarDay = dayKey(base); state.calendarItems = [];
    loadCalendar();
  }
  if (mode === "destination") { state.destinationIndex = 0; state.pendingFolder = null; loadDestinations().then(() => state.mode === "destination" && renderPanel()); }
  renderPanel();
  const focus = panel.querySelector("input, [data-focus]");
  focus?.focus();
  focus?.select?.();
}

function closeMode(restore = true) {
  if (!state.mode) return;
  if (state.mode === "heading" && !state.title.trim()) { state.title = ""; state.titleEdited = false; renderHeader(); }
  state.mode = null;
  panel.hidden = true; panel.innerHTML = "";
  document.body.classList.remove("memo-mode-open");
  if (restore) restoreSelection();
}

function hint(items) { return `<p class="memo-panel-hint">${items.map(([key, text]) => `<span><kbd>${esc(key)}</kbd>${esc(text)}</span>`).join("")}</p>`; }

function renderPanel() {
  if (!state.mode) return;
  panel.hidden = false;
  document.body.classList.add("memo-mode-open");
  if (state.mode === "heading") {
    panel.innerHTML = `<section class="memo-card" aria-label="見出し編集"><h2>見出し編集</h2><input id="headingInput" maxlength="300" value="${esc(state.titleEdited ? state.title : currentTitle())}" placeholder="${esc(defaultTitle(state.createdAt))}">${hint([["Enter", "確定"], ["Esc", "閉じる"], ["⌘H", "閉じる"]])}</section>`;
  } else if (state.mode === "tag") {
    panel.innerHTML = `<section class="memo-card" aria-label="タグ設定"><h2>タグ設定</h2><div id="tagChips" class="memo-chip-row"></div><input id="tagInput" autocomplete="off" value="${esc(state.tagQuery)}" placeholder="タグ名を入力して検索…"><ul id="tagSuggestions" class="memo-suggestions" role="listbox"></ul>${hint([["↑↓", "候補を選ぶ"], ["Enter", "追加（候補なしは「その他」に新規作成）"], ["Esc", "閉じる"], ["⌘T", "閉じる"]])}</section>`;
    renderTagChips();
    renderTagSuggestions();
  } else if (state.mode === "attach") {
    const current = state.destinations?.current;
    const files = state.files.map((file) => `<li><span class="memo-file-icon">${esc((file.extension || "file").slice(0, 4).toUpperCase())}</span><span><strong>${esc(file.name)}</strong><small>${esc(file.relativePath)}</small></span><button type="button" data-open-file="${esc(file.id)}">開く</button><button type="button" data-remove-file="${esc(file.id)}" aria-label="外す">×</button></li>`).join("");
    const uploads = state.uploads.map((upload) => `<li><img src="/api/v1/uploads/${encodeURIComponent(upload.id)}/content" alt=""><span><strong>${esc(upload.originalName)}</strong><small>クリップボード画像 · ${Math.max(1, Math.round(upload.sizeBytes / 1024))}KB</small></span><button type="button" data-open-upload="${esc(upload.id)}">開く</button><button type="button" data-remove-upload="${esc(upload.id)}" aria-label="外す">×</button></li>`).join("");
    panel.innerHTML = `<section class="memo-card" aria-label="ファイル添付"><h2>ファイル添付</h2><p class="memo-muted">${current ? `ファイル本体はコピーせず、保存先「${esc(current.id || current.name)}」のフォルダからの相対パスだけを記録します。` : "先にメモの保存先を選んでください。"}</p><ul class="memo-files">${files}${uploads}</ul>${files || uploads ? "" : '<p class="memo-empty">添付はまだありません。</p>'}<div class="memo-card-actions"><button type="button" class="primary" data-pick-file ${current ? "" : "disabled"}>保存先フォルダからファイルを選ぶ</button></div>${hint([["Enter", "ファイルを選ぶ"], ["⌘V", "クリップボード画像を添付"], ["Esc", "閉じる"], ["⌘A", "閉じる"]])}</section>`;
    panel.querySelector("[data-pick-file]")?.focus();
  } else if (state.mode === "list") {
    panel.innerHTML = `<section class="memo-card memo-list-card" aria-label="メモ一覧"><h2>メモ一覧</h2><input id="listInput" autocomplete="off" value="${esc(state.listQuery)}" placeholder="見出し・本文・タグで検索…"><div class="memo-list-tools"><label>並べ替え<select id="listSort">${sortOptions.map(([value, label]) => `<option value="${value}" ${state.listSort === value ? "selected" : ""}>${label}</option>`).join("")}</select></label><div id="listTagFilter" class="memo-tag-filter"></div></div><ul id="memoList" class="memo-list" role="listbox"></ul>${hint([["↑↓", "選ぶ"], ["Enter", "開く"], ["Tab", "並べ替えへ"], ["Esc", "閉じる"], ["⌘O", "閉じる"]])}</section>`;
    renderList();
  } else if (state.mode === "calendar") {
    panel.innerHTML = `<section class="memo-card memo-calendar-card" aria-label="カレンダー" tabindex="0" data-focus><div id="memoCalendar"></div>${hint([["←→↑↓", "日を選ぶ"], ["Enter", "その日のメモを開く"], ["PageUp/Down", "前月・翌月"], ["Esc", "閉じる"]])}</section>`;
    renderCalendar();
  } else if (state.mode === "destination") {
    renderDestinationPanel();
  }
}

// ---- タグ ----

function tagSuggestions() {
  const query = state.tagQuery.trim().toLowerCase();
  return state.tags.filter((tag) => !state.tagIds.includes(tag.id) && (!query || tag.name.toLowerCase().includes(query)))
    .sort((a, b) => Number(!a.name.toLowerCase().startsWith(query)) - Number(!b.name.toLowerCase().startsWith(query)))
    .slice(0, 8);
}

function renderTagChips() {
  const row = panel.querySelector("#tagChips");
  if (row) row.innerHTML = state.tagIds.map((id) => tagChip(id, true)).join("") || '<span class="memo-muted">まだタグはありません</span>';
}

function renderTagSuggestions() {
  const list = panel.querySelector("#tagSuggestions");
  if (!list) return;
  const items = tagSuggestions(), query = state.tagQuery.trim();
  state.tagIndex = Math.min(state.tagIndex, items.length - 1);
  const exact = state.tags.some((tag) => tag.name === query);
  list.innerHTML = items.map((tag, index) => `<li role="option" aria-selected="${index === state.tagIndex}" class="${index === state.tagIndex ? "active" : ""}" data-add-tag="${esc(tag.id)}"><span class="memo-dot" style="--chip:${tagColor(tag)}"></span>${esc(tag.name)}<small>${esc(tag.categoryName || "")}</small></li>`).join("")
    + (query && !exact ? `<li class="memo-create ${state.tagIndex < 0 ? "active" : ""}" data-create-tag>＋「${esc(query)}」を「その他」に作成<small>Enter</small></li>` : "");
}

async function addTagFromInput() {
  const items = tagSuggestions(), query = state.tagQuery.trim();
  let tag = state.tagIndex >= 0 ? items[state.tagIndex] : null;
  if (!tag && !query) return;
  if (!tag) {
    tag = state.tags.find((item) => item.name === query);
    if (!tag) {
      try {
        tag = (await request("/api/tags", { method: "POST", body: JSON.stringify({ name: query }) })).item;
        if (!state.tags.some((item) => item.id === tag.id)) state.tags.push(tag);
      } catch (error) { if (error.detail?.destinationRequired) { closeMode(false); toggleMode("destination"); } else setStatus(error.message, true); return; }
    }
  }
  addTag(tag.id, query);
}

// 新規タグの作成を待つ間に入力された文字は消さず、確定した語だけを入力欄から取り除く。
function addTag(id, submitted = state.tagQuery) {
  if (!state.tagIds.includes(id)) state.tagIds = [...state.tagIds, id];
  const input = panel.querySelector("#tagInput");
  if (input && submitted && input.value.startsWith(submitted)) input.value = input.value.slice(submitted.length).trimStart();
  state.tagQuery = input ? input.value : ""; state.tagIndex = -1;
  changed(); renderTagChips(); renderTagSuggestions();
  input?.focus();
}

// ---- 一覧（並べ替え・タグで絞り込み） ----

async function loadList() {
  try {
    const query = state.listQuery;
    const items = (await request(`/api/memos?q=${encodeURIComponent(query)}&limit=500`)).items;
    if (state.mode !== "list" || query !== state.listQuery) return;
    state.listItems = items; state.listIndex = 0;
    renderList();
  } catch (error) { renderList(error.detail?.destinationRequired ? "保存先を選ぶと、メモの一覧が表示されます。" : error.message); }
}

function tagOrder(id) { const index = state.tags.findIndex((tag) => tag.id === id); return index < 0 ? Number.MAX_SAFE_INTEGER : index; }

// 表示する行。タグ別のときは、同じメモが複数のタグの下に出ることがある。
function listRows() {
  const filtered = state.listItems.filter((item) => [...state.listTagFilter].every((id) => item.tagIds.includes(id)));
  const compare = {
    updated: (a, b) => b.updatedAt.localeCompare(a.updatedAt),
    "created-desc": (a, b) => b.createdAt.localeCompare(a.createdAt),
    "created-asc": (a, b) => a.createdAt.localeCompare(b.createdAt),
    title: (a, b) => a.title.localeCompare(b.title, "ja"),
    tag: (a, b) => b.updatedAt.localeCompare(a.updatedAt),
  }[state.listSort] || ((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  const sorted = [...filtered].sort(compare);
  if (state.listSort !== "tag") return sorted.map((item) => ({ item }));
  const groups = new Map();
  for (const item of sorted) for (const id of item.tagIds.length ? item.tagIds : [""]) { if (!groups.has(id)) groups.set(id, []); groups.get(id).push(item); }
  return [...groups.keys()].sort((a, b) => (a === "" ? 1 : b === "" ? -1 : tagOrder(a) - tagOrder(b)))
    .flatMap((id) => [{ group: id ? tagById(id)?.name || "（不明なタグ）" : "タグなし", tagId: id, count: groups.get(id).length }, ...groups.get(id).map((item) => ({ item }))]);
}

function renderList(message = "") {
  const list = panel.querySelector("#memoList");
  if (!list) return;
  const usedTags = [...new Set(state.listItems.flatMap((item) => item.tagIds))].sort((a, b) => tagOrder(a) - tagOrder(b));
  const filter = panel.querySelector("#listTagFilter");
  filter.innerHTML = usedTags.length ? `<span class="memo-muted">タグで絞り込み</span>${usedTags.map((id) => { const tag = tagById(id); return tag ? `<button type="button" class="memo-chip ${state.listTagFilter.has(id) ? "selected" : ""}" style="--chip:${tagColor(tag)}" data-filter-tag="${esc(id)}">${esc(tag.name)}</button>` : ""; }).join("")}` : "";
  const rows = listRows(), selectable = rows.filter((row) => row.item);
  state.listIndex = Math.min(state.listIndex, Math.max(0, selectable.length - 1));
  let index = -1;
  list.innerHTML = rows.map((row) => {
    if (row.group) return `<li class="memo-group" role="presentation">${row.tagId ? `<span class="memo-dot" style="--chip:${tagColor(tagById(row.tagId))}"></span>` : ""}${esc(row.group)}<small>${row.count}件</small></li>`;
    index += 1;
    const item = row.item;
    return `<li role="option" aria-selected="${index === state.listIndex}" class="${index === state.listIndex ? "active" : ""} ${item.id === state.memoId ? "current" : ""}" data-open-memo="${esc(item.id)}"><div><strong>${esc(item.title)}</strong><time>${esc(dateLabel(state.listSort === "updated" ? item.updatedAt : item.createdAt))}</time></div><small>${esc(item.excerpt || "（本文なし）")}</small><span class="memo-chip-row">${item.tagIds.map((id) => tagChip(id)).join("")}</span><button type="button" class="memo-delete" data-delete-memo="${esc(item.id)}" data-revision="${item.revision}" title="ゴミ箱へ移動">🗑</button></li>`;
  }).join("") || `<li class="memo-empty">${esc(message || (state.listQuery || state.listTagFilter.size ? "一致するメモはありません。" : "まだメモはありません。"))}</li>`;
  list.querySelector(".active")?.scrollIntoView({ block: "nearest" });
}

function selectedListItem() { return listRows().filter((row) => row.item)[state.listIndex]?.item; }

async function openFromList(id) {
  closeMode(false);
  if (id === state.memoId) { restoreSelection(); return; }
  await openTarget(id);
}

async function deleteMemo(id, revision) {
  if (!window.confirm("このメモを削除しますか？")) return;
  try {
    if (id === state.memoId) { await flush(); revision = state.revision; }
    await request(`/api/memos/${encodeURIComponent(id)}`, { method: "DELETE", body: JSON.stringify({ revision }) });
    const reopen = state.mode;
    if (id === state.memoId) { state.memoId = null; startNewMemo(); if (reopen) toggleMode(reopen); }
    else if (state.mode === "list") await loadList();
    else if (state.mode === "calendar") await loadCalendar();
  } catch (error) { setStatus(error.message, true); }
}

// ---- カレンダー ----

function monthRange(month) {
  return { from: new Date(month.getFullYear(), month.getMonth(), 1).toISOString(), to: new Date(month.getFullYear(), month.getMonth() + 1, 1).toISOString() };
}

async function loadCalendar() {
  const month = state.calendarMonth;
  try {
    const items = (await request(`/api/memos?${new URLSearchParams({ ...monthRange(month), limit: "1000" })}`)).items;
    if (state.mode !== "calendar" || month !== state.calendarMonth) return;
    state.calendarItems = items;
    renderCalendar();
  } catch (error) { state.calendarItems = []; renderCalendar(error.detail?.destinationRequired ? "保存先を選ぶと、メモがカレンダーに表示されます。" : error.message); }
}

function shiftCalendarDay(days) {
  const [year, month, day] = state.calendarDay.split("-").map(Number);
  const next = new Date(year, month - 1, day + days);
  state.calendarDay = dayKey(next);
  if (next.getFullYear() !== state.calendarMonth.getFullYear() || next.getMonth() !== state.calendarMonth.getMonth()) {
    state.calendarMonth = new Date(next.getFullYear(), next.getMonth(), 1); state.calendarItems = []; renderCalendar(); loadCalendar();
  } else renderCalendar();
}

function shiftCalendarMonth(months) {
  const month = new Date(state.calendarMonth.getFullYear(), state.calendarMonth.getMonth() + months, 1);
  const day = Math.min(Number(state.calendarDay.slice(8)), new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate());
  state.calendarMonth = month; state.calendarDay = dayKey(new Date(month.getFullYear(), month.getMonth(), day)); state.calendarItems = [];
  renderCalendar(); loadCalendar();
}

function calendarDayItems(key) {
  return state.calendarItems.filter((item) => dayKey(item.createdAt) === key).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
}

function renderCalendar(message = "") {
  const host = panel.querySelector("#memoCalendar");
  if (!host) return;
  const month = state.calendarMonth, year = month.getFullYear(), monthIndex = month.getMonth();
  const first = new Date(year, monthIndex, 1).getDay(), days = new Date(year, monthIndex + 1, 0).getDate(), today = dayKey(new Date());
  const cells = Array.from({ length: first }, () => '<div class="memo-cal-cell blank"></div>');
  for (let day = 1; day <= days; day += 1) {
    const key = `${year}-${pad(monthIndex + 1)}-${pad(day)}`, items = calendarDayItems(key);
    const titles = items.slice(0, 3).map((item) => { const tag = tagById(item.tagIds[0]); return `<span class="memo-cal-item" style="--chip:${tag ? tagColor(tag) : "var(--coral)"}">${esc(item.title)}</span>`; }).join("");
    cells.push(`<button type="button" class="memo-cal-cell ${key === state.calendarDay ? "selected" : ""} ${key === today ? "today" : ""} ${items.length ? "has-items" : ""}" data-calendar-day="${key}"><b>${day}</b>${titles}${items.length > 3 ? `<small>+${items.length - 3}</small>` : ""}</button>`);
  }
  const selected = calendarDayItems(state.calendarDay), [, selectedMonth, selectedDay] = state.calendarDay.split("-").map(Number);
  const total = state.calendarItems.length;
  host.innerHTML = `<header class="memo-cal-head"><button type="button" data-calendar-month="-1" aria-label="前の月">‹</button><h2>${year}年${monthIndex + 1}月</h2><button type="button" data-calendar-month="1" aria-label="次の月">›</button><button type="button" class="memo-cal-today" data-calendar-today>今日</button><span class="memo-muted">${total ? `${total}件` : ""}</span></header>
    <div class="memo-cal-grid">${["日", "月", "火", "水", "木", "金", "土"].map((name, index) => `<span class="memo-cal-weekday ${index === 0 ? "sun" : index === 6 ? "sat" : ""}">${name}</span>`).join("")}${cells.join("")}</div>
    <section class="memo-cal-day"><h3>${selectedMonth}月${selectedDay}日のメモ</h3>${message ? `<p class="memo-empty">${esc(message)}</p>` : selected.length ? `<ul class="memo-list">${selected.map((item) => `<li data-open-memo="${esc(item.id)}" class="${item.id === state.memoId ? "current" : ""}"><div><strong>${esc(item.title)}</strong><time>${esc(dateLabel(item.createdAt).slice(11))}</time></div><small>${esc(item.excerpt || "（本文なし）")}</small><span class="memo-chip-row">${item.tagIds.map((id) => tagChip(id)).join("")}</span></li>`).join("")}</ul>` : '<p class="memo-empty">この日のメモはありません。</p>'}</section>`;
}

// ---- 保存先 ----

function destinationRows() {
  const data = state.destinations || { recent: [] }, rows = [];
  const opened = data.tickTockTome?.current;
  if (opened && !data.recent.some((item) => item.key === opened.key)) rows.push({ kind: "ticktocktome", path: opened.basePath, title: `Tomeletで開いている「${opened.id}」`, detail: opened.basePath });
  for (const item of data.recent) rows.push({ kind: "recent", path: item.path, title: item.id || item.name, detail: item.path, current: item.current, available: item.available, linked: opened?.key === item.key });
  rows.push({ kind: "choose", title: "フォルダを選ぶ…", detail: "新しいフォルダを選ぶと、メモを保存するフォルダ（.kobito-tools）を作ります" });
  return rows;
}

function renderDestinationPanel() {
  const data = state.destinations;
  if (state.pendingFolder) {
    const folder = state.pendingFolder;
    panel.innerHTML = `<section class="memo-card" aria-label="保存先の作成"><h2>新しい保存先</h2><p class="memo-muted">「${esc(folder.path)}」に、メモを保存するフォルダ（.kobito-tools/PopNote）を作ります。後からこのフォルダをTomeletの基準パスにすると、Tomeletのカレンダーにも表示できます。</p><label class="memo-field"><span>ID（保存先の名前）</span><input id="destinationIdInput" maxlength="60" value="${esc(folder.suggestedId)}"></label><div class="memo-card-actions"><button type="button" class="primary" data-create-destination>作成して保存先にする</button><button type="button" data-cancel-destination>戻る</button></div>${hint([["Enter", "作成"], ["Esc", "閉じる"]])}</section>`;
    return;
  }
  const rows = destinationRows();
  state.destinationIndex = Math.min(state.destinationIndex, rows.length - 1);
  const intro = data?.current ? "" : `<p class="memo-notice">${data?.tickTockTome?.installed ? "メモの保存先を選んでください。Tomeletの基準パスを選ぶと、Tomeletのカレンダーにも表示できます。" : "メモを保存するフォルダを選んでください。PopNote!だけで使えます。"}</p>`;
  panel.innerHTML = `<section class="memo-card" aria-label="保存先" tabindex="0" data-focus><h2>保存先</h2>${intro}<ul class="memo-destinations" role="listbox">${rows.map((row, index) => `<li role="option" aria-selected="${index === state.destinationIndex}" class="${index === state.destinationIndex ? "active" : ""} ${row.current ? "current" : ""} ${row.available === false ? "unavailable" : ""}" data-destination-index="${index}"><span class="memo-destination-icon">${row.kind === "choose" ? "＋" : row.kind === "ticktocktome" ? "⏱" : "📁"}</span><span><strong>${esc(row.title)}</strong><small>${esc(row.available === false ? "見つかりません（フォルダの移動・未接続）" : row.detail)}</small></span>${row.current ? '<em>使用中</em>' : row.linked ? '<em class="linked">Tomelet</em>' : ""}${row.kind === "recent" && !row.current ? `<button type="button" class="memo-delete" data-forget-destination="${esc(row.path)}" title="一覧から外す（データは消えません）">×</button>` : ""}</li>`).join("")}</ul>${hint([["↑↓", "選ぶ"], ["Enter", "決定"], ["Esc", "閉じる"]])}</section>`;
}

async function chooseDestinationRow(index) {
  const row = destinationRows()[index];
  if (!row) return;
  if (row.kind !== "choose") { if (row.available === false) { setStatus("このフォルダが見つかりません。", true); return; } return selectDestination(row.path); }
  try {
    const chosen = await request("/api/destinations:choose", { method: "POST", body: "{}" });
    if (chosen.cancelled) return panel.querySelector("[data-focus]")?.focus();
    if (chosen.existing) return selectDestination(chosen.path);
    state.pendingFolder = chosen;
    renderPanel();
    const input = panel.querySelector("#destinationIdInput"); input?.focus(); input?.select();
  } catch (error) { setStatus(error.message, true); }
}

function createPendingDestination() {
  const input = panel.querySelector("#destinationIdInput");
  if (!state.pendingFolder || !input?.value.trim()) return input?.focus();
  selectDestination(state.pendingFolder.path, input.value.trim());
}

// ---- 添付 ----

async function pickFile() {
  try {
    setStatus("ファイル選択画面を開いています…");
    const result = await request("/api/files:pick", { method: "POST", body: "{}" });
    if (result.cancelled) { setStatus(state.memoId ? "保存済み" : "新しいメモ"); return; }
    if (!state.files.some((item) => item.id === result.item.id)) state.files = [...state.files, result.item];
    changed();
    if (state.mode === "attach") renderPanel();
  } catch (error) { setStatus(error.message, true); }
}

function readBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1] || "");
    reader.onerror = () => reject(new Error("画像を読み込めませんでした。"));
    reader.readAsDataURL(file);
  });
}

async function uploadImage(file) {
  const extension = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic" }[file.type] || "png";
  const now = new Date();
  const name = file.name && file.name !== "image.png" ? file.name : `clipboard-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}.${extension}`;
  setStatus("画像を保存しています…");
  const upload = (await request("/api/uploads", { method: "POST", body: JSON.stringify({ name, mimeType: file.type, base64: await readBase64(file) }) })).item;
  if (!state.uploads.some((item) => item.id === upload.id)) state.uploads = [...state.uploads, upload];
  return upload;
}

function removeUpload(id) {
  state.uploads = state.uploads.filter((upload) => upload.id !== id);
  body.querySelectorAll(`img[src="/api/v1/uploads/${CSS.escape(id)}/content"]`).forEach((node) => node.remove());
  changed();
  renderPanel();
}

document.addEventListener("paste", async (event) => {
  const images = [...(event.clipboardData?.items || [])].filter((item) => item.kind === "file" && item.type.startsWith("image/")).map((item) => item.getAsFile()).filter(Boolean);
  const inBody = body.contains(event.target) || event.target === body;
  if (images.length && (inBody || state.mode === "attach")) {
    event.preventDefault();
    try {
      for (const image of images) {
        const upload = await uploadImage(image);
        if (inBody && state.mode !== "attach") document.execCommand("insertHTML", false, `<img src="/api/v1/uploads/${encodeURIComponent(upload.id)}/content" alt="">`);
      }
      changed();
      if (state.mode === "attach") renderPanel();
    } catch (error) { if (error.detail?.destinationRequired) toggleMode("destination"); setStatus(error.message, true); }
    return;
  }
  // 他アプリの書式や埋め込みを持ち込まず、文字だけを貼り付ける。
  if (inBody) {
    event.preventDefault();
    document.execCommand("insertText", false, event.clipboardData?.getData("text/plain") || "");
  }
});

// ---- 装飾 ----

function format(command) {
  const selection = window.getSelection();
  const inBody = document.activeElement === body || (selection.rangeCount && body.contains(selection.getRangeAt(0).commonAncestorContainer));
  if (!inBody || state.mode) return;
  document.execCommand(command, false, null);
  changed();
}

// ---- 入力 ----

body.addEventListener("input", changed);
body.addEventListener("keydown", (event) => {
  // Tabでフォーカスを移さず、本文へタブ文字を入れる。
  if (event.key === "Tab") { event.preventDefault(); document.execCommand("insertText", false, "\t"); }
});

panel.addEventListener("input", (event) => {
  if (event.target.id === "headingInput") { state.title = event.target.value; state.titleEdited = Boolean(event.target.value.trim()); changed(); }
  if (event.target.id === "tagInput") { state.tagQuery = event.target.value; state.tagIndex = -1; renderTagSuggestions(); }
  if (event.target.id === "listInput") { state.listQuery = event.target.value; state.listIndex = 0; clearTimeout(listTimer); listTimer = setTimeout(loadList, 150); }
});

panel.addEventListener("change", (event) => {
  if (event.target.id === "listSort") { state.listSort = event.target.value; state.listIndex = 0; store("popnote.listSort", state.listSort); renderList(); panel.querySelector("#listInput")?.focus(); }
});

function moveListSelection(step) {
  const count = listRows().filter((row) => row.item).length;
  state.listIndex = Math.max(0, Math.min(count - 1, state.listIndex + step));
  renderList();
}

panel.addEventListener("keydown", (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  const id = event.target.id;
  if (id === "headingInput" && event.key === "Enter") { event.preventDefault(); closeMode(); }
  if (id === "tagInput") {
    const count = tagSuggestions().length;
    if (event.key === "ArrowDown") { event.preventDefault(); state.tagIndex = Math.min(count - 1, state.tagIndex + 1); renderTagSuggestions(); }
    else if (event.key === "ArrowUp") { event.preventDefault(); state.tagIndex = Math.max(-1, state.tagIndex - 1); renderTagSuggestions(); }
    else if (event.key === "Enter") { event.preventDefault(); addTagFromInput(); }
    else if (event.key === "Backspace" && !event.target.value && state.tagIds.length) { state.tagIds = state.tagIds.slice(0, -1); changed(); renderTagChips(); renderTagSuggestions(); }
  }
  if (id === "listInput") {
    if (event.key === "ArrowDown") { event.preventDefault(); moveListSelection(1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); moveListSelection(-1); }
    else if (event.key === "Enter") { event.preventDefault(); const item = selectedListItem(); if (item) openFromList(item.id); }
  }
  if (id === "destinationIdInput" && event.key === "Enter") { event.preventDefault(); createPendingDestination(); }
  if (state.mode === "calendar" && event.target.closest(".memo-calendar-card") && !event.metaKey) {
    const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    if (moves[event.key]) { event.preventDefault(); shiftCalendarDay(moves[event.key]); }
    else if (event.key === "PageUp" || event.key === "PageDown") { event.preventDefault(); shiftCalendarMonth(event.key === "PageUp" ? -1 : 1); }
    else if (event.key === "Enter" && event.target.classList.contains("memo-calendar-card")) { event.preventDefault(); const item = calendarDayItems(state.calendarDay)[0]; if (item) openFromList(item.id); }
  }
  if (state.mode === "destination" && event.target.matches("[data-focus]")) {
    const count = destinationRows().length;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); state.destinationIndex = (state.destinationIndex + (event.key === "ArrowDown" ? 1 : count - 1)) % count; renderPanel(); panel.querySelector("[data-focus]")?.focus(); }
    else if (event.key === "Enter") { event.preventDefault(); chooseDestinationRow(state.destinationIndex); }
  }
});

document.addEventListener("click", async (event) => {
  const target = event.target.closest("[data-mode],[data-command],[data-format],[data-remove-tag],[data-add-tag],[data-create-tag],[data-open-memo],[data-delete-memo],[data-pick-file],[data-open-file],[data-remove-file],[data-open-upload],[data-remove-upload],[data-filter-tag],[data-calendar-day],[data-calendar-month],[data-calendar-today],[data-destination-index],[data-forget-destination],[data-create-destination],[data-cancel-destination]");
  if (!target) { if (state.mode && !panel.contains(event.target)) closeMode(false); return; }
  if (target.dataset.deleteMemo) { event.stopPropagation(); return deleteMemo(target.dataset.deleteMemo, Number(target.dataset.revision)); }
  if (target.dataset.forgetDestination) { event.stopPropagation(); state.destinations = await request("/api/destinations:forget", { method: "POST", body: JSON.stringify({ path: target.dataset.forgetDestination }) }); return renderPanel(); }
  if (target.dataset.mode) return toggleMode(target.dataset.mode);
  if (target.dataset.command === "new") { await flush(); return startNewMemo(); }
  if (target.dataset.format) { restoreSelectionIfNeeded(); return format(target.dataset.format); }
  if (target.dataset.removeTag) { state.tagIds = state.tagIds.filter((id) => id !== target.dataset.removeTag); changed(); renderTagChips(); renderTagSuggestions(); return panel.querySelector("#tagInput")?.focus(); }
  if (target.dataset.addTag) return addTag(target.dataset.addTag);
  if (target.hasAttribute("data-create-tag")) { state.tagIndex = -1; return addTagFromInput(); }
  if (target.dataset.filterTag) { const id = target.dataset.filterTag; if (state.listTagFilter.has(id)) state.listTagFilter.delete(id); else state.listTagFilter.add(id); state.listIndex = 0; renderList(); return; }
  if (target.dataset.calendarDay) { if (target.dataset.calendarDay === state.calendarDay && calendarDayItems(state.calendarDay).length === 1) return openFromList(calendarDayItems(state.calendarDay)[0].id); state.calendarDay = target.dataset.calendarDay; renderCalendar(); return panel.querySelector("[data-focus]")?.focus(); }
  if (target.dataset.calendarMonth) return shiftCalendarMonth(Number(target.dataset.calendarMonth));
  if (target.hasAttribute("data-calendar-today")) { const today = new Date(); state.calendarMonth = new Date(today.getFullYear(), today.getMonth(), 1); state.calendarDay = dayKey(today); state.calendarItems = []; renderCalendar(); return loadCalendar(); }
  if (target.dataset.destinationIndex) { state.destinationIndex = Number(target.dataset.destinationIndex); return chooseDestinationRow(state.destinationIndex); }
  if (target.hasAttribute("data-create-destination")) return createPendingDestination();
  if (target.hasAttribute("data-cancel-destination")) { state.pendingFolder = null; renderPanel(); return panel.querySelector("[data-focus]")?.focus(); }
  if (target.dataset.openMemo) return openFromList(target.dataset.openMemo);
  if (target.hasAttribute("data-pick-file")) return pickFile();
  if (target.dataset.openFile) {
    const file = state.files.find((item) => item.id === target.dataset.openFile);
    try { await request("/api/files:open", { method: "POST", body: JSON.stringify({ relativePath: file.relativePath }) }); setStatus("OSの標準アプリで開きました。"); }
    catch (error) { setStatus(error.message, true); }
    return;
  }
  if (target.dataset.removeFile) { state.files = state.files.filter((file) => file.id !== target.dataset.removeFile); changed(); return renderPanel(); }
  if (target.dataset.openUpload) return window.open(`/api/v1/uploads/${encodeURIComponent(target.dataset.openUpload)}/content`, "_blank", "noopener");
  if (target.dataset.removeUpload) return removeUpload(target.dataset.removeUpload);
});
// ツールバーのボタンを押しても本文の選択範囲を失わない。
document.querySelector(".memo-keys").addEventListener("mousedown", (event) => { if (event.target.closest("[data-format]")) event.preventDefault(); });
function restoreSelectionIfNeeded() { if (document.activeElement !== body && state.savedRange) restoreSelection(); }
body.addEventListener("blur", rememberSelection);

document.addEventListener("keydown", (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === "Escape" && state.mode) { event.preventDefault(); closeMode(); return; }
  if (!event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
  const key = event.key.toLowerCase();
  const modes = { o: "list", t: "tag", h: "heading", a: "attach" };
  const formats = { b: "bold", u: "underline", x: "strikeThrough", i: "italic" };
  if (key === "n") { event.preventDefault(); flush().then(startNewMemo); }
  else if (modes[key]) { event.preventDefault(); toggleMode(modes[key]); }
  else if (formats[key]) { event.preventDefault(); format(formats[key]); }
  else if (key === "s") { event.preventDefault(); flush(); }
}, true);

document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") flush(); });

async function initialize() {
  document.execCommand("styleWithCSS", false, false);
  await loadDestinations();
  await loadContext();
  const id = new URLSearchParams(location.search).get("id");
  await openTarget(id || "new");
  if (!state.destinations?.current) { state.destinationPrompted = true; toggleMode("destination"); }
}

window.PopNote = Object.freeze({ flush, openTarget });
initialize();
})();
