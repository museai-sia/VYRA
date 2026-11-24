# PHASE 1 HANDOFF

次のAIエージェントが会話履歴なしで開発を再開できるための引き継ぎ。

## 1. プロジェクト構成

`ARCHITECTURE.md` 参照。要点: App / Models / ViewModels / Views（Home, Preview, Download, Library, Settings）/ Components / Services。Xcodeプロジェクトはフォルダ同期型（PBXFileSystemSynchronizedRootGroup、objectVersion 77）のため、ファイル追加時に pbxproj 編集は不要。

## 2. 使用バージョン

- Swift 5.9（SWIFT_VERSION=5.9）、SwiftUI / SwiftData
- Xcode 26 SDK 想定（GitHub Actions の macos-26 ランナーで選択される最新26系。確定値は Actions ログで確認すること）

## 3. Deployment Target

iOS 26.0、iPhone専用（TARGETED_DEVICE_FAMILY=1）。

## 4. ビルド方法

GitHub Actions（下記）または Mac 上で:
`xcodebuild build -project VYRA.xcodeproj -scheme VYRA -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`

## 5. GitHub Actions の実行方法

main への push / Pull Request で `.github/workflows/ios-build.yml` が自動実行される。手動確認は Actions タブから対象 run を開く。

## 6. 最新のビルド結果

GitHub Actions実行待ち（本ドキュメント作成時点では未実行。成功と断定しないこと）。実行後にここへ結果と run URL を追記すること。

## 7. 最新のテスト結果

GitHub Actions実行待ち。Unit Test 27件（VYRATests）、UI Test 4件（VYRAUITests、起動テスト含む）を用意済み。実行後に成功/失敗数を追記すること。

## 8. 実装済み画面

Home、Video Preview、Format Selection、Download Confirmation、Download Progress、Library、Settings（全画面）。

## 9. 実装済み機能

URL入力・貼り付け・クリア・バリデーションとエラー表示、モック動画情報表示、形式/品質選択（M4A時品質非表示、表示連動）、ダウンロード確認、モック進捗（開始/キャンセル/完了/失敗）、完了時のライブラリ追加、ライブラリのモック追加・削除・共有、設定画面、タブ切替、アニメーション。

## 10. 作成済み Model

Video、DownloadItem（SwiftData @Model）、DownloadFormat / DownloadQuality、DownloadState。

## 11. ViewModel の構成

HomeViewModel、VideoPreviewViewModel、DownloadViewModel、LibraryViewModel、SettingsViewModel（すべて @MainActor @Observable）。

## 12. Service の構成

VideoMetadataService / DownloadService ともに protocol + Mock 実装（MockVideoMetadataService / MockDownloadService）。差し替えは ViewModel の初期化引数で行う。

## 13. モックデータの場所

- `VYRA/Models/Video.swift` の `Video.mock`
- `VYRA/Services/VideoMetadataService.swift` の `MockVideoMetadataService`
- `VYRA/Models/DownloadItem.swift` の `DownloadItem.mockItem()`
- 推定サイズ算出: `VYRA/ViewModels/VideoPreviewViewModel.swift`

## 14. 次フェーズで変更する必要がある箇所

- Phase 2: `MockVideoMetadataService` を実サービスへ差し替え（protocol は変更不要の想定）。
- Phase 3: `MockDownloadService` 差し替えと、Library の SwiftData 本格永続化（現状 ModelContainer のみ設定、画面は LibraryViewModel のインメモリ配列が正）。

## 15. 既知の問題

- ローカル（Linux）ではコンパイル確認ができないため、Swift / SwiftUI のコンパイル可否は GitHub Actions の結果でのみ確定する。
- スクリーンショットの自動取得はベストエフォート（ワークフロー内コメントと手動手順を参照）。

## 16. 未解決の問題

- GitHub Actions の初回実行結果の確認と、失敗時のエラー修正（未実施）。
- AGENTS.md の現在フェーズ表記を「Phase 1 Completed / Phase 2 Pending Approval」へ更新するのは、Actions 成功確認後（親担当）。

## 17. 関連ファイルパス

- ワークフロー: `.github/workflows/ios-build.yml`
- プロジェクト: `VYRA.xcodeproj/project.pbxproj`、共有スキーム: `VYRA.xcodeproj/xcshareddata/xcschemes/VYRA.xcscheme`
- テスト: `VYRATests/VYRATests.swift`、`VYRAUITests/`

## 18. 最新のコミットID

ローカル初回コミットのIDは `git log -1 --format=%H` で確認すること（本ドキュメントには自己参照になるため記載しない）。

## 19. 次フェーズの開始手順

1. 本ドキュメントと `Documentation/MASTER.md`、`Documentation/Phases/PHASE_2_METADATA.md` を読む。
2. GitHub Actions の最新 run が成功していることを確認する。
3. 開発者から Phase 2 開始の明示承認を得る。
4. `VideoMetadataService` の実実装を新規ファイルで追加し、Mock と差し替える（既存画面・ViewModel のインターフェースは維持）。
