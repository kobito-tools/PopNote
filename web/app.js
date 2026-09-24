(function () {
"use strict";

const $ = (selector) => document.querySelector(selector);
const esc = (value = "") => String(value).replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
const pad = (value) => String(value).padStart(2, "0");
const categoryColors = ["#477b70", "#c75543", "#9b7432", "#5c668f", "#7b587d", "#416b7c", "#8a6a4f", "#6d7a45"];
const body = $("#memoBody"), panel = $("#memoPanel");

const state = {
  tags: [], categories: [], fileRoots: [],
  memoId: null, revision: 0, createdAt: "", title: "", titleEdited: false,
  tagIds: [], files: [], uploads: [],
  mode: null, dirty: false, saving: null, retryTimer: null, savedRange: null,
  tagQuery: "", tagIndex: -1, listQuery: "", listItems: [], listIndex: 0,
};
let saveTimer = null, listTimer = null;

async function request(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", ...options, headers: { ...(options.body ? { "Content-Type": "application/json" } : {}), ...(options.headers || {}) } });
  let result;
  try { result = await response.json(); } catch { result = {}; }
  if (!response.ok) { const error = new Error(result.error || `処理に失敗しました (${response.status})`); error.status = response.status; throw error; }
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
function currentTitle() { return state.title.trim() || defaultTitle(state.createdAt); }
function tagById(id) { return state.tags.find((tag) => tag.id === id); }
function tagColor(tag) { const index = state.categories.findIndex((category) => category.id === tag?.categoryId); return categoryColors[Math.max(0, index) % categoryColors.length]; }
function tagChip(id, removable = false) {
  const tag = tagById(id);
  if (!tag) return "";
  return `<span class="memo-chip" style="--chip:${tagColor(tag)}">${esc(tag.name)}${removable ? `<button type="button" data-remove-tag="${esc(id)}" aria-label="${esc(tag.name)}を外す">×</button>` : ""}</span>`;
}
function modifierLabel() { return "⌘"; }

function setStatus(text, error = false) {
  const node = $("#memoStatus");
  node.textContent = text;
  node.classList.toggle("error", error);
}

function renderHeader() {
  $("#memoTitle").textContent = currentTitle();
  document.title = `${currentTitle()} - Tick Tock Tome メモ`;
  $("#memoCreated").textContent = `作成 ${dateLabel(state.createdAt)}`;
  $("#memoTags").innerHTML = state.tagIds.length ? state.tagIds.map((id) => tagChip(id)).join("") : `<span class="memo-tags-empty">＋ タグ（${modifierLabel()}T）</span>`;
  const count = state.files.length + state.uploads.length;
  $("#memoAttachmentCount").textContent = count ? `📎 添付 ${count}件` : "📎 添付なし";
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
    } catch (error) {
      state.dirty = true;
      setStatus(`保存できません：${error.message}`, true);
      if (error.status !== 409) { clearTimeout(state.retryTimer); state.retryTimer = setTimeout(save, 3000); }
    } finally { state.saving = null; }
  })();
  await state.saving;
  if (state.dirty) { clearTimeout(saveTimer); saveTimer = setTimeout(save, 400); }
}

