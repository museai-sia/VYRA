# VYRA — MASTER

## 概要

VYRA は iPhone 専用の SwiftUI アプリ。動画URLを入力 → 動画情報を確認 → 保存形式を選択 → ダウンロード進捗を確認 → ライブラリで管理、という流れを提供する。

## フェーズ境界

| Phase | 内容 | 状態 |
|---|---|---|
| Phase 1 | 全画面UI、モックデータによる全動作、GitHub Actions ビルド/テスト基盤 | 完了 |
| Phase 2 | URL解析、MetadataProvider 設計によるメタデータ取得基盤、ViewModel連携、Phase 3 への権限設計 | **実装済み**（改訂仕様準拠。`Phases/PHASE_2_METADATA.md`） |
| Phase 3 | 実際のファイル取得・保存、進捗管理、Library 完成 | **実装済み**（2026-11-24 開発者の明示承認により開始。`Phases/PHASE_3_DOWNLOAD.md`） |
| Phase 4 | CPython + yt-dlp のアプリ内組み込み（オンデバイス実行） | **実装済み**（2026-11-25 オーナー指示による方針転換。`Phases/PHASE_4_YTDLP.md`） |

## Phase 2 の確定方針（改訂仕様）

- **YouTube Data API に依存しない。** APIキー / Secrets は不要で、コードにもドキュメントにも置かない。
- **yt-dlp について（2026-11-25 方針転換）:** Phase 2 当時の「組み込まない」結論はオーナー指示により撤回され、Phase 4 で CPython + yt-dlp を組み込んだ。サブプロセスは使わず、JS チャレンジは JavaScriptCore プロバイダ、形式は単一ファイルのみに限定する。詳細は `Phases/PHASE_4_YTDLP.md`。
- メタデータ取得は `MetadataProvider` 抽象化 + 集約サービスで構成し、利用許可が確認できたプロバイダだけが実データを返す。未設定のソースは明確なエラーで失敗し、モックを実データとして表示しない。
- 署名・認証・DRM の回避、スクレイピング、ストリーミングURL抽出、Cookie/ログイン利用は全フェーズで禁止。

## 技術

Swift / SwiftUI / MVVM / SwiftData / Swift Concurrency / SF Symbols、iOS 26.0、Xcode 26 SDK、GitHub Actions（macOS ランナー）でビルド・テストする。開発者はMacを所有していないため、ローカルMac前提の手順は置かない。Phase 4 以降は CPython 3.14（Python-Apple-support）と yt-dlp / yt-dlp-ejs をアプリ内に同梱する（`THIRD_PARTY_LICENSES.md` 参照）。バイナリは CI の bootstrap スクリプトが取得し、リポジトリには含めない。

## 判断記録

- Xcodeプロジェクトは PBXFileSystemSynchronizedRootGroup（フォルダ同期型）で手書きし、ファイル追加時の pbxproj 編集を不要にした。
- SwiftData は `DownloadItem` の永続化モデルとして App に ModelContainer を設定。Phase 3 で Library は SwiftData を正とし、起動時に実ファイルの存在確認と修復を行う（判断理由は ARCHITECTURE.md）。
- ファイルサイズ: Phase 1/2 の形式選択画面では推定値として「推定（モック）」と明示する。Phase 3 で実際にダウンロードしたファイルは実測サイズを保存し、推定値と区別する。取得できない情報は表示しない。
- タブバーは標準 TabView ではなく、レイアウトフロー内に置くカスタム Liquid Glass フローティングバーとし、コンテンツと重ならないことを保証した。
- Phase 2: 当初は公式API方式で実装を進めたが、改訂仕様により YouTube Data API 依存を撤去し、MetadataProvider 方式へ移行した（経緯は `Phases/PHASE_2_METADATA.md` 参照）。
- Phase 3: ダウンロードエンジンは yt-dlp を組み込まず、直接 HTTPS メディアファイル URL 専用のネイティブ URLSession エンジンを `DownloadService` プロトコルの背後に採用した。ページ URL（YouTube watch 等）は開始前に拒否する。バックグラウンドダウンロードと paused 状態は、保証できないため実装しない（正直な制約として UI とドキュメントに明記）。
