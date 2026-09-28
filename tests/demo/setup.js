// デモ用の保存先と、過去のメモを数件用意する（内容はすべて架空）。
const call = async (path, method = "GET", body) => (await fetch(path, { method, headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined })).json();
await call("/api/destinations:select", "POST", { path: basePath, datasetId: "デモ" });
const tag = async (name) => (await call("/api/tags", "POST", { name })).item.id;
const [meeting, idea, reading] = [await tag("会議"), await tag("アイデア"), await tag("読書")];
const day = (offset, hour) => { const d = new Date(); d.setDate(d.getDate() - offset); d.setHours(hour, 12, 0, 0); return d.toISOString(); };
const memos = [
  [day(1, 10), "週次ミーティング", "<div>進捗の共有と来週の予定</div>", [meeting]],
  [day(2, 16), "アプリ名の候補", "<div>短くて、Spotlightで見つけやすい名前</div>", [idea]],
  [day(4, 21), "『考えるための散歩道』メモ", "<div>歩くと考えがまとまる、という話</div>", [reading]],
  [day(6, 9), "朝のふりかえり", "<div>昨日やり残したことを先に片づける</div>", []],
];
for (const [createdAt, title, bodyHtml, tagIds] of memos) {
  const item = (await call("/api/memos", "POST", { createdAt, bodyHtml, tagIds })).item;
  await call(`/api/memos/${item.id}`, "PUT", { title, bodyHtml, tagIds, revision: item.revision });
}
return true;
