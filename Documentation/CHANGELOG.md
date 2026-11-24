# CHANGELOG

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
