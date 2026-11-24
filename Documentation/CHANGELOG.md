# CHANGELOG

## [1.2.0] — Phase 3（ダウンロード・保存・Library 完成）

- ダウンロードエンジン: yt-dlp は組み込まず（iOS 実行不可能、Phase 2 調査を踏襲）、直接 HTTPS メディアファイル URL 専用の `URLSessionDownloadEngine` を `DownloadService` プロトコルの背後に実装。ページ URL は `DirectMediaResolver` が開始前に拒否し、明確なエラーで失敗する。
- `DirectMediaProvider` を追加し、集約の既定配線に接続: 直接ファイル URL（.mp4/.mov/.m4a）は HEAD で確認し、ファイル自身の形式のみを `availableFormats` とする。
- `DownloadTaskManager` を追加: 開始・実進捗・キャンセル（タスク停止 + 一時ファイル処理、Library 未登録）・再試行（新規タスク）・複数タスク・状態遷移検証。Phase 2 の `DownloadManager` プロトコルは `DownloadCapabilityEvaluating` に改名。
- `DownloadState` に queued / preparing を追加（waiting は互換維持）。paused は再開を保証できないため実装しない。`DownloadProgress`（割合は総サイズ判明時のみ）と `DownloadError`（日本語 userMessage / ログ用詳細を分離）を追加。
- `MediaFormatOption` / `MediaFormatService` を追加: 形式・品質の選択肢は実在する情報からのみ生成。M4A では品質 UI 非表示を維持。
- `FileStorageService`（Documents/VYRA、一時領域、移動・削除・重複名解決・サイズ/存在確認）と `FileNameValidator`（サニタイズ・空拒否・拡張子保護）を追加。
- Download Confirmation: ファイル名編集、判明している情報のみ表示、保存先表示、ダウンロード不可理由の表示。Download Progress: 実バイト数・速度・残り時間、総サイズ不明時は % 非表示。
- Library: SwiftData 永続化（起動時復元・実ファイル確認・孤児レコード修復・中断分は failed 扱い）、AVKit 再生、実ファイル ShareLink、確認付き削除（ファイル + レコード同期）。モック追加ボタンは廃止。
- テスト: `Phase3DownloadTests` を追加（マネージャ/ストレージ/ファイル名/状態遷移/形式/Library+SwiftData/URLProtocol スタブによるエンジン、全てオフライン）。
- バックグラウンドダウンロードは実装しない（フォアグラウンドのみ、UI とドキュメントに明記）。実機 IPA 作成・インストールは未検証。

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
