# PHASE 2 HANDOFF（改訂仕様準拠）

次のAI開発者がチャット履歴なしで第3フェーズを開始できるための引き継ぎ資料。

## 1. 実装済み機能

- URL入力・貼り付け・クリア、構造化検証（HTTPS必須、ソース種別分類）、YouTube動画ID抽出（`URLValidationService`）。
- `MetadataProvider` 抽象化と集約サービス `VideoMetadataService` によるメタデータ取得基盤。
- プロバイダ3種: `MockMetadataProvider`（テスト/プレビュー専用）、`YtDlpIntegrationProvider`（スタブ）、`AuthorizedSourceProvider`（許可確認骨格）。
- HomeViewModel 連携: 状態遷移（idle/validating/loading/loaded/failed）、重複実行防止、キャンセル、再試行、最近取得履歴（インメモリ）。
- Video Preview へのメタデータ反映: AsyncImage サムネイル、タイトル、作成者、時間、公開日、ソース、説明（取得できない項目は非表示）。
- エラー種別ごとの日本語メッセージと再試行UI。
- Phase 3 への権限設計（`DownloadCapability`、§9）。
- テスト: URL検証19件、メタデータ/プロバイダ15件、ViewModel 11件を新規・改訂（外部ネットワーク・Secrets 不要）。

## 2. 未実装機能

- 実データ取得プロバイダの接続: 現在のアプリ既定では、許可が確認できた取得元が存在しないため、実URLのメタデータ取得は意図的にエラーで失敗する（モックを実データとして見せないため）。接続手順は §8。
- 履歴の永続保存（recentFetches はインメモリのみ。仕様上、保存する場合も最小限とする方針）。
- Phase 3 のダウンロード機能全般（未実装が正。§13）。
- ThumbnailService の独立ファイル化（現状サムネイルはメタデータの thumbnailURL を AsyncImage で表示するのみ）。

## 3. yt-dlp 調査結果と iOS 実現可能性

調査結論: **yt-dlp のアプリ内実行は iOS では実現不可能かつ不適合。組み込まない。**

- ライセンス: yt-dlp 本体は Unlicense。ただし同梱バイナリ等には GPLv3+ 等のコンポーネントが含まれる。
- 動作要件: CPython 3.11+（または PyPy 3.11+）が必要で、ffmpeg / ffprobe が強く推奨される。
- YouTube 完全対応には yt-dlp-ejs と外部 JavaScript ランタイム（deno / node / bun / QuickJS）が、YouTube の n/sig チャレンジ解読のために必要。これらにネイティブ iOS ビルドは存在しない。
- コミュニティの a-Shell 等の回避策はサブプロセス起動に依存する。iOS サンドボックスは通常アプリの外部プロセス起動を禁止し、サイドローディングでも解除されない。
- n/sig 解読は署名回避であり、本仕様 §4（署名・認証・DRM 回避の禁止）に抵触する。
- コード上の扱い: `YtDlpIntegrationProvider` はインターフェーススタブとしてのみ存在し、常に `MetadataError.integrationUnavailable(reason:)` を投げる。Process / Python / シェル / スクレイピング / Cookie・署名処理のコードはアプリ内に存在しない。

## 4. 採用構成と比較

| # | 方式 | 判定 |
|---|---|---|
| 1 | ネイティブ実装（Swift で直接取得） | 不採用: YouTube 向けは署名回避が必要で §4 抵触 |
| 2 | Python ランタイム組み込み（yt-dlp） | 不採用: §3 のとおり実現不可能・不適合 |
| 3 | 外部の許可済みサービス経由 | 将来候補: 許可済みソースに限り `AuthorizedSourceProvider` の接続先として想定 |
| 4 | yt-dlp 非依存の MetadataProvider 設計 | **採用**: プロバイダ抽象化 + 集約。許可済みプロバイダだけが実データを返す |

採用理由: iOS の制約内で合法・保守可能であり、将来許可済みソースが現れた場合にプロバイダ追加だけで接続できるため。

## 5. 変更したファイル一覧

追加:
- `VYRA/Services/URLValidationService.swift`
- `VYRA/Services/MetadataProvider.swift`（MetadataError、VideoMetadataFetching、MetadataProvider、集約 VideoMetadataService）
- `VYRA/Services/MockMetadataProvider.swift`
- `VYRA/Services/YtDlpIntegrationProvider.swift`
- `VYRA/Services/AuthorizedSourceProvider.swift`（SourcePermission を含む）
- `VYRA/Models/VideoMetadata.swift`
- `VYRA/Models/DownloadCapability.swift`
- `VYRATests/URLValidationTests.swift`
- `VYRATests/VideoMetadataTests.swift`
- `VYRATests/ViewModelTests.swift`
- `Documentation/HANDOFF/PHASE_2_HANDOFF.md`（本書）

