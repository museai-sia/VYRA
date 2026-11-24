# VYRA — ARCHITECTURE

## 構成

```
VYRA/
├── App/          VYRAApp.swift（ModelContainer設定）, ContentView.swift（タブ切替 + 起動時 Library 復元）, VYRATheme.swift（3色定義）
├── Models/       Video, VideoMetadata, DownloadCapability, DownloadItem（@Model）, DownloadFormat（+DownloadQuality）,
│                 DownloadState（遷移検証付き）, DownloadProgress, MediaFormatOption, DownloadError
├── ViewModels/   Home / VideoPreview / Download / Library / Settings（すべて @MainActor @Observable）
├── Views/        Home / Preview（+FormatSelection） / Download（Confirmation, Progress） / Library / Settings
├── Components/   GlassTabBar, URLInputView, PrimaryButton（+GlassIconButton）, VideoThumbnailView, DownloadProgressView
└── Services/     URLValidationService, MetadataProvider（+集約 VideoMetadataService）, MockMetadataProvider,
                  YtDlpIntegrationProvider（スタブ）, AuthorizedSourceProvider（骨格）, DirectMediaProvider,
                  DownloadService（protocol）, URLSessionDownloadEngine / StubDownloadEngine,
                  DownloadTaskManager, MediaFormatService（+DirectMediaResolver）,
                  FileStorageService, FileNameValidator
```

## 責務分離

- View: 表示と入力の受け渡しのみ。ビジネスロジックを持たない。
- ViewModel: 画面状態と操作ロジックを集約。取得手段の詳細には依存せず `VideoMetadataFetching` だけを見る。
- Service / Provider: 外部処理の境界。`MetadataProvider` ごとにソース対応を分離し、集約サービスが選択する。
- Model: 型安全なデータ定義。`DownloadItem` は SwiftData の `@Model`。取得元固有の構造を View に持ち込まない。

## データフロー（Phase 2・改訂仕様）

```
Home（URL入力）
  → HomeViewModel.state: validating
  → URLValidationService.validate（HTTPS必須、URLComponentsで検証、ソース種別分類、YouTubeは動画ID抽出、類似ホスト拒否）
  → state: loading
  → VideoMetadataService（集約）: 処理可能な最初の MetadataProvider を選択（無ければ unsupportedSource）
      ├ YtDlpIntegrationProvider（YouTube担当スタブ）: 常に integrationUnavailable（iOSでは実行不可）
      ├ AuthorizedSourceProvider（汎用HTTPS骨格）: 許可未確認 → permissionNotVerified
      └ MockMetadataProvider（テスト/プレビュー専用、アプリ既定には含めない）
  → state: loaded / failed（日本語の行動可能なエラーメッセージ、再試行・キャンセル可）
  → Video(metadata:) で Phase 1 の表示モデルへブリッジ
  → Video Preview（AsyncImage サムネイル、タイトル/作成者/時間/公開日/説明）
  → （Phase 1 のまま）形式・品質選択 → Download Confirmation → Download Progress（モック）→ Library
```

アプリのデフォルト配線では実データ取得プロバイダが未接続のため、実URLの取得は明確なエラーで失敗する。これは未完成の隠蔽ではなく仕様どおりの挙動であり、許可済みプロバイダを接続した時点で同じ流れで実データが表示される。

最近取得したメタデータは `HomeViewModel.recentFetches`（インメモリ、永続化なし、最小限の項目のみ）に保持し、Home の既存の最近セクションに表示する。

## ダウンロード・保存・Library（Phase 3）

```
Video Preview（実在する形式・品質のみ選択肢化: MediaFormatService）
  → Download Confirmation（ファイル名編集 = FileNameValidator で検証、判明している情報のみ表示）
  → DirectMediaResolver: 直接ファイル URL か検証（ページ URL はここで拒否）
  → DownloadTaskManager（状態遷移検証・進捗・キャンセル・再試行・複数タスク）
      → DownloadService（protocol）→ URLSessionDownloadEngine（一時ファイルへ実ダウンロード）
      → FileStorageService: Documents/VYRA へ移動（重複名解決、実測サイズ確認）
      → LibraryViewModel.registerCompleted: SwiftData へ保存 + Library 表示
  → Library: AVKit 再生 / ShareLink 共有 / 確認付き削除（ファイル + レコード同期）
```

- エンジン: yt-dlp は iOS で実行不可能（Phase 2 調査）。代替として直接 HTTPS
  メディアファイル URL 専用のネイティブ URLSession エンジンを採用した。
  エンジンは `DownloadService` プロトコルの背後にあり、テストでは
  `StubDownloadEngine` に差し替える。
- 状態: queued / preparing / downloading / completed / failed / cancelled
  （+ Phase 1/2 互換 waiting）。`paused` は再開を保証できないため実装しない。
- バックグラウンド: フォアグラウンドセッションのみ。アプリ終了で中断された
  ダウンロードは failed として扱い、偽の再開はしない。
- Phase 2 の `DownloadManager` プロトコルは `DownloadCapabilityEvaluating`
  に改名（能力評価専用）。実体マネージャは `DownloadTaskManager`。
  `DownloadCapability.evaluate` の原則（メタデータだけでは許可されない）は不変。

## 永続化の方式と選択理由（SwiftData）

Library の永続化には **SwiftData** を採用した。理由: (1) Phase 1 から
`DownloadItem` が `@Model` でアプリに ModelContainer が設定済みであり、
新規依存や移行コストなしに本格利用へ進められる。(2) 検索・ソート
（新しい順）が FetchDescriptor で型安全に書ける。(3) ファイル実体は
FileStorageService が持ち、SwiftData には相対パス等の管理情報だけを
持つため、責務が分離できる。Codable + JSON ファイル方式は、件数が増えた
場合の部分更新・整合性修復で不利なため採らない。

保存項目: fileID / filename / Documents 相対パス / 拡張子（format）/
mimeType / 実測 fileSize / savedAt（createdAt）/ duration? /
thumbnailURL? / sourceURL / state / downloadedBytes / errorMessage?。

起動時復元: Fetch → 完了項目のみ表示 → 実ファイル存在確認 → 無いレコードは
削除して修復 → 中断状態（queued/preparing/downloading）のレコードは
failed 化して Library から除外する。

## 並行性

メタデータ取得は `async/await` + `Task`。HomeViewModel は取得中タスクを保持し、重複実行防止と `cancel()` によるキャンセルを行う。
ダウンロードは `DownloadTaskManager`（@MainActor）がタスクごとに `Task` を保持し、エンジン（URLSession デリゲート / スタブ）からの進捗コールバックをメインアクターへ集約する。複数タスクの同時実行に対応する。
