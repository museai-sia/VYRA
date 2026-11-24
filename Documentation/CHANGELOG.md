# CHANGELOG

## [1.1.0] — Phase 2（改訂仕様: MetadataProvider 方式）

- `URLValidationService` を追加・一般化: URLComponents による構造化解析、HTTPS必須、ソース種別分類（youtube / genericHTTPS / unsupported）、類似ホスト拒否。YouTube 形式（watch / youtu.be / shorts / embed / live）と動画ID検証（11文字）を維持。
- `VideoMetadata` モデルを追加（id, title, creatorName, sourceName, thumbnailURL?, durationSeconds, publishedAt?, description?, sourceURL, availableFormats?）。取得できない項目は nil（推測で埋めない）。
- `MetadataProvider` protocol と集約サービス `VideoMetadataService` を追加。プロバイダ: `MockMetadataProvider`（テスト/プレビュー専用、明示的にモック）、`YtDlpIntegrationProvider`（インターフェーススタブ、常に integrationUnavailable）、`AuthorizedSourceProvider`（許可確認済みの場合のみ返す骨格、デフォルト未確認）。
- アプリのデフォルト配線は集約（Authorized + YtDlp スタブ）。実URLは明確なエラーで失敗し、モックを実データとして見せない。
- `Models/DownloadCapability.swift` を追加（Phase 3 への設計のみ）: DownloadSource / AvailableMediaFormat / DownloadPermission（デフォルト unknown）/ DownloadCapability / DownloadManager プレースホルダ。ダウンロード実装はなし。
- HomeViewModel: FetchState、重複実行防止、キャンセル、再試行、recentFetches（インメモリ）、エラー種別ごとの日本語メッセージ。
- VideoPreviewViewModel / Views: メタデータ表示（AsyncImage サムネイル、公開日・説明）、再試行ボタン、最近取得表示。Phase 1 のデザインと形式・品質ロジックは不変。
- テスト: URLValidationTests 19件、VideoMetadataTests（プロバイダ/集約/権限）15件、ViewModelTests 11件を追加・改訂。Secrets・外部ネットワークなしで全件実行可能。
- ドキュメント: MASTER / ARCHITECTURE / DESIGN_SYSTEM / DEVELOPMENT_RULES / PHASE_2_METADATA / AGENTS / README を改訂し、`HANDOFF/PHASE_2_HANDOFF.md` を作成。

※ 方針変更の経緯: 当初 Phase 2 は YouTube Data API v3 方式で実装を進めたが、改訂仕様により **YouTube Data API 依存を全て撤去**した（サービス・DTO・APIキー関連の記述を削除）。
※ yt-dlp は改訂仕様に基づき調査した結果、iOS では実現不可能・不適合（CPython/ffmpeg/JSランタイム要件、サンドボックスの外部プロセス禁止、n/sig 解読は署名回避）と判断し、**組み込んでいない**。根拠は `Phases/PHASE_2_METADATA.md`。
※ ビルド・テスト結果（2026-11-24）: GitHub Actions run 45381348474（PR #1）でビルド成功・テスト76件全件成功（Unit 72件 + UI 4件）。Xcode 26.6 / iOS Simulator SDK 26.5 / iPhone 17 Pro。
※ 途中経過: 公式API方式時点の run 45379350930 でもビルド・テスト成功（69件）を確認したが、その実装は改訂仕様により置き換え済み。

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
