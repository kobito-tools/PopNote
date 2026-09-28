#!/bin/zsh
# PopNote!の保存処理を、画面と同じ経路で確かめる。保存先（.kobito-tools）の形と共有タグも確認する。
set -euo pipefail
cd "${0:A:h}/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/base/docs" && echo agenda > "$work/base/docs/agenda.txt"
# 本体が先に書き出した共有タグ（PopNote!は取り込んで使う）。dataset.json の無い .kobito-tools への作成も確かめる。
mkdir -p "$work/base/.kobito-tools/Tags"
cat > "$work/base/.kobito-tools/Tags/tags.json" <<'JSON'
{"format": "kobito-tags", "schemaVersion": 1, "revision": 4, "categories": [],
 "tags": [{"id": "tag-from-tomelet", "categoryId": "theme", "name": "本体のタグ", "description": "", "displayOrder": 1, "revision": 2, "archivedAt": null, "deletedAt": null}]}
JSON
cp -R web schema "$work/"
cp assets/icon/icon.svg "$work/web/icon.svg"
# PopNoteApp.swift（@main）以外をハーネスと一緒にコンパイルする。
if ! xcrun swiftc -o "$work/harness" Sources/{SQLiteDatabase,Dataset,TagStore,MemoRules,LocalMemoStore,TickTockTomeLink,MemoRouter,PageSchemeHandler}.swift \
  tests/harness/main.swift -framework Cocoa -framework WebKit -lsqlite3 > "$work/build.log" 2>&1; then
  cat "$work/build.log"; exit 1
fi
# 保存先の記録はハーネス専用の設定領域に置き、実際のPopNote!の設定には触れない。
defaults delete harness >/dev/null 2>&1 || true
"$work/harness" tests/store-scenario.js "$work/base"
defaults delete harness >/dev/null 2>&1 || true

# Tomeletと同じ表の形で .kobito-tools/PopNote/ に保存し、共有タグを書き出したか
python3 - "$work/base/.kobito-tools" <<'PY'
import json, sqlite3, sys, os
root = sys.argv[1]
dataset = json.load(open(os.path.join(root, "dataset.json")))
assert dataset["format"] == "kobito-tools-dataset" and dataset["datasetId"] == "テスト用", dataset
for name in ["database", "uploads"]: assert os.path.isdir(os.path.join(root, "PopNote", name)), name
assert not os.path.exists(os.path.join(root, "Tomelet")), "本体のフォルダには触れない"
db = sqlite3.connect(os.path.join(root, "PopNote", "database", "popnote.sqlite3"))
applied = [row[0] for row in db.execute("SELECT version FROM schema_migrations ORDER BY version")]
bundled = sorted(name for name in os.listdir("schema") if name.endswith(".sql"))
assert applied == bundled, (applied, bundled)
assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
assert db.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
print(f"ok - Tomeletと同じ表の形（DB更新 {len(applied)}件・整合性OK）")
tags = json.load(open(os.path.join(root, "Tags", "tags.json")))
names = {tag["name"] for tag in tags["tags"]}
assert tags["format"] == "kobito-tags" and tags["revision"] > 4 and {"本体のタグ", "会議"} <= names, tags
assert len(tags["categories"]) >= 8, "分類も共有する"
db_names = {row[0] for row in db.execute("SELECT name FROM tags")}
assert names == db_names, (names, db_names)
print("ok - 共有タグ（Tags/tags.json）と写しが一致")
PY