async function flush() {
  clearTimeout(saveTimer);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    if (state.saving) await state.saving;
    else if (state.dirty && !isBlank()) await save();
    else break;
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

// ---- モード（タグ・見出し・添付・一覧） ----

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
  if (mode === "list") { state.listQuery = ""; state.listIndex = 0; state.listItems = []; loadList(); }
  renderPanel();
  panel.querySelector("input")?.focus();
  panel.querySelector("input")?.select?.();
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
  const mod = modifierLabel();
  if (state.mode === "heading") {
    panel.innerHTML = `<section class="memo-card" aria-label="見出し編集"><h2>見出し編集</h2><input id="headingInput" maxlength="300" value="${esc(state.titleEdited ? state.title : currentTitle())}" placeholder="${esc(defaultTitle(state.createdAt))}">${hint([["Enter", "確定"], ["Esc", "閉じる"], [`${mod}H`, "閉じる"]])}</section>`;
  } else if (state.mode === "tag") {
    panel.innerHTML = `<section class="memo-card" aria-label="タグ設定"><h2>タグ設定</h2><div id="tagChips" class="memo-chip-row"></div><input id="tagInput" autocomplete="off" value="${esc(state.tagQuery)}" placeholder="タグ名を入力して検索…"><ul id="tagSuggestions" class="memo-suggestions" role="listbox"></ul>${hint([["↑↓", "候補を選ぶ"], ["Enter", "追加（候補なしは「その他」に新規作成）"], ["Esc", "閉じる"], [`${mod}T`, "閉じる"]])}</section>`;
    renderTagChips();
    renderTagSuggestions();
  } else if (state.mode === "attach") {
    const root = state.fileRoots.find((item) => item.id === "files");
    const files = state.files.map((file) => `<li><span class="memo-file-icon">${esc((file.extension || "file").slice(0, 4).toUpperCase())}</span><span><strong>${esc(file.name)}</strong><small>${esc(file.relativePath)}</small></span><button type="button" data-open-file="${esc(file.id)}">開く</button><button type="button" data-remove-file="${esc(file.id)}" aria-label="外す">×</button></li>`).join("");
    const uploads = state.uploads.map((upload) => `<li><img src="/api/v1/uploads/${encodeURIComponent(upload.id)}/content" alt=""><span><strong>${esc(upload.originalName)}</strong><small>クリップボード画像 · ${Math.max(1, Math.round(upload.sizeBytes / 1024))}KB</small></span><button type="button" data-open-upload="${esc(upload.id)}">開く</button><button type="button" data-remove-upload="${esc(upload.id)}" aria-label="外す">×</button></li>`).join("");
    panel.innerHTML = `<section class="memo-card" aria-label="ファイル添付"><h2>ファイル添付</h2><p class="memo-muted">ファイル本体はコピーせず、「ファイル」基準パスからの相対パスだけを記録します。</p><ul class="memo-files">${files}${uploads}</ul>${files || uploads ? "" : '<p class="memo-empty">添付はまだありません。</p>'}<div class="memo-card-actions"><button type="button" class="primary" data-pick-file ${root?.available ? "" : "disabled"}>基準フォルダからファイルを選ぶ</button>${root?.available ? "" : '<small class="memo-warning">Tick Tock Tomeの設定で「ファイル」の基準パスを設定してください。</small>'}</div>${hint([["Enter", "ファイルを選ぶ"], [`${mod}V`, "クリップボード画像を添付"], ["Esc", "閉じる"], [`${mod}A`, "閉じる"]])}</section>`;
    panel.querySelector("[data-pick-file]")?.focus();
  } else if (state.mode === "list") {
    panel.innerHTML = `<section class="memo-card memo-list-card" aria-label="メモ一覧"><h2>メモ一覧</h2><input id="listInput" autocomplete="off" value="${esc(state.listQuery)}" placeholder="見出し・本文・タグで検索…"><ul id="memoList" class="memo-list" role="listbox"></ul>${hint([["↑↓", "選ぶ"], ["Enter", "開く"], ["Esc", "閉じる"], [`${mod}O`, "閉じる"]])}</section>`;
    renderList();
  }
}

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
      } catch (error) { setStatus(error.message, true); return; }
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

async function loadList() {
  try {
    const query = state.listQuery;
    const items = (await request(`/api/memos?q=${encodeURIComponent(query)}&limit=300`)).items;
    if (state.mode !== "list" || query !== state.listQuery) return;
    state.listItems = items; state.listIndex = Math.min(state.listIndex, Math.max(0, items.length - 1));
    renderList();
  } catch (error) { setStatus(error.message, true); }
}

function renderList() {
  const list = panel.querySelector("#memoList");
  if (!list) return;
  list.innerHTML = state.listItems.map((item, index) => `<li role="option" aria-selected="${index === state.listIndex}" class="${index === state.listIndex ? "active" : ""} ${item.id === state.memoId ? "current" : ""}" data-open-memo="${esc(item.id)}"><div><strong>${esc(item.title)}</strong><time>${esc(dateLabel(item.createdAt))}</time></div><small>${esc(item.excerpt || "（本文なし）")}</small><span class="memo-chip-row">${item.tagIds.map((id) => tagChip(id)).join("")}</span><button type="button" class="memo-delete" data-delete-memo="${esc(item.id)}" data-revision="${item.revision}" title="ゴミ箱へ移動">🗑</button></li>`).join("")
    || `<li class="memo-empty">${state.listQuery ? "一致するメモはありません。" : "まだメモはありません。"}</li>`;
  list.querySelector(".active")?.scrollIntoView({ block: "nearest" });
}

