# PHASE 3 — DOWNLOAD（実装済み）

> **【2026-11-25 追記】** Phase 4 で yt-dlp エンジンが追加され、
> formatID を持つリクエストは yt-dlp 経路でダウンロードされるように
> なった。本書の URLSession 経路（直接ファイル URL）はそのまま維持。
> 詳細は `PHASE_4_YTDLP.md`。

Phase 3 では、ダウンロード・進捗管理・ファイル保存・Library を実装した。
開始条件（Phase 2 完了 + 開発者の明示承認）は 2026-11-24 に満たされた。

## ダウンロードエンジン（仕様 §6 の判断）

**yt-dlp は組み込まない**（Phase 2 の調査結論を踏襲）: CPython 3.11+ / ffmpeg /
yt-dlp-ejs + JS ランタイムに iOS ビルドがなく、iOS サンドボックスは外部プロセス
起動を禁止し（サイドロードでも解除されない）、n/sig 解読は署名回避にあたる。

仕様 §6 が認める代替エンジンとして、**ネイティブ URLSession ダウンロード
エンジン**（`URLSessionDownloadEngine`、`DownloadService` プロトコルの背後）を採用:

- ダウンロードできるのは **直接 HTTPS メディアファイル URL**（URL 自体が
  .mp4 / .mov / .m4a ファイルを提供するもの）、または許可確認済みプロバイダが
  直接ファイル URL を提供した場合のみ。
- YouTube の watch ページ等の「ページ URL」は `DirectMediaResolver` が開始前に
  拒否し、明確な日本語エラーで失敗する。偽のダウンロードは行わない。
- 非 HTTPS・非 2xx 応答もエンジン側で拒否する。

## メタデータ連携

- `DirectMediaProvider`（MetadataProvider）: 直接ファイル URL に対して HEAD
  リクエストで応答を確認し、ファイル名・拡張子からメタデータを構成する。
  `availableFormats` はそのファイル自身の形式のみ。
- 集約 `VideoMetadataService.appDefault` の先頭に配置。YouTube は従来どおり
  yt-dlp スタブが `integrationUnavailable`、その他のページ URL は許可未確認で失敗。

## 形式・品質（§7）

- `MediaFormatOption`: id / container / fileExtension / mimeType / displayName /
  isVideo / isAudio / qualityLabel / estimatedFileSize?（不明は nil）。
- 選択肢は実在する情報からのみ生成する。直接ファイルは自形式 + Original のみ。
  存在しない品質は表示しない。M4A では品質 UI を表示しない（Phase 1 から継続）。

## ダウンロード管理（§9–§11）

- `DownloadTaskManager`（@MainActor @Observable）: 開始 / 進捗 / キャンセル /
  再試行 / 複数タスク同時実行 / 完了時の保存・登録連携を統括する。
- 状態: queued → preparing → downloading → completed / failed / cancelled
  （+ Phase 1/2 互換の waiting）。遷移は `DownloadState.canTransition(to:)` で
  検証し、不正遷移は拒否する。**paused は実装しない**: 任意のサーバーで
  バイトレンジ再開が保証できないため、形だけの状態は作らない。
- キャンセル: タスク停止 + 一時ファイル削除 + cancelled 遷移。Library には
  登録しない。再試行: 古い一時ファイルを掃除してから新規タスクで開始する。
- Phase 2 の `DownloadManager` プロトコル（能力評価プレースホルダ）は
  `DownloadCapabilityEvaluating` に改名し、名前の衝突を解消した。

## 進捗（§10）

`DownloadProgress`: downloadedBytes / totalBytes? / speed? /
estimatedRemainingTime? / state。総サイズ不明時は割合を nil とし、UI は
パーセンテージを表示しない。速度・残り時間は実測がある場合のみ表示する。

## ファイル保存（§12）

`FileStorageService`: 保存先は Documents/VYRA、一時ファイルは
temporaryDirectory/VYRA-Downloads。移動は FileManager の move（メモリに
読み込まない）。重複名は "name 1.ext" 形式で解決。ファイル名は
`FileNameValidator` がサニタイズ（禁止文字除去・空拒否・拡張子保護）し、
Download Confirmation で編集可能。

## Library と永続化（§13・§14）

- 永続化は **SwiftData**（Phase 1 からアプリのスタックであり、`DownloadItem`
  が既に @Model のため。新規依存なし・移行が軽量）。完了した項目のみ登録する。
- 起動時復元: 保存データを読み込み → 実ファイルの存在を確認 → ファイルが
  無いレコードは削除して修復 → 中断されていたダウンロードは failed として
  扱い Library には出さない（偽の再開はしない）。
- Library: 新しい順の一覧、サムネイル / ファイル名 / 形式 / サイズ / 保存日時 /
  再生時間（取得可能な場合）。再生は AVKit `VideoPlayer`、共有は実ファイル
  URL の ShareLink、削除は確認ダイアログ付きでファイルとレコードを同期削除。

## バックグラウンド処理（§15）

**バックグラウンド URLSession は実装していない。** ダウンロードはアプリが
表示されている間のみ継続し、アプリ終了で中断されたものは失敗として扱う。
この制約は Download Confirmation 画面と本書に明記している。セッション識別子
管理・再起動時タスク復元を伴わない「対応しているように見える」実装はしない。

## エラー処理（§17）

`DownloadError`（invalidURL / permissionNotVerified / unsupportedFormat /
httpStatus / network / cancelled / fileSystem / insufficientStorage /
integrityFailed / invalidStateTransition）に型付けし、簡潔な日本語の
`userMessage` と、ログ専用の `developerDescription` を分離した。

## サイドロード調査（§20）

- Bundle Identifier: `com.siatube.vyra`（テスト: `.tests` / `.uitests`）
- Deployment Target: iOS 26.0、SDKROOT=iphoneos（全構成で設定済み）
- Signing: シミュレータビルドは CODE_SIGNING_ALLOWED=NO。実機 IPA には
  開発者自身の Apple ID / 証明書と Provisioning Profile が必要（リポジトリには
  証明書・秘密情報を含めない）。
- Entitlements / Capabilities: 現状アプリは特別な Capability を要求しない
  （サンドボックス内ファイル保存と HTTPS 通信のみ）。App Sandbox 等の追加
  entitlement ファイルは存在しない。
- IPA 作成手順（Mac がある環境）: Xcode で VYRA.xcodeproj を開く → Signing &
  Capabilities で自分の Team を選択 → Product > Archive → Organizer から
  Development 配布で IPA を書き出し → AltStore / SideStore 等でインストール。
  **本フェーズでは実機 IPA の作成・インストールは未検証**（Mac・実機での
  検証が必要）。

## テスト（§19）

`VYRATests/Phase3DownloadTests.swift`（全てオフライン）:
DownloadTaskManager（開始/進捗/完了/失敗/キャンセル/再試行/複数タスク/拒否）、
状態遷移（正常・不正）、FileStorageService（保存/移動/削除/重複/存在確認）、
FileNameValidator、MediaFormatService / DirectMediaResolver、
LibraryViewModel + SwiftData（復元/孤児修復/再生対象/共有対象/削除/新しい順）、
URLSession エンジン（URLProtocol スタブで 200/404）。
結果は `Documentation/HANDOFF/PHASE_3_HANDOFF.md` に記録する。
