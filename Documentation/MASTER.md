# VYRA — MASTER

## 概要

VYRA は iPhone 専用の SwiftUI アプリ。動画URLを入力 → 動画情報を確認 → 保存形式を選択 → ダウンロード進捗を確認 → ライブラリで管理、という流れを提供する。

## フェーズ境界

| Phase | 内容 | 状態 |
|---|---|---|
| Phase 1 | 全画面UI、モックデータによる全動作、GitHub Actions ビルド/テスト基盤 | 完了 |
| Phase 2 | URL解析、MetadataProvider 設計によるメタデータ取得基盤、ViewModel連携、Phase 3 への権限設計 | **実装済み**（改訂仕様準拠。`Phases/PHASE_2_METADATA.md`、`HANDOFF/PHASE_2_HANDOFF.md`） |
| Phase 3 | 実際のファイル取得・保存 | 予定のみ（`Phases/PHASE_3_DOWNLOAD.md`）。**実装禁止（開発者の明示承認が必要）** |

## Phase 2 の確定方針（改訂仕様）

- **YouTube Data API に依存しない。** APIキー / Secrets は不要で、コードにもドキュメントにも置かない。
- **yt-dlp は調査のうえ組み込まない。** iOS では CPython / ffmpeg / JS ランタイム要件とサンドボックス（外部プロセス起動禁止）により実現不可能であり、n/sig 解読は署名回避として仕様 §4 にも抵触する。根拠は `Phases/PHASE_2_METADATA.md` に記録。
- メタデータ取得は `MetadataProvider` 抽象化 + 集約サービスで構成し、利用許可が確認できたプロバイダだけが実データを返す。未設定のソースは明確なエラーで失敗し、モックを実データとして表示しない。
- 署名・認証・DRM の回避、スクレイピング、ストリーミングURL抽出、Cookie/ログイン利用は全フェーズで禁止。

## 技術

Swift / SwiftUI / MVVM / SwiftData / Swift Concurrency / SF Symbols、iOS 26.0、Xcode 26 SDK、GitHub Actions（macOS 26 ランナー）でビルド・テストする。開発者はMacを所有していないため、ローカルMac前提の手順は置かない。外部ライブラリは追加しない。

## 判断記録

- Xcodeプロジェクトは PBXFileSystemSynchronizedRootGroup（フォルダ同期型）で手書きし、ファイル追加時の pbxproj 編集を不要にした。
- SwiftData は `DownloadItem` の永続化モデルとして App に ModelContainer を設定。画面動作は LibraryViewModel のインメモリ配列を正とし、SwiftData への本格移行は将来フェーズの判断とする。
- ファイルサイズは実測値ではなく、動画長と形式・品質から算出する推定値として、UI上も「推定（モック）」と明示する（Phase 3 のダウンロード側の話であり、メタデータとは無関係）。
- タブバーは標準 TabView ではなく、レイアウトフロー内に置くカスタム Liquid Glass フローティングバーとし、コンテンツと重ならないことを保証した。
- Phase 2: 当初は公式API方式で実装を進めたが、改訂仕様により YouTube Data API 依存を撤去し、MetadataProvider 方式へ移行した（経緯は PHASE_2_HANDOFF 参照）。
