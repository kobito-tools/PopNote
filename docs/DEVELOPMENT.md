# 開発について

PopNote! のビルド方法、ソースコードの構成、Tomelet との連携の仕組みをまとめます。利用方法は [README](../README.md) を参照してください。

## ビルド

Xcode Command Line Tools（`xcode-select --install`）が必要です。

```bash
./build.sh                    # フォルダ直下に PopNote!.app（ユニバーサルバイナリ）を作成
./tests/run.sh                # 保存先の作成からメモの読み書きまでのテスト
./scripts/package-release.sh  # Releases 用の dist/PopNote_<版>_universal.zip（GitHub は名前の「!」を使えないため付けない） を作成
./tests/demo/record.sh        # README のデモGIF（docs/images/demo.gif）を撮り直す（ffmpeg が必要）
```

版番号は `build.sh` の `VERSION` で指定します。`PopNote-Setup.command` は `build.sh` を呼び出すだけの、ソースから使う人向けの入口です。

デモGIFは、一時フォルダの保存先で本物の画面を画面外のウィンドウに表示し、演出（`tests/demo/director.js`）を1コマずつ進めながら撮影します。PopNote! 本体の設定やメモには触れません。

## ソースコードの構成

| パス | 内容 |
|---|---|
| `Sources/PopNoteApp.swift` | ウィンドウ、メニュー、URL の受け取り、終了前の保存 |
| `Sources/MemoRouter.swift` | 保存先の管理、使用中の印、ファイル選択 |
| `Sources/LocalMemoStore.swift` | 保存先の SQLite へのメモの読み書き（Tomelet と同じSQL） |
| `Sources/Dataset.swift` | `.kobito-tools/` の形式、データセットキー、使用中の印 |
| `Sources/TagStore.swift` | 共有タグ（`.kobito-tools/Tags/tags.json`）とDBの写しの同期（Tomelet の `scripts/tag-store.js` と同じ規則） |
| `Sources/MemoRules.swift` | 本文の整形、見出しの初期値、入力の検証（Tomelet と同じ規則） |
| `Sources/TickTockTomeLink.swift` | Tomelet の検出と、Tomelet が開いている基準パスの取得 |
| `Sources/PageSchemeHandler.swift` | 画面ファイルの配信と API の受け渡し |
| `web/` | メモ画面（HTML・CSS・JavaScript） |
| `schema/` | Tomelet の DB 更新の写し（`scripts/sync-schema.sh <Tomeletのフォルダ>` で更新） |
| `tests/run.sh` | 保存先の作成からメモの読み書きまでを、画面と同じ経路で確かめるテスト |
| `build.sh` | ユニバーサルバイナリの `PopNote!.app` を作成 |

Tomelet に DB 更新が増えたら `scripts/sync-schema.sh` で `schema/` を更新し、`tests/run.sh` を実行してください。連携 API の仕様は、Tomelet の `docs/INTEGRATIONS.md` と `docs/BASE_PATH_FOR_COMPANIONS.md` にあります。

## Tomelet との連携の仕組み

```text
PopNote!.app
  ├─ 画面（web/）を popnote-page:// でアプリ内から表示
  └─ /api/… を MemoRouter → LocalMemoStore が処理し、保存先の .kobito-tools/PopNote/ を直接読み書き（SQLite）
Tomelet ─ PopNote/database を読み取り専用で開き、「本アプリでも表示する」ときだけカレンダー・検索に表示
```

保存先フォルダの中身（Tomelet の `scripts/dataset.js` と同じ規則）：

```text
<保存先>/.kobito-tools/
├── dataset.json                   format: "kobito-tools-dataset"・ID（Tomelet と共通）
├── PopNote/
│   ├── lock.json                  開いている間だけ置く使用中の印
│   ├── database/popnote.sqlite3   メモ・タグの写し・添付の登録情報（表の形は Tomelet と同じ）
│   └── uploads/                   貼り付けた画像
├── Tags/tags.json                 Tomelet と共有するタグ
└── Tomelet/                       Tomelet のデータ（PopNote! は触れない）
```

- **新しいDB**は、Tomelet と同じDB更新（`schema/`、Tomelet の `migrations/` の写し）で作ります。既存のDBは更新しません。表の形を Tomelet と同じにしておくことで、Tomelet が読み取り専用で開いて表示できます。
- **使用中の印**：`PopNote/lock.json` に `app: "popnote"` の印を置き、30秒ごとに更新します。Tomelet の印は `Tomelet/` にあるので互いに干渉しません。別のMacの PopNote! が使用中の保存先には書き込みません。
- **共有タグ**：保存先を開いたとき（`context`）と、タグを作る前後に `Tags/tags.json` と同期します。同じIDは `revision` の大きい方を採り、タグは完全削除しません（詳しくは Tomelet の `docs/BASE_PATH_FOR_COMPANIONS.md`）。
- **旧形式**：`.TickTockTome/` だけがあるフォルダは、Tomelet で一度開くと `.kobito-tools/` へ移行されます。PopNote! は移行せず、その旨を案内します。
- **Tomelet との通信**：Tomelet が起動しているときだけ、`scripts/companion-connect.js popnote --no-launch` で専用トークンを受け取り、`context` から Tomelet が開いている基準パスを取得して保存先の候補に出します。メモは Tomelet へ送りません。
