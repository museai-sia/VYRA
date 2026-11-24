# VYRA — MASTER

## 概要

VYRA は iPhone 専用の SwiftUI アプリ。動画URLを入力 → 動画情報を確認 → 保存形式を選択 → ダウンロード進捗を確認 → ライブラリで管理、という流れを提供する。

## フェーズ境界

| Phase | 内容 | 状態 |
|---|---|---|
| Phase 1 | 全画面UI、モックデータによる全動作、GitHub Actions ビルド/テスト基盤 | 完了 |
| Phase 2 | 公式に許可された手段（YouTube Data API v3）による動画メタデータの実取得、URL解析、ViewModel連携 | **実装済み**（`Phases/PHASE_2_METADATA.md`、`HANDOFF/PHASE_2_HANDOFF.md`）。ただし実APIキー未設定のため実通信は未検証 |
| Phase 3 | 実際のファイル取得・保存 | 予定のみ（`Phases/PHASE_3_DOWNLOAD.md`）。**実装禁止（開発者の明示承認が必要）** |

YouTube 等のアクセス制御やダウンロード制限を回避する機能は一切実装しない。連携は公式に許可された手段と利用規約への適合を前提とする。yt-dlp / FFmpeg / スクレイピング / ストリーミングURL抽出は全フェーズで禁止（Phase 2 作業中に yt-dlp 利用の要望があったが、指示書 §5 に基づき採用しなかった。メタデータ取得は公式APIで代替済み）。

## 技術

Swift / SwiftUI / MVVM / SwiftData / Swift Concurrency / SF Symbols、iOS 26.0、Xcode 26 SDK、GitHub Actions（macOS 26 ランナー）でビルド・テストする。開発者はMacを所有していないため、ローカルMac前提の手順は置かない。

## 判断記録

- Xcodeプロジェクトは PBXFileSystemSynchronizedRootGroup（フォルダ同期型）で手書きし、ファイル追加時の pbxproj 編集を不要にした。
- SwiftData は `DownloadItem` の永続化モデルとして App に ModelContainer を設定。画面動作は LibraryViewModel のインメモリ配列を正とし、SwiftData への本格移行は将来フェーズの判断とする。
- ファイルサイズは実測値ではなく、動画長と形式・品質から算出する推定値として、UI上も「推定（モック）」と明示する（Phase 2 でも変更なし。これは Phase 3 のダウンロード側の話であり、メタデータとは無関係）。
- タブバーは標準 TabView ではなく、レイアウトフロー内に置くカスタム Liquid Glass フローティングバーとし、コンテンツと重ならないことを保証した。
- Phase 2: APIキーはソースに直書きせず、Info.plist の `YouTubeAPIKey` / 環境変数 `YOUTUBE_API_KEY`（GitHub Secrets 由来）から読む。キー未設定時はモックを実データとして見せず、`apiKeyMissing` エラーで明示的に失敗する。本番ではバックエンドプロキシ経由を推奨（クライアント内キーは抽出され得る）。