変更:
- `VYRA/Models/Video.swift`（任意ブリッジ項目と `Video(metadata:)` を追加。既存初期化子は互換維持）
- `VYRA/ViewModels/HomeViewModel.swift`（FetchState、検証連携、cancel/retry、recentFetches、エラーメッセージ。汎用 `URLValidator` は Phase 1 のまま保持）
- `VYRA/ViewModels/VideoPreviewViewModel.swift`（メタデータ表示プロパティと `init(metadata:)` を追加。形式・品質・推定サイズのロジックは不変）
- `VYRA/Views/Home/HomeView.swift`、`VYRA/Views/Preview/VideoPreviewView.swift`（最小変更のみ）
- `VYRATests/VYRATests.swift`（モック取得系テストを MockMetadataProvider 前提に更新）
- `Documentation/MASTER.md`、`ARCHITECTURE.md`、`CHANGELOG.md`、`DEVELOPMENT_RULES.md`、`Phases/PHASE_2_METADATA.md`、`AGENTS.md`、`README.md`

削除（改訂仕様による YouTube Data API 依存の撤去）:
- `VYRA/Services/YouTubeDataAPIService.swift`、`VYRA/Models/API/YouTubeAPIResponse.swift`、旧 `VYRA/Services/VideoMetadataService.swift`（protocol 定義は MetadataProvider.swift へ移行）

変更なし: ワークフロー `.github/workflows/ios-build.yml`（Secrets 不要のまま要件を満たす）、pbxproj（フォルダ同期型のため編集不要）。

## 6. 主要なクラス・構造体・プロトコル

- `URLValidationService`: `validate(_:)`（一般検証・分類）、`parse(_:)` / `extractVideoID(from:)`（YouTube）、`classify(host:)`、`isValidVideoID(_:)`。エラーは `URLValidationError`（empty / invalidFormat / unsupportedHost / missingVideoID / invalidVideoID）。
- `SourceKind`（youtube / genericHTTPS / unsupported）、`ValidatedSource`（url / kind / videoID?）。
- `VideoMetadata`（Codable/Identifiable/Equatable/Sendable）: id（ソース側ID）, title, creatorName, sourceName, thumbnailURL?, durationSeconds, publishedAt?, description?, sourceURL, availableFormats?。
- `VideoMetadataFetching`（protocol）: ViewModel が依存する取得抽象。
- `MetadataProvider`（protocol）: id / displayName / canHandle / fetchMetadata。
- `VideoMetadataService`（struct）: 集約サービス。`appDefault` は YtDlp スタブ + Authorized 骨格。
- `MetadataError`（enum, Equatable）: urlValidation / unsupportedSource / integrationUnavailable(reason:) / permissionNotVerified / notFound / network / decoding / invalidResponse / cancelled。
- `MockMetadataProvider` / `YtDlpIntegrationProvider` / `AuthorizedSourceProvider`（+ `SourcePermission`）。
- `DownloadSource` / `AvailableMediaFormat` / `DownloadPermission` / `DownloadCapability` / `DownloadManager`（§9）。
- `Video` のブリッジ: externalID / thumbnailURL / publishedAt / descriptionText（Optional・デフォルト nil）と `init(metadata:)`（author ← creatorName）。

## 7. URL解析の仕様

- URLComponents でホスト・パス・クエリを検証（文字列置換による判定はしない）。**HTTPS 必須**（http は invalidFormat として拒否）。
- ソース分類: 完全一致ホスト（youtube.com / www.youtube.com / m.youtube.com / music.youtube.com / youtu.be）→ youtube、その他の HTTPS → genericHTTPS、類似ホスト（youtube.com.evil.com、notyoutube.com 等）→ unsupported として拒否。
- YouTube 形式: `/watch?v=<id>`（追加クエリ可）、`youtu.be/<id>`、`/shorts/<id>`、`/embed/<id>`、`/live/<id>`。動画IDは `^[A-Za-z0-9_-]{11}$`。
- 汎用URL構文検証 `URLValidator`（Phase 1、http も構文としては可）は温存。取得フローは `validate` を使う。

## 8. メタデータ取得の仕様

- 流れ: HomeViewModel → `URLValidationService.validate` → 集約 `VideoMetadataService.fetchMetadata` → canHandle する最初のプロバイダへ委譲（無ければ unsupportedSource）。
- 新しい取得元を接続する手順: (1) そのサービスの利用規約・許可を確認する。(2) `MetadataProvider` 実装を追加する（取得できない項目は nil）。(3) 集約の providers 配列（`VideoMetadataService.appDefault` または ViewModel 注入）へ加える。(4) テストを追加し Actions で確認する。
- **YouTube Data API は使用しない**（改訂仕様の完成条件）。APIキーや Secrets は不要であり、追加してはいけない。
- 取得できない情報は推測で表示しない。エラーは種別ごとに日本語の行動可能なメッセージへ変換される（HomeViewModel.message）。

## 9. 権限・DownloadCapability 設計（Phase 3 接続）

