# PHASE 3 HANDOFF

次のAI開発者がチャット履歴なしで VYRA の現状を把握するための引き継ぎ資料。
Phase 3 は 2026-11-24 に開発者の明示承認を受けて実装した。

## 1. 実装済み機能

- 直接 HTTPS メディアファイル URL（.mp4 / .mov / .m4a）の実ダウンロード
  （`URLSessionDownloadEngine`、`DownloadService` プロトコルの背後）。
- 形式・品質選択: 実在する情報からのみ選択肢を生成（`MediaFormatService` /
  `MediaFormatOption`）。直接ファイルは自形式 + Original のみ。M4A は品質 UI 非表示。
- Download Confirmation: サムネイル、ファイル名編集（拡張子保護・禁止文字処理・
  空拒否・重複対応）、形式、品質、判明している場合のみファイルサイズ、保存先表示、
  ダウンロード不可理由の表示。
- `DownloadTaskManager`: 開始、実進捗（バイト数・速度・残り時間）、キャンセル
  （タスク停止 + 一時ファイル削除、Library 未登録）、再試行（新規タスク）、
  複数タスク同時実行、状態遷移検証。
- ファイル保存: `FileStorageService`（Documents/VYRA、移動はメモリに読み込まない、
  重複名は "name 1.ext"、サイズ・存在確認）。
- Library: SwiftData 永続化、新しい順一覧、AVKit 再生、実ファイル ShareLink、
  確認付き削除（ファイル + レコード同期）、Empty State（既存デザイン維持）。
- 起動時復元: 実ファイル存在確認、孤児レコード修復、中断分は failed 扱い。
- 型付きエラー `DownloadError`（日本語 userMessage とログ用詳細を分離）。
- `DirectMediaProvider` を集約の既定配線に接続（直接ファイル URL のメタデータ）。

## 2. 未実装機能

- バックグラウンドダウンロード（§9 参照。意図的に未実装）。
- paused / 再開（任意サーバーで再開を保証できないため未実装。形だけの状態は作らない）。
- YouTube 等のページ URL からのダウンロード（禁止事項であり未実装が正）。
- 許可確認済み外部プロバイダが提供する直接ファイル URL の実接続
  （`DirectMediaResolver` / `AuthorizedSourceProvider` の接続点は用意済みだが、
  実際に許可が確認できた外部サービスは現時点で存在しない）。
- 実機 IPA の作成・インストール検証（§10 参照。未検証）。

## 3. 変更ファイル一覧

追加:
- `VYRA/Models/DownloadProgress.swift`（DownloadProgress / DownloadRequest）
- `VYRA/Models/MediaFormatOption.swift`
- `VYRA/Models/DownloadError.swift`
- `VYRA/Services/URLSessionDownloadEngine.swift`（本番エンジン + StubDownloadEngine）
- `VYRA/Services/DownloadTaskManager.swift`
- `VYRA/Services/MediaFormatService.swift`（+ DirectMediaResolver）
- `VYRA/Services/FileStorageService.swift`
- `VYRA/Services/FileNameValidator.swift`
- `VYRA/Services/DirectMediaProvider.swift`
- `VYRATests/Phase3DownloadTests.swift`
- `Documentation/Phases/PHASE_3_DOWNLOAD.md`（全面改訂）、本書