async function openFromList(id) {
  closeMode(false);
  if (id === state.memoId) { restoreSelection(); return; }
  await openTarget(id);
}

async function deleteMemo(id, revision) {
  if (!window.confirm("このメモをゴミ箱へ移動しますか？（Tick Tock Tomeの設定画面から復元できます）")) return;
  try {
    if (id === state.memoId) { await flush(); revision = state.revision; }
    await request(`/api/memos/${encodeURIComponent(id)}`, { method: "DELETE", body: JSON.stringify({ revision }) });
    if (id === state.memoId) { state.memoId = null; startNewMemo(); toggleMode("list"); }
    else await loadList();
  } catch (error) { setStatus(error.message, true); }
}

// ---- 添付 ----

async function pickFile() {
  try {
    setStatus("ファイル選択画面を開いています…");
    const file = (await request("/api/files:pick", { method: "POST", body: "{}" })).item;
    if (!state.files.some((item) => item.id === file.id)) state.files = [...state.files, file];
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
    } catch (error) { setStatus(error.message, true); }
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

panel.addEventListener("keydown", (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.target.id === "headingInput" && event.key === "Enter") { event.preventDefault(); closeMode(); }
  if (event.target.id === "tagInput") {
    const count = tagSuggestions().length;
    if (event.key === "ArrowDown") { event.preventDefault(); state.tagIndex = Math.min(count - 1, state.tagIndex + 1); renderTagSuggestions(); }
    else if (event.key === "ArrowUp") { event.preventDefault(); state.tagIndex = Math.max(-1, state.tagIndex - 1); renderTagSuggestions(); }
    else if (event.key === "Enter") { event.preventDefault(); addTagFromInput(); }
    else if (event.key === "Backspace" && !event.target.value && state.tagIds.length) { state.tagIds = state.tagIds.slice(0, -1); changed(); renderTagChips(); renderTagSuggestions(); }
  }
  if (event.target.id === "listInput") {
    if (event.key === "ArrowDown") { event.preventDefault(); state.listIndex = Math.min(state.listItems.length - 1, state.listIndex + 1); renderList(); }
    else if (event.key === "ArrowUp") { event.preventDefault(); state.listIndex = Math.max(0, state.listIndex - 1); renderList(); }
    else if (event.key === "Enter") { event.preventDefault(); const item = state.listItems[state.listIndex]; if (item) openFromList(item.id); }
  }
});

document.addEventListener("click", async (event) => {
  const target = event.target.closest("[data-mode],[data-command],[data-format],[data-remove-tag],[data-add-tag],[data-create-tag],[data-open-memo],[data-delete-memo],[data-pick-file],[data-open-file],[data-remove-file],[data-open-upload],[data-remove-upload]");
  if (!target) { if (state.mode && !panel.contains(event.target)) closeMode(false); return; }
  if (target.dataset.deleteMemo) { event.stopPropagation(); return deleteMemo(target.dataset.deleteMemo, Number(target.dataset.revision)); }
  if (target.dataset.mode) return toggleMode(target.dataset.mode);
  if (target.dataset.command === "new") { await flush(); return startNewMemo(); }
  if (target.dataset.format) { restoreSelectionIfNeeded(); return format(target.dataset.format); }
  if (target.dataset.removeTag) { state.tagIds = state.tagIds.filter((id) => id !== target.dataset.removeTag); changed(); renderTagChips(); renderTagSuggestions(); return panel.querySelector("#tagInput")?.focus(); }
  if (target.dataset.addTag) return addTag(target.dataset.addTag);
  if (target.hasAttribute("data-create-tag")) { state.tagIndex = -1; return addTagFromInput(); }
  if (target.dataset.openMemo) return openFromList(target.dataset.openMemo);
  if (target.hasAttribute("data-pick-file")) return pickFile();
  if (target.dataset.openFile) {
    const file = state.files.find((item) => item.id === target.dataset.openFile);
    try { await request(`/api/files/${encodeURIComponent(file.id)}:open`, { method: "POST", body: "{}" }); setStatus("OSの標準アプリで開きました。"); }
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
  try {
    const context = await request("/api/context");
    Object.assign(state, { tags: context.tags, categories: context.tagCategories, fileRoots: context.fileRoots });
  } catch (error) { setStatus(error.message, true); }
  const id = new URLSearchParams(location.search).get("id");
  await openTarget(id || "new");
}

window.PopNote = Object.freeze({ flush, openTarget });
initialize();
})();
