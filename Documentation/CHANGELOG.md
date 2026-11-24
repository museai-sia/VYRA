# CHANGELOG

## [1.1.0] — Phase 2（メタデータ取得）

- `URLValidationService` を追加: URLComponents による YouTube URL の構造化解析（watch / youtu.be / shorts / embed / live）、動画ID抽出・検証、類似ホスト拒否、エラー種別の分離。
- `VideoMetadata` モデルと YouTube Data API v3 用 DTO（`Models/API/YouTubeAPIResponse.swift`）を追加。ISO8601 duration / 日時のパース、サムネイル優先順位（maxres>high>medium>default）。
- `VideoMetadataService` protocol の戻り値を `Video` から `VideoMetadata` に変更。`Video` に任意ブリッジ項目（externalID / thumbnailURL / publishedAt / descriptionText、すべてデフォルト付き）を追加し `Video(metadata:)` を追加。
- `YouTubeDataAPIService` を追加: 公式APIのみ、async/await、HTTPClient 抽象化、HTTP/クォータ/通信/デコード/キャンセルエラーの分離。APIキーは Info.plist `YouTubeAPIKey` / 環境変数 `YOUTUBE_API_KEY` のみ（直書きなし）。キー未設定時は `UnconfiguredVideoMetadataService` が apiKeyMissing で失敗（モックを実データとして見せない）。
- HomeViewModel: FetchState、重複実行防止、キャンセル、再試行、recentFetches（インメモリ履歴）、エラー種別ごとの日本語メッセージ。
- VideoPreviewViewModel: メタデータ由来の表示データ（タイトル/チャンネル/時間/公開日/サムネイルURL/説明）を公開。形式・品質ロジックは Phase 1 のまま不変。
- Views（最小変更のみ）: Home の見出し文言から「（Phase 1: モック）」を除去し YouTube URL 前提に更新、失敗時の再試行ボタン、最近取得したメタデータ表示。Video Preview に AsyncImage サムネイル、公開日・説明表示。
- テスト追加: URLValidationTests（14件）、VideoMetadataTests（15件、スタブHTTP）、ViewModelTests（9件）。Phase 1 のモックメタデータテストは YouTube URL 前提に意図を更新（件数は維持）。
- ドキュメント更新: MASTER / ARCHITECTURE / PHASE_2_METADATA / AGENTS / README、`HANDOFF/PHASE_2_HANDOFF.md` を新規作成。

※ ビルド・テスト結果（2026-11-24）: GitHub Actions run 45379350930（PR #1）でビルド成功・テスト69件全件成功（Unit 65件 + UI 4件）を確認。Xcode 26.6 / iOS Simulator SDK 26.5 / iPhone 17 Pro。
※ 実API通信は GitHub Secret `YOUTUBE_API_KEY` 未設定のため未実施・未検証。
※ yt-dlp は指示書 §5 により不採用（作業中の要望に対しても公式APIで代替）。

## [1.0.0] — Phase 1

- VYRA プロジェクトを新規構築（SwiftUI / MVVM / SwiftData、iOS 26.0）。
- 全画面を実装: Home、Video Preview、Format Selection、Download Confirmation、Download Progress、Library、Settings。
- Liquid Glass フローティングタブバー（Home / Library / Settings）を実装。
- URL入力・貼り付け・クリア・バリデーション、モック動画情報表示、形式/品質選択（M4A時は品質非表示）、モック進捗（キャンセル/完了/失敗）、ライブラリへのモック追加・削除を実装。
- Unit Test / UI Test を追加。
- GitHub Actions ワークフロー（macos-26、Simulatorビルド、テスト、Artifacts保存）を追加。
- ドキュメント一式（MASTER / ARCHITECTURE / DESIGN_SYSTEM / DEVELOPMENT_RULES / Phases / HANDOFF）を作成。

※ ビルド・テスト結果（2026-11-24）: GitHub Actions run 45372323350 でビルド成功・テスト31件全件成功を確認。詳細は HANDOFF 参照。
- 修正履歴: SDKROOT=iphoneos の追加（宛先エラー修正）、DownloadProgressScreen.swift への改名（同名ファイル衝突修正）、スクリーンショット取得ステップの改善（シミュレータ起動+アプリ起動で Home を撮影）。