変更:
- `VYRA/Models/DownloadState.swift`（queued / preparing 追加、遷移検証、waiting は互換維持）
- `VYRA/Models/DownloadItem.swift`（localFileRelativePath / mimeType / thumbnailURLString / durationSeconds / downloadedBytes / errorMessage を追加、transition(to:)）
- `VYRA/Models/DownloadCapability.swift`（`DownloadManager` プロトコル → `DownloadCapabilityEvaluating` に改名）
- `VYRA/Services/DownloadService.swift`（Phase 1 モック用プロトコルから、エンジン境界プロトコルへ再定義。旧 MockDownloadService は廃止）
- `VYRA/Services/MetadataProvider.swift`（appDefault に DirectMediaProvider を追加）
- `VYRA/ViewModels/DownloadViewModel.swift`（マネージャ連携モード + Phase 1 ティック互換モード）
- `VYRA/ViewModels/LibraryViewModel.swift`（SwiftData 連携・復元/修復・再生/共有 URL）
- `VYRA/ViewModels/VideoPreviewViewModel.swift`（実在形式の選択肢・解決可否・検証済みファイル名での項目生成）
- `VYRA/ViewModels/SettingsViewModel.swift`（Phase 3 表記、実ストレージ使用量）
- `VYRA/Views/Download/DownloadConfirmationView.swift` / `DownloadProgressScreen.swift`
- `VYRA/Views/Library/LibraryView.swift`（再生シート・共有・削除確認。モック追加ボタン廃止）
- `VYRA/Views/Preview/FormatSelectionView.swift` / `VideoPreviewView.swift`
- `VYRA/Views/Home/HomeView.swift`（メタデータを Preview へ引き渡し）
- `VYRA/Views/Settings/SettingsView.swift`、`VYRA/App/ContentView.swift`（起動時に modelContext を Library へ接続）
- `Documentation/MASTER.md`、`ARCHITECTURE.md`、`CHANGELOG.md`、`AGENTS.md`、`README.md`

変更なし: ワークフロー `.github/workflows/ios-build.yml`、pbxproj（フォルダ同期型）。

## 4. ダウンロードエンジンの構造

- 境界: `DownloadService` プロトコル（download(request:progress:) / cancel(taskID:)）。
- 本番: `URLSessionDownloadEngine`（NSObject + URLSessionDownloadDelegate）。
  HTTPS のみ、非 2xx は httpStatus エラー、一時ファイルへ移動してから継続を返す。
  進捗は didWriteData から実測（速度は 0.25 秒以上のサンプル差分、ETA は残量/速度）。
- テスト/プレビュー: `StubDownloadEngine`（成功/失敗/ハングの挙動切替、ネットワークなし）。
- yt-dlp は組み込まない（Phase 2 調査: CPython/ffmpeg/JS ランタイム要件、
  サンドボックスの外部プロセス禁止、n/sig 解読は署名回避）。

## 5. ダウンロード状態の仕様

- 遷移: waiting → queued → preparing → downloading → completed / failed /
  cancelled。failed / cancelled からは再試行として queued へ戻れる。
  completed からは遷移不可。不正遷移は `canTransition(to:)` で拒否する。
- paused は存在しない（再開保証がないため）。

## 6. ファイル保存の仕様

- 保存先: Documents/VYRA。一時: temporaryDirectory/VYRA-Downloads。
- 完了時に moveItem で移動（全体をメモリに読み込まない）。移動後に実測
  サイズを確認し、0 バイトは integrityFailed として登録しない。
- 重複名: "name.ext" → "name 1.ext" → "name 2.ext"。
- ファイル名: FileNameValidator が / \ ? % * | " < > : と制御文字を除去し、
  空を拒否し、拡張子は選択形式で強制する。

## 7. Library のデータ構造

`DownloadItem`（SwiftData @Model）: id / fileName / formatRawValue /
qualityRawValue / fileSizeBytes（完了後は実測）/ createdAt / stateRawValue /
thumbnailSymbol / sourceURLString / localFileRelativePath? / mimeType? /
thumbnailURLString? / durationSeconds? / downloadedBytes / errorMessage?。
Library に表示するのは state == completed かつ（ファイルパスがある場合は）
実ファイルが存在する項目のみ。表示順は createdAt 降順。

## 8. データ永続化の方式

SwiftData（選択理由は ARCHITECTURE.md に記載）。管理情報のみを SwiftData に
持ち、ファイル実体は FileStorageService が Documents/VYRA に持つ。相対パスで
参照するため、アプリコンテナの絶対パス変更に影響されない。

