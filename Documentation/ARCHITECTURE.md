# VYRA — ARCHITECTURE

## 構成

```
VYRA/
├── App/          VYRAApp.swift（ModelContainer設定）, ContentView.swift（タブ切替）, VYRATheme.swift（3色定義）
├── Models/       Video, VideoMetadata, DownloadCapability（Phase 3 設計）, DownloadItem（@Model）, DownloadFormat（+DownloadQuality）, DownloadState
├── ViewModels/   Home / VideoPreview / Download / Library / Settings（すべて @MainActor @Observable）
├── Views/        Home / Preview（+FormatSelection） / Download（Confirmation, Progress） / Library / Settings
├── Components/   GlassTabBar, URLInputView, PrimaryButton（+GlassIconButton）, VideoThumbnailView, DownloadProgressView
└── Services/     URLValidationService, MetadataProvider（+集約 VideoMetadataService）, MockMetadataProvider,
                  YtDlpIntegrationProvider（スタブ）, AuthorizedSourceProvider（骨格）, DownloadService（protocol + Mock）
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

## Phase 3 への接続（設計のみ）

`DownloadCapability.evaluate(metadata:permission:)`: メタデータだけでは許可は得られない。permission が verified で形式が判明している場合のみ `isDownloadable == true`。`DownloadManager` protocol は能力評価のプレースホルダのみで、ダウンロード実行APIは Phase 2 には存在しない。

## 並行性

メタデータ取得は `async/await` + `Task`。HomeViewModel は取得中タスクを保持し、重複実行防止と `cancel()` によるキャンセルを行う。
