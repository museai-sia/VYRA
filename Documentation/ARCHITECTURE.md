# VYRA — ARCHITECTURE

## 構成

```
VYRA/
├── App/          VYRAApp.swift（ModelContainer設定）, ContentView.swift（タブ切替）, VYRATheme.swift（3色定義）
├── Models/       Video, VideoMetadata（Phase 2）, DownloadItem（@Model）, DownloadFormat（+DownloadQuality）, DownloadState
│   └── API/      YouTubeAPIResponse.swift（YouTube Data API v3 の DTO、アプリ内部モデルと分離）
├── ViewModels/   Home / VideoPreview / Download / Library / Settings（すべて @MainActor @Observable）
├── Views/        Home / Preview（+FormatSelection） / Download（Confirmation, Progress） / Library / Settings
├── Components/   GlassTabBar, URLInputView, PrimaryButton（+GlassIconButton）, VideoThumbnailView, DownloadProgressView
└── Services/     URLValidationService, VideoMetadataService（protocol + Mock + Unconfigured）, YouTubeDataAPIService, DownloadService（protocol + Mock実装）
```

## 責務分離

- View: 表示と入力の受け渡しのみ。ビジネスロジックを持たない。
- ViewModel: 画面状態と操作ロジックを集約。API通信の詳細やJSON構造には依存しない。
- Service: 外部処理の境界。protocol で定義し、Mock / 実サービス / 未設定サービスを差し替え可能。
- Model: 型安全なデータ定義。`DownloadItem` は SwiftData の `@Model`。API DTO（`Models/API/`）とアプリ内部モデル（`VideoMetadata`）は分離し、DTO を View に持ち込まない。

## データフロー（Phase 2）

```
Home（URL入力）
  → HomeViewModel.state: validating
  → URLValidationService.parse（URLComponents でホスト/パス/クエリを検証、動画ID抽出）
  → state: loading
  → VideoMetadataService.fetchMetadata(for:)
      ├ YouTubeDataAPIService（キー設定時）: GET youtube/v3/videos?part=snippet,contentDetails
      │    → YouTubeVideosListResponse（DTO）→ VideoMetadata へ変換
      ├ UnconfiguredVideoMetadataService（キー未設定時）: apiKeyMissing で失敗
      └ MockVideoMetadataService（テスト/プレビュー用）
  → state: loaded / failed（日本語の行動可能なエラーメッセージ、再試行・キャンセル可）
  → Video(metadata:) で Phase 1 の表示モデルへブリッジ
  → Video Preview（AsyncImage サムネイル、タイトル/チャンネル/時間/公開日/説明）
  → （Phase 1 のまま）形式・品質選択 → Download Confirmation → Download Progress（モック）→ Library
```

最近取得したメタデータは `HomeViewModel.recentFetches`（インメモリ、永続化なし、最小限の項目のみ）に保持し、Home の既存の最近セクションに表示する。

## 並行性

メタデータ取得は `async/await` + `Task`。HomeViewModel は取得中タスクを保持し、重複実行防止と `cancel()` によるキャンセルを行う。HTTP層は `HTTPClient` protocol（URLSession が適合）で抽象化し、テストではスタブ差し替えで通信なしに検証する。
