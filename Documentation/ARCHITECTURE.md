# VYRA — ARCHITECTURE

## 構成

```
VYRA/
├── App/          VYRAApp.swift（ModelContainer設定）, ContentView.swift（タブ切替）, VYRATheme.swift（3色定義）
├── Models/       Video, DownloadItem（@Model）, DownloadFormat（+DownloadQuality）, DownloadState
├── ViewModels/   Home / VideoPreview / Download / Library / Settings（すべて @MainActor @Observable）
├── Views/        Home / Preview（+FormatSelection） / Download（Confirmation, Progress） / Library / Settings
├── Components/   GlassTabBar, URLInputView, PrimaryButton（+GlassIconButton）, VideoThumbnailView, DownloadProgressView
└── Services/     VideoMetadataService, DownloadService（protocol + Mock実装）
```

## 責務分離

- View: 表示と入力の受け渡しのみ。ビジネスロジックを持たない。
- ViewModel: 画面状態と操作ロジックを集約。
- Service: 外部処理の境界。protocol で定義し、Phase 1 は Mock 実装のみ。実サービスは同じ protocol で差し替え可能。
- Model: 型安全なデータ定義。`DownloadItem` は SwiftData の `@Model`。

## データフロー

Home（URL入力・検証）→ モックメタデータ取得 → Video Preview（形式・品質選択）→ Download Confirmation → Download Progress（モック進捗、状態遷移 Waiting/Downloading/Completed/Failed/Cancelled）→ 完了時に Library へ追加。

## 並行性

メタデータ取得は `async/await`、モック進捗は `Task` ループ + `tick()` で進める。進捗の単体テストは `tick()` を直接呼んで決定的に検証する。
