# VYRA

iPhone専用 SwiftUI アプリ「VYRA」の Phase 1 + Phase 2 実装です。

動画URLを入力し、動画情報を確認し、保存形式を選んでファイルを管理する——という体験を提供します。Phase 2（改訂仕様）では、URL解析と `MetadataProvider` 設計によるメタデータ取得基盤、ViewModel連携、Phase 3 に向けたダウンロード権限の設計を実装しました。

方針（Phase 2 で確定）:
- **YouTube Data API には依存しません**（APIキー/Secrets 不要）。
- **yt-dlp は組み込みません。** 調査の結果、iOS では CPython / ffmpeg / JavaScript ランタイムの要件とサンドボックスの制約（外部プロセス起動禁止）によりアプリ内実行は実現不可能で、署名回避の観点でも不適合と判断しました（根拠: `Documentation/Phases/PHASE_2_METADATA.md`）。
- 利用許可が確認できたプロバイダだけが実データを返します。未設定のソースでは「取得元が未設定です」等の明確なエラーを表示し、モックを実データとして見せることはしません。モックプロバイダはテスト/プレビュー専用です。
- 実際の動画ダウンロードは Phase 2 に含まれません。

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
- Secrets や外部ネットワークなしで、ビルド・テストが成功する構成です。

ローカル（Macがある場合）:

```sh
xcodebuild build -project VYRA.xcodeproj -scheme VYRA -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild test  -project VYRA.xcodeproj -scheme VYRA -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' CODE_SIGNING_ALLOWED=NO
```

## ドキュメント

詳細は `Documentation/` を参照してください。入口は `AGENTS.md` と `Documentation/MASTER.md`、引き継ぎは `Documentation/HANDOFF/PHASE_3_HANDOFF.md`（Phase 2 は `PHASE_2_HANDOFF.md`、Phase 1 は `PHASE_1_HANDOFF.md`）です。

## フェーズ

- Phase 1: UI / モック動作（完了）
- Phase 2: URL解析・MetadataProvider によるメタデータ取得基盤・権限設計（完了、改訂仕様準拠）
- Phase 3: 実際のファイル取得・保存・Library 完成（完了。直接 HTTPS メディアファイル URL 専用の URLSession エンジン）
