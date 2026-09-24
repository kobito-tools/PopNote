# PopNote!

<img src="assets/icon/icon-1024.png" width="96" align="right" alt="">

PopNote! は、押したらポンッと出てきてすぐに書ける macOS 用のクイックメモです。会議中などに思いついたことを、ランチャーからワンアクションで書き留められます。

メモは [Tick Tock Tome](https://github.com/kobito-tools/TickTockTome) に保存されます。Tick Tock Tome を入れている Mac に PopNote! を追加すると、書いたメモが日記・時間割と同じカレンダーや横断検索に並びます。[OpenSesame!](https://github.com/kobito-tools/OpenSesame) に登録すると、キーを押すだけで開けます。

## 動作環境

- macOS 12 以降（Apple Silicon / Intel）
- セットアップ済みの Tick Tock Tome（`TickTockTome.app` を一度起動していること）
- Xcode Command Line Tools（`xcode-select --install`）

PopNote! は単体ではメモを保存しません。Tick Tock Tome が見つからない場合は、起動時に案内を表示して終了します。

## インストール

1. このリポジトリをクローンします。
2. `PopNote-Setup.command` をダブルクリックします。フォルダ直下に `PopNote!.app` ができます。
3. `PopNote!.app` をアプリケーションフォルダへ移動します。

「開発元を確認できない」と表示された場合は、Finder で `PopNote-Setup.command` を右クリックして「開く」を選びます。コマンドから作る場合は `./build.sh` を実行します。

## 使い方

起動すると、すぐに新しいメモが開きます。入力は自動で保存されるので、保存操作はいりません。

| 操作 | 内容 |
|---|---|
| `⌘N` | 新しいメモ。作成日時は押した時刻、見出しの初期値は「09月23日14時05分07秒のノート」 |
| `⌘O` | 過去のメモ一覧。見出し・本文・タグで絞り込み、`↑↓` と `Enter` で開く |
| `⌘T` | タグ設定モード。一致するタグを候補表示し、候補を選んで `Enter` で追加、候補を選ばずに `Enter` で「その他」に新しいタグを作成 |
| `⌘H` | 見出し編集モード |
| `⌘A` | ファイル添付。Tick Tock Tome の「ファイル」基準パスからの相対パスだけを記録。`⌘V` でクリップボードの画像も添付 |
| `⌘B`・`⌘U`・`⌘X`・`⌘I` | ボールド・下線・取り消し線・イタリック |
| `⌘Q` | PopNote! を閉じる（保存待ちの内容を書き込んでから閉じます） |

- モードは、同じショートカットをもう一度押すか `Esc` で閉じます。
- 本文に貼り付けた画像は、本文中に表示され、添付にも加わります。
- `⌘X` と `⌘A` は装飾と添付に使うため、カットと全選択は「編集」メニューから選びます。
- 「ウインドウ」メニューの「常に手前に表示」で、ほかのアプリより前面に固定できます。

### ランチャーから開く

OpenSesame! などのランチャーには `PopNote!.app` を登録します。URL にも対応しています。

| URL | 動作 |
|---|---|
| `popnote://new` | 新しいメモを開く |
| `popnote://open/<メモID>` | 指定したメモを開く |

すでに起動している場合は、同じウィンドウで切り替えます。

## Tick Tock Tome との連携

- メモは作成日時の日付で Tick Tock Tome のカレンダーに表示され、横断検索、ファイル一覧の関連作業、活動分析の元データにも加わります。
- Tick Tock Tome 画面上部の「✎」やカレンダーのメモから、PopNote! の該当メモを開けます。
- 削除したメモは、Tick Tock Tome の設定画面のゴミ箱から復元できます。
- PopNote! だけを開いたときは、Tick Tock Tome のウィンドウを出さずにローカルサーバーだけを使います。サーバーは、Tick Tock Tome と PopNote! の両方を閉じたときに止まります。

### 仕組み

```text
ランチャー / popnote:// URL
  ↓
PopNote!.app
  ├─ 画面（web/）を popnote-page:// でアプリ内から表示
  └─ /api/… を Tick Tock Tome の連携 API へ中継（専用トークンを付与）
        ↓
Tick Tock Tome ローカルサーバー（127.0.0.1） → SQLite
```

1. PopNote! は、バンドル ID `local.ticktocktome.desktop` からインストール済みの `TickTockTome.app` を探します。
2. Tick Tock Tome の `scripts/companion-connect.js popnote` を実行します。サーバーが止まっていれば起動し、PopNote! 専用トークンを受け取ります。
3. トークンは初回に Tick Tock Tome の `config/integrations.json` へ登録されます。権限は `memo:read`・`memo:write` だけで、日記や設定は読み書きできません。

PopNote! は Tick Tock Tome のデータベースや設定ファイルを直接開きません。トークンは Swift 側だけで扱い、画面の JavaScript には渡しません。

## プライバシー

PopNote! は外部と通信しません。通信先は同じ Mac の Tick Tock Tome（`127.0.0.1`）だけです。メモ本文や添付ファイルの実体は Tick Tock Tome のデータ保存先にあり、PopNote! 自体はウィンドウ位置と「常に手前に表示」の設定だけを保存します。

## アンインストール

1. `PopNote!.app` をゴミ箱へ移動します。
2. 連携の許可も取り消す場合は、Tick Tock Tome の `config/integrations.json`（macOS では `~/Library/Application Support/TickTockTome/config/`）から `"id": "popnote"` の項目を削除します。

書いたメモは Tick Tock Tome に残ります。

## 開発について

| パス | 内容 |
|---|---|
| `Sources/PopNoteApp.swift` | ウィンドウ、メニュー、URL の受け取り、終了前の保存 |
| `Sources/TickTockTomeLink.swift` | Tick Tock Tome の検出、接続、サーバー停止 |
| `Sources/PageSchemeHandler.swift` | 画面ファイルの配信と連携 API への中継 |
| `web/` | メモ画面（HTML・CSS・JavaScript） |
| `assets/icon/` | アイコン（`icon.svg` が原本） |
| `build.sh` | ユニバーサルバイナリの `PopNote!.app` を作成 |

連携 API の仕様は、Tick Tock Tome の `docs/INTEGRATIONS.md` にあります。

## ライセンス

[MIT License](LICENSE)
