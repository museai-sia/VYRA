# PHASE 1 HANDOFF

次のAIエージェントが会話履歴なしで開発を再開できるための引き継ぎ。

## 1. プロジェクト構成

`ARCHITECTURE.md` 参照。要点: App / Models / ViewModels / Views（Home, Preview, Download, Library, Settings）/ Components / Services。Xcodeプロジェクトはフォルダ同期型（PBXFileSystemSynchronizedRootGroup、objectVersion 77）のため、ファイル追加時に pbxproj 編集は不要。

## 2. 使用バージョン

- Swift 言語モード 5.9（SWIFT_VERSION=5.9）、SwiftUI / SwiftData。ランナーのツールチェインは Apple Swift 6.3.3
- Xcode 26.6（Build 17F113）、iOS Simulator SDK 26.5、テスト実行シミュレータ: iPhone 17 Pro（いずれも GitHub Actions run 45372323350 のログで確認済み）

## 3. Deployment Target

iOS 26.0、iPhone専用（TARGETED_DEVICE_FAMILY=1）。

## 4. ビルド方法

GitHub Actions（下記）または Mac 上で:
`xcodebuild build -project VYRA.xcodeproj -scheme VYRA -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`

## 5. GitHub Actions の実行方法

main への push / Pull Request で `.github/workflows/ios-build.yml` が自動実行される。手動確認は Actions タブから対象 run を開く。

## 6. 最新のビルド結果

成功。GitHub Actions run 45372323350（2026-11-24、所要 4分14秒）で `** BUILD SUCCEEDED **` を確認。
URL: https://github.com/museai-sia/VYRA/actions/runs/45372323350
経緯: run 45372041269 は SDKROOT 未指定で宛先エラー、run 45372205953 は同名ファイル衝突で失敗し、いずれも修正済み（コミット a5eee2f、a2058d2）。
Artifacts: `vyra-build-logs-and-results`（build.log / test.log / TestResults.xcresult / launch.png）に保存（保持14日）。

## 7. 最新のテスト結果

成功。run 45372323350 で `** TEST SUCCEEDED **` を確認。テスト総数31件（Unit 27件 + UI 4件）、成功31件、失敗0件。
内訳の検証は test.log の Test case 行を集計（ユニーク31件すべて passed）。

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

- ローカル（Linux）ではコンパイル確認ができないため、Swift / SwiftUI のコンパイル可否は GitHub Actions の結果でのみ確定する（Phase 1 コードは run 45372323350 で成功確認済み）。
- スクリーンショットは Home（起動画面）のみ自動取得をワークフローに組み込み済み（ベストエフォート、continue-on-error）。その他の画面は手動手順（ワークフロー内コメント）参照で未自動化。
- Download Confirmation への遷移は NavigationLink の destination で downloadItem を生成する方式。UIテストの自動検証範囲外のため、実機/シミュレータでの目視確認が望ましい。
- SwiftData は ModelContainer の設定までで、Library の永続化は未実装（画面は LibraryViewModel のインメモリ配列が正）。

## 16. 未解決の問題

- なし（Phase 1 の DoD 範囲）。Phase 2 は開発者の明示承認があるまで開始しない。

## 17. 関連ファイルパス

- ワークフロー: `.github/workflows/ios-build.yml`
- プロジェクト: `VYRA.xcodeproj/project.pbxproj`、共有スキーム: `VYRA.xcodeproj/xcshareddata/xcschemes/VYRA.xcscheme`
- テスト: `VYRATests/VYRATests.swift`、`VYRAUITests/`

## 18. 最新のコミットID

Phase 1 のコードとしてビルド・テスト成功を確認したコミット: `a2058d284cd541745ee71412ddfabea4b002293a`（Rename download progress screen file...）。
本ハンドオフ更新を含むドキュメントコミットがこの後に続く。正確な最新IDは `git log -1 --format=%H` で確認すること。

## 19. 次フェーズの開始手順

1. 本ドキュメントと `Documentation/MASTER.md`、`Documentation/Phases/PHASE_2_METADATA.md` を読む。
2. GitHub Actions の最新 run が成功していることを確認する。
3. 開発者から Phase 2 開始の明示承認を得る。
4. `VideoMetadataService` の実実装を新規ファイルで追加し、Mock と差し替える（既存画面・ViewModel のインターフェースは維持）。