## 9. バックグラウンド処理の対応状況

未対応（意図的）。フォアグラウンド URLSession のみで、ダウンロードはアプリ
表示中のみ継続する。アプリ終了で中断されたタスクは復元時に failed として
扱い、自動再開しない。この制約は Download Confirmation 画面に明記している。

## 10. サイドロードに必要な設定

- Bundle Identifier: `com.siatube.vyra`（テストは `.tests` / `.uitests`）
- Deployment Target: iOS 26.0 / SDKROOT=iphoneos（全構成設定済み）
- Signing: シミュレータは CODE_SIGNING_ALLOWED=NO。実機向けには開発者自身の
  Apple ID・証明書・Provisioning Profile が必要（リポジトリに含めない）。
- Entitlements / Capabilities: 追加なし（サンドボックス内保存 + HTTPS のみ）。
- IPA 手順: Mac の Xcode で Team を設定 → Archive → Development 配布で IPA
  書き出し → AltStore 等でインストール。**実機での作成・インストール・動作は
  未検証**（Mac と実機が必要）。

## 11. テスト結果

GitHub Actions run 45390003270（PR #2、コードコミット 55bc209）で確認:
- Unit: 99件全件成功（Phase 2 までの 72件 + Phase3DownloadTests 27件）
- UI: 4件全件成功（VYRAUITests 3件 + LaunchTests 1件）
- 合計: **103件成功 / 0件失敗**（`** TEST SUCCEEDED **`）
- Secrets・外部ネットワークなしで全件実行できる（エンジンのテストは
  URLProtocol スタブ、マネージャのテストは StubDownloadEngine を使用）。
- main へのマージ後の最終結果は §12 を参照。

## 12. GitHub Actions の結果

- PR: https://github.com/museai-sia/VYRA/pull/2 （branch `phase-3-download` → `main`）
- 成功 run（PR、コード）: https://github.com/museai-sia/VYRA/actions/runs/45390003270 — `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`
- 環境: Xcode 26.6、iOS Simulator SDK 26.5、テスト実行シミュレータ iPhone 17 Pro、ランナー macos-26。
- Artifacts: `vyra-build-logs-and-results`（build.log / test.log / TestResults.xcresult / launch.png、保持14日）。
- マージ: PR #2 を main へマージ。マージコミット `8df64d4dd28d220f8bcdc3de76f351830eb17ba5`。
- 成功 run（main、マージコミット）: https://github.com/museai-sia/VYRA/actions/runs/45392979998 — `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`（103件成功 / 0件失敗、Xcode 26.6 / iOS Simulator SDK 26.5 / iPhone 17 Pro）。
- 本追記を含む最終ドキュメントコミットの run が main の最新結果となる。

## 13. 既知の問題

- 直接ファイル URL でも、サーバーが Content-Length を返さない場合は進捗率が
  表示されない（仕様どおり: 推測表示しない）。
- DirectMediaProvider の HEAD に応答しないサーバー（405 等）ではメタデータ
  取得が notFound として失敗する。
- ダウンロード中にアプリを終了するとタスクは失われ、失敗として扱われる（§9）。
- ローカル（Linux）ではコンパイル確認ができず、確定は Actions の結果のみ。

## 14. 実機確認が必要な項目

- 実機での直接ファイル URL ダウンロード（大容量ファイル、回線切断時）。
- 実機での AVKit 再生（保存した mp4/mov/m4a）、ShareLink の共有シート。
- アプリ再起動後の Library 復元の実機確認。
- IPA のサイドロードインストールと起動。

## 15. 今後の改善候補

- 許可が確認できた外部プロバイダの接続（直接ファイル URL の提供が条件）。
- バックグラウンド URLSession の正式対応（セッション復元設計と実機検証が前提）。
- HEAD 非対応サーバー向けの GET range フォールバック（メタデータ取得のみ）。
- サムネイルのローカル生成（AVAssetImageGenerator）とキャッシュ管理。
