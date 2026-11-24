# VYRA — MASTER

## 概要

VYRA は iPhone 専用の SwiftUI アプリ。動画URLを入力 → 動画情報を確認 → 保存形式を選択 → ダウンロード進捗を確認 → ライブラリで管理、という流れを提供する。

## フェーズ境界

| Phase | 内容 | 状態 |
|---|---|---|
| Phase 1 | 全画面UI、モックデータによる全動作、GitHub Actions ビルド/テスト基盤 | 実装対象（本書の範囲） |
| Phase 2 | 公式に許可された手段による動画メタデータの実取得 | 予定のみ（`Phases/PHASE_2_METADATA.md`）。実装禁止 |
| Phase 3 | 実際のファイル取得・保存 | 予定のみ（`Phases/PHASE_3_DOWNLOAD.md`）。実装禁止 |

Phase 1 では YouTube 等のアクセス制御やダウンロード制限を回避する機能は一切実装しない。将来の連携は公式に許可された手段と利用規約への適合を前提とする。

## 技術

Swift / SwiftUI / MVVM / SwiftData / Swift Concurrency / SF Symbols、iOS 26.0、Xcode 26 SDK、GitHub Actions（macOS 26 ランナー）でビルド・テストする。開発者はMacを所有していないため、ローカルMac前提の手順は置かない。

## 判断記録

- Xcodeプロジェクトは PBXFileSystemSynchronizedRootGroup（フォルダ同期型）で手書きし、ファイル追加時の pbxproj 編集を不要にした。
- SwiftData は `DownloadItem` の永続化モデルとして App に ModelContainer を設定。Phase 1 の画面動作は決定的なモック動作のため LibraryViewModel のインメモリ配列を正とし、SwiftData への本格移行は将来フェーズの判断とする。
- ファイルサイズは実測値ではなく、動画長と形式・品質から算出する推定値として、UI上も「推定（モック）」と明示する。
- タブバーは標準 TabView ではなく、レイアウトフロー内に置くカスタム Liquid Glass フローティングバーとし、コンテンツと重ならないことを保証した。