- `DownloadPermission`: unknown（デフォルト）/ verified / denied。**メタデータが取得できただけでは許可は得られない。**
- `DownloadCapability.isDownloadable`: permission == verified かつ availableFormats が1件以上ある場合のみ true。unknown / denied では常に false で、形式リストも空に正規化される（`evaluate` の仕様、テストで担保）。
- `VideoMetadata.availableFormats` は許可確認済みの場合にのみ意味を持つ（デフォルト nil）。
- `DownloadManager` protocol は能力評価のみのプレースホルダ。ダウンロード実行APIは Phase 2 に存在しない。
- Phase 3 での接続: Video Preview の形式・品質選択と `DownloadItem`、`Video` のブリッジ項目（externalID、sourceURLString、thumbnailURL）を既存の流れで渡し、実処理は Service 層の差し替えとして実装する。ただし実際のファイル取得は、対象ソースで公式に許可された手段が存在する場合に限る。

## 10. テスト結果

GitHub Actions run 45381348474（PR #1、コミット 71ee681）で確認:
- Unit: 72件全件成功（VYRATests 27件 + URLValidationTests 19件 + VideoMetadataTests 15件 + ViewModelTests 11件）
- UI: 4件全件成功（VYRAUITests 3件 + LaunchTests 1件）
- 合計: **76件成功 / 0件失敗**（`** TEST SUCCEEDED **`）
- Secrets・外部ネットワークなしで全件実行できる。
- 本ハンドオフを含むドキュメントコミットの検証は、同じ PR の後続 run で行う（最終結果は PR #1 の checks を参照）。
- 途中経過: 初回 run 45378952713 はテスト側コンパイルエラー（XCTAssert の autoclosure 内 await）で失敗 → 1件修正。公式API方式の run 45379350930 は成功（69件）したが改訂仕様で置き換え済み。

## 11. GitHub Actions の実行結果

- PR: https://github.com/museai-sia/VYRA/pull/1 （branch `phase-2-metadata` → `main`）
- 成功 run（改訂仕様のコード）: https://github.com/museai-sia/VYRA/actions/runs/45381348474 — `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`
- 環境: Xcode 26.6、iOS Simulator SDK 26.5、テスト実行シミュレータ iPhone 17 Pro、ランナー macos-26。
- Artifacts: `vyra-build-logs-and-results`（build.log / test.log / TestResults.xcresult / launch.png、保持14日）。

## 12. 既知の問題と経緯

- アプリ既定では実データ取得プロバイダが未接続のため、実URLの取得はエラーになる（仕様どおりの意図的挙動。§8 の手順で接続可能）。
- ローカル（Linux）ではコンパイル確認ができないため、Swift / SwiftUI のコンパイル可否は GitHub Actions の結果でのみ確定する。
- スクリーンショット自動取得は Home（起動画面）のみ（Phase 1 から継続）。
- recentFetches はインメモリのみで、アプリ再起動で消える。
- 経緯（正直な記録）: 当初の Phase 2 仕様では yt-dlp は禁止で、公式API方式が指示されていた。作業中に開発者から「yt-dlp で取得してほしい」との要望があり、その後に出された改訂仕様で「セーフガード付きで yt-dlp を調査すること」が正式に認められた。最終判断は改訂仕様に従い「調査のうえ組み込まない」（§3）であり、YouTube Data API 依存も改訂仕様の完成条件に従って撤去した。

## 13. 第3フェーズへの引き継ぎ

変更が必要な箇所:
- 許可済み取得元の接続（§8 の手順）と、許可が確認できた場合の `DownloadCapability` 連携。
- ダウンロード実処理を実装する場合の接続点は `DownloadService`（protocol + Mock）、`DownloadViewModel`、`VideoPreviewViewModel.makeDownloadItem()` が生む `DownloadItem`。
- Library の SwiftData 本格永続化（現状 ModelContainer のみ設定、画面は LibraryViewModel のインメモリ配列が正）。
- 開始には開発者の明示承認が必須。

変更してはいけない箇所:
- デザイン: 3色（#090909 / #FFFFFF / #888888）、背景への直接配置、Liquid Glass の限定使用。カードのネストや色付き装飾を追加しない。
- 禁止事項: yt-dlp / FFmpeg の組み込み、Python 同梱、外部プロセス実行、ストリーミングURL抽出、スクレイピング、署名・認証・DRM 回避、Cookie/ログイン利用、YouTube Data API への依存追加。
- `URLValidationService` の検証仕様、`MetadataProvider` の分離構造、許可未確認ソースから取得しない原則、モックを実データとして見せない原則。
- Phase 1 の形式・品質選択と推定サイズ表示（「推定（モック）」表記）の意味。

開始時に読むべきファイル:
1. `AGENTS.md`
2. `Documentation/MASTER.md`
3. `Documentation/ARCHITECTURE.md`
4. `Documentation/DESIGN_SYSTEM.md`
5. `Documentation/DEVELOPMENT_RULES.md`
6. `Documentation/Phases/PHASE_2_METADATA.md`
7. `Documentation/Phases/PHASE_3_DOWNLOAD.md`
8. `Documentation/HANDOFF/PHASE_2_HANDOFF.md`（本書）
9. ソース: `VYRA/Services/`（全ファイル）、`VYRA/Models/VideoMetadata.swift`、`VYRA/Models/DownloadCapability.swift`、`VYRA/ViewModels/HomeViewModel.swift`、`VYRA/ViewModels/VideoPreviewViewModel.swift`
10. ワークフロー: `.github/workflows/ios-build.yml`
