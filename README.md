# KICneo

KICEvents-iOS（非公開）の更新版です。神戸電子専門学校の学生アカウントでログインすると、学生ポータルの出欠・出席率・時間割・企業説明会・公欠／就職活動・学生証・成績を iPhone で確認できます。

KICEvents-iOS では、学校サイトをスクレイピングし、Gemini API で整形したデータを Supabase に保存してアプリに配信していました。KICneo ではこの構成をやめ、サーバーとデータベースを使わずに、アプリがポータルへ直接アクセスする方式に変更しています。学校のデータや個人情報を外部のサーバーに置かないため、データはすべて端末の中で完結します。

## 技術

| 項目 | 内容 |
|---|---|
| UI | SwiftUI（iOS 26） |
| 並行処理 | Swift Concurrency（async/await、actor） |
| HTML 解析 | [SwiftSoup](https://github.com/scinfu/SwiftSoup)（Swift Package Manager） |
| 認証情報 | Keychain（この端末のみ） |
| 保存 | Caches（アカウントごとの JSON）、UserDefaults（取得日時） |

### ポータルとの通信

ポータルは ASP.NET WebForms で作られており、API はありません。`SchoolClient`（actor）がブラウザと同じ手順でページを取得し、返ってきた HTML を解析します。

- **postback の再現**：画面遷移のたびに必要な `__VIEWSTATE` などの hidden フィールドをページから読み取り、`__EVENTTARGET` / `__EVENTARGUMENT` とあわせて次のリクエストに引き継ぎます。submit・image・`__doPostBack` のリンクなど、ボタンの種類ごとに送信内容を変えています。
- **通信の順序制御**：ポータルは同じセッション内で表示中の画面（日別／集計など）を覚えているため、状態に依存する出欠の通信は actor 内で 1 つずつ実行します。HTML の解析は actor の外で並列に行います。
- **セッション切れ**：ログインページが返ってきた場合は、Keychain の情報で再ログインして 1 回だけやり直します。
- **説明会の申込**：申込ボタンを押した後は、通信エラーでも自動でやり直しません。申込が完了したかどうかは、一覧の申込状況を取り直して確認します。

### キャッシュ

- 前回取得したデータをアカウントごとに保存し、起動直後はそれを表示してから裏で更新します。内容が変わったときだけ画面を更新します。
- データの種類ごとに有効期限を設けています（説明会 15 分、時間割・成績 6 時間、学生証 7 日など）。期限内のデータは起動時に取得し直しません。
- 月が終わって 14 日たった出欠と月の出席率は確定とみなし、再取得しません。
- ログアウト時には、キャッシュ・取得記録・Keychain をすべて削除します。

### デモモード

Debug ビルドで起動引数に `-demo` を付けると、架空のデータ（`Models/DemoData.swift`）で起動します。ポータルには接続せず、保存済みのデータや Keychain にも触れません。

## ファイル構成

```
KICneo/
├── KICEvents.xcodeproj
├── KICEventsApp.swift
├── ContentView.swift        # タブ構成と起動処理
├── Models/                  # データの型、デモ用データ
├── ViewModels/
│   ├── SchoolViewModel.swift   # ポータルのデータの取得・キャッシュ・画面の状態
│   └── EventViewModel.swift    # 説明会の一覧・絞り込み・保存
├── Servics/
│   ├── SchoolClient.swift      # ポータルとの通信と HTML 解析
│   ├── KeychainService.swift
│   ├── AccountCache.swift      # アカウントごとのキャッシュ
│   └── FetchLog.swift          # 取得日時と有効期限
├── Components/              # 画面と UI 部品
└── Assets.xcassets
Design/                      # アプリアイコンの元データ（SVG）
```

## 動作環境

- iOS 26.2 以降
- Xcode 26.2 以降

`KICneo/KICEvents.xcodeproj` を開き、Signing & Capabilities で Team を選んで実行します。SwiftSoup は Swift Package Manager で自動的に取得されます。ログインには神戸電子専門学校の学生アカウントが必要です（アカウントがない場合はデモモードで動作を確認できます）。
