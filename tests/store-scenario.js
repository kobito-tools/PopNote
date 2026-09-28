// PopNote!単独（Tomeletなし）で保存先（.kobito-tools/PopNote）を作り、メモAPIを一通り使う。basePathはハーネスから渡される。
const results = [];
const check = (label, condition, detail = "") => { if (!condition) throw new Error(`${label} ${detail}`); results.push(`ok - ${label}`); };
const call = async (path, method = "GET", body) => {
  const response = await fetch(path, { method, headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
  let json = {};
  try { json = await response.clone().json(); } catch { /* 画像など */ }
  return { status: response.status, json, response };
};

check("保存先が未選択", (await call("/api/destinations")).json.current === null);
let r = await call("/api/memos", "POST", { bodyHtml: "x" });
check("保存先なしの保存は428", r.status === 428 && r.json.destinationRequired === true, r.status);
check("新しいフォルダはIDが必要", (await call("/api/destinations:select", "POST", { path: basePath })).status === 400);
r = await call("/api/destinations:select", "POST", { path: basePath, datasetId: "テスト用" });
check("保存先を作成して選択", r.status === 200 && r.json.current.id === "テスト用" && r.json.mode === "local", JSON.stringify(r.json));
r = await call("/api/context");
check("本体と同じタグ分類（8分類）", r.json.tagCategories.length === 8 && r.json.dataset.id === "テスト用");
check("本体が書き出した共有タグを取り込む", r.json.tags.some((item) => item.id === "tag-from-tomelet" && item.name === "本体のタグ"));
check("共有タグと同名なら再利用", (await call("/api/tags", "POST", { name: "本体のタグ" })).json.item.id === "tag-from-tomelet");
const tag = (await call("/api/tags", "POST", { name: "会議" })).json.item;
check("新しいタグは「その他」", tag.categoryId === "other" && tag.created === true);
check("同名タグは再利用", (await call("/api/tags", "POST", { name: "会議" })).json.item.id === tag.id);

const createdAt = new Date(Date.now() - 5000).toISOString();
r = await call("/api/memos", "POST", { createdAt, bodyHtml: "<div onclick='x'>決定<b>事項</b></div><script>bad()</script>", tagIds: [tag.id] });
const memo = r.json.item;
check("作成と本文の整形", r.status === 201 && memo.bodyHtml === "<div>決定<b>事項</b></div>bad()", memo.bodyHtml);
check("見出しの初期値", /^\d{2}月\d{2}日\d{2}時\d{2}分\d{2}秒のノート$/.test(memo.title), memo.title);
check("作成日時を保持", memo.createdAt === createdAt, memo.createdAt);
check("未来の作成日時は拒否", (await call("/api/memos", "POST", { createdAt: new Date(Date.now() + 3600000).toISOString() })).status === 400);

const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const upload = (await call("/api/uploads", "POST", { name: "shot.png", mimeType: "image/png", base64: png })).json.item;
r = await call(`/api/v1/uploads/${upload.id}/content`);
check("画像の保存と表示", r.status === 200 && r.response.headers.get("Content-Type") === "image/png");
check("画像以外は拒否", (await call("/api/uploads", "POST", { name: "a.pdf", mimeType: "application/pdf", base64: "JVBERg==" })).status === 400);
const file = (await call("/api/files:reference", "POST", { relativePath: "docs/agenda.txt" })).json.item;
check("添付は保存先からの相対パス", file.rootId === "base" && file.relativePath === "docs/agenda.txt");
check("保存先の外は拒否", (await call("/api/files:reference", "POST", { relativePath: "../outside.txt" })).status === 400);

r = await call(`/api/memos/${memo.id}`, "PUT", { title: "定例会議", bodyHtml: `${memo.bodyHtml}<img src="/api/v1/uploads/${upload.id}/content" alt="">`, tagIds: [tag.id], managedFileIds: [file.id], revision: memo.revision });
check("更新（本文の画像も添付に入る）", r.status === 200 && r.json.item.revision === 2 && r.json.item.uploadIds.length === 1 && r.json.item.files.length === 1);
check("古い版での更新は409", (await call(`/api/memos/${memo.id}`, "PUT", { title: "古い", revision: 1 })).status === 409);
const search = async (q) => (await call(`/api/memos?q=${encodeURIComponent(q)}`)).json.items.length;
check("本文・タグ名で検索", (await search("決定")) === 1 && (await search("会議")) === 1 && (await search("?%_")) === 0);
const time = Date.parse(createdAt);
check("期間で絞り込み（カレンダー用）", (await call(`/api/memos?from=${new Date(time - 1000).toISOString()}&to=${new Date(time + 1000).toISOString()}`)).json.items.length === 1
  && (await call(`/api/memos?from=${new Date(time + 1000).toISOString()}`)).json.items.length === 0);
const other = (await call("/api/memos", "POST", { bodyHtml: "消す" })).json.item;
check("ゴミ箱へ移動", (await call(`/api/memos/${other.id}`, "DELETE", { revision: other.revision })).status === 200 && (await call(`/api/memos/${other.id}`)).status === 404);
return results.join("\n");
