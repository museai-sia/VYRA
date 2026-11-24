# VYRA

iPhone専用 SwiftUI アプリ「VYRA」の Phase 1 実装です。

動画URLを入力し、動画情報を確認し、保存形式を選んでファイルを管理する——という体験を、**すべてモックデータ**で動作するUIとして実装しています。実際の動画ダウンロード、yt-dlp、FFmpeg、外部API通信は Phase 1 には含まれません。

## 技術構成

- Swift / SwiftUI / MVVM / SwiftData
- Swift Concurrency、SF Symbols
- Deployment Target: iOS 26.0（Liquid Glass は iOS 26 標準APIを使用）
- デザイン: モノクロ3色（#090909 / #FFFFFF / #888888）のみ
- 外部ライブラリ: なし

## 画面

Home / Video Preview（形式・品質選択を含む）/ Download Confirmation / Download Progress / Library / Settings の全画面と、Liquid Glass のフローティングタブバー（Home / Library / Settings）を実装しています。

## ビルドとテスト

開発者にMacがないため、ビルドとテストは GitHub Actions（macOS 26 ランナー、Xcode 26）で実行します。

- ワークフロー: `.github/workflows/ios-build.yml`（main への push / Pull Request で起動）
- Simulator向けビルド（コード署名なし）、Unit Test / UI Test の実行、ログと `.xcresult` の Artifacts 保存を行います。

ローカル（Macがある場合）:

```sh
xcodebuild build -project VYRA.xcodeproj -scheme VYRA -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -project VYRA.xcodeproj -scheme VYRA -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

## ドキュメント

詳細は `Documentation/` を参照してください。入口は `AGENTS.md` と `Documentation/MASTER.md`、引き継ぎは `Documentation/HANDOFF/PHASE_1_HANDOFF.md` です。

## フェーズ

- Phase 1: UI / モック動作（本リポジトリの範囲）
- Phase 2: 動画メタデータ取得（予定のみ・未実装）
- Phase 3: 実際のファイル取得（予定のみ・未実装）
