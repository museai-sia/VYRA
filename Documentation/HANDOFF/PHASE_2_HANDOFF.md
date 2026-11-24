# PHASE 2 HANDOFF

次のAI開発者がチャット履歴なしで第3フェーズを開始できるための引き継ぎ資料。

## 1. 実装済み機能

- YouTube URL の入力・貼り付け・クリア、構造化検証、動画ID抽出（`URLValidationService`）。
- 公式 YouTube Data API v3 によるメタデータ取得サービス（`YouTubeDataAPIService`）。取得項目は §6 参照。
- メタデータのモデル化（`VideoMetadata`）と API DTO の分離（`YouTubeVideosListResponse`）。
- HomeViewModel への連携: 状態遷移（idle/validating/loading/loaded/failed）、重複実行防止、キャンセル、再試行、最近取得履歴（インメモリ）。
- Video Preview への実データ反映: AsyncImage サムネイル、タイトル、チャンネル名、時間、公開日、ソース、説明（取得できない項目は非表示。推測で埋めない）。
- エラー種別ごとの日本語メッセージ（対応外URL、APIキー未設定、クォータ、通信失敗、動画なし、HTTPエラー等）と再試行UI。
- テスト: URL検証14件、メタデータ15件、ViewModel 9件を新規追加（すべてスタブ/モック、実通信なし）。

## 2. 未実装機能

- **実API通信の検証**: GitHub Secret `YOUTUBE_API_KEY` が未設定（`gh secret list` は空）のため、実際の YouTube Data API への通信は未実施・未検証。コードは完成しているが、キー設定後に実動画URLでの動作確認が必要。
- 履歴の永続保存（recentFetches はインメモリのみ。仕様上、保存する場合は最小限とする方針で意図的に未永続化）。
- バックエンドプロキシ（推奨構成として §9 に記載のみ、未構築）。
- Phase 3 のダウンロード機能全般（未実装が正。§13 参照）。
- ThumbnailService は独立ファイルとして作っていない（サムネイル選択ロジックは DTO の `Thumbnails.bestURL` に集約。必要になれば分離可能）。

## 3. 変更したファイル一覧

追加:
- `VYRA/Services/URLValidationService.swift`
- `VYRA/Services/YouTubeDataAPIService.swift`（`HTTPClient` protocol を含む）
- `VYRA/Models/VideoMetadata.swift`
- `VYRA/Models/API/YouTubeAPIResponse.swift`
- `VYRATests/URLValidationTests.swift`
- `VYRATests/VideoMetadataTests.swift`（`StubHTTPClient` を含む）
- `VYRATests/ViewModelTests.swift`（`FlippableService` を含む）
- `Documentation/HANDOFF/PHASE_2_HANDOFF.md`（本書）

変更:
- `VYRA/Services/VideoMetadataService.swift`（protocol 戻り値を VideoMetadata に変更、エラー種別拡張、Mock 更新、Unconfigured 追加）
- `VYRA/Models/Video.swift`（任意ブリッジ項目と `Video(metadata:)` を追加。既存初期化子は互換維持）
- `VYRA/ViewModels/HomeViewModel.swift`（FetchState、検証連携、cancel/retry、recentFetches、エラーメッセージ。汎用 `URLValidator` は Phase 1 のまま保持）
- `VYRA/ViewModels/VideoPreviewViewModel.swift`（メタデータ表示プロパティと `init(metadata:)` を追加。形式・品質・推定サイズのロジックは不変）
- `VYRA/Views/Home/HomeView.swift`（見出し文言、再試行ボタン、最近取得メタデータ表示、取得ボタンの無効化）
- `VYRA/Views/Preview/VideoPreviewView.swift`（AsyncImage サムネイル、公開日・説明表示）
- `VYRATests/VYRATests.swift`（モックメタデータ系2テストを YouTube URL 前提に意図更新）
- `Documentation/MASTER.md`、`Documentation/ARCHITECTURE.md`、`Documentation/CHANGELOG.md`、`Documentation/Phases/PHASE_2_METADATA.md`、`AGENTS.md`、`README.md`

変更なし: ワークフロー `.github/workflows/ios-build.yml`（既存のままで要件を満たす）、pbxproj（フォルダ同期型のため編集不要）。

## 4. 主要なクラス・構造体・プロトコル

- `URLValidationService`（struct）: `parse(_:)`, `extractVideoID(from:)`, `isValidVideoID(_:)`。エラーは `URLValidationError`。
- `VideoMetadata`（struct, Codable/Identifiable/Equatable/Sendable）: §6 参照。`parseISO8601Duration(_:)`, `parseISO8601Date(_:)` を持つ。
- `YouTubeVideosListResponse`（Decodable DTO）: Item / Snippet / Thumbnails / ContentDetails。`Item.toVideoMetadata(sourceURL:)` で内部モデルへ変換。
- `VideoMetadataService`（protocol, Sendable）: `fetchMetadata(for url: URL) async throws -> VideoMetadata`。
- `VideoMetadataError`（enum, Equatable）: invalidURL / urlValidation(URLValidationError) / apiKeyMissing / httpError(Int) / quotaExceeded / notFound / network(String) / decoding / invalidResponse / cancelled。
- `YouTubeDataAPIService`（struct）: `configuredAPIKey(...)`, `defaultService()`。依存は `HTTPClient`。
- `HTTPClient`（protocol）: `data(for:) async throws -> (Data, URLResponse)`。URLSession が extension で適合。
- `MockVideoMetadataService` / `UnconfiguredVideoMetadataService`（struct）: テスト用 / キー未設定時の本番デフォルト。
- `HomeViewModel.FetchState`（enum）: idle / validating / loading / loaded / failed。
- `Video` のブリッジ: `externalID`, `thumbnailURL`, `publishedAt`, `descriptionText`（すべて Optional・デフォルト nil）と `init(metadata:)`。

## 5. URL解析の仕様

- URLComponents でホスト・パス・クエリを検証（文字列置換による判定はしない）。
- 対応ホスト（完全一致のみ）: `youtube.com`, `www.youtube.com`, `m.youtube.com`, `music.youtube.com`, `youtu.be`。類似ホスト（`youtube.com.evil.com`, `notyoutube.com` 等）は unsupportedHost として拒否。
- 対応形式: `/watch?v=<id>`（追加クエリ可）、`youtu.be/<id>`、`/shorts/<id>`、`/embed/<id>`、`/live/<id>`。
- 動画ID: `^[A-Za-z0-9_-]{11}$`。
- エラー: 空→empty、スキーム不正/パース不能→invalidFormat、ホスト不一致→unsupportedHost、IDなし→missingVideoID、ID形式不正→invalidVideoID。
- 汎用URL構文検証 `URLValidator`（Phase 1）は温存。HomeViewModel の取得フローは YouTube 専用解析を使う。

## 6. メタデータ取得の仕様

- エンドポイント: `GET https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails&id=<videoID>&key=<APIキー>`（URLComponents で構築、タイムアウト15秒）。
- 取得項目: 動画ID、タイトル、チャンネル名、サムネイルURL（maxres>high>medium>default の優先順）、動画時間（ISO8601 duration を秒へ変換）、公開日時（ISO8601）、説明文。
- 取得できない項目は nil とし、UIでは非表示。推測で埋めない。
- ステータス処理: 200→デコード、403/429→quotaExceeded、その他→httpError(code)。items が空→notFound。JSON不正→decoding。URLError→network（cancelled のみ cancelled へ分離）。snippet 欠落→invalidResponse。
- これはメタデータ取得のみであり、動画ファイルのダウンロード権限を意味しない。

## 7. API接続方法

- 本番デフォルトは `YouTubeDataAPIService.defaultService()`: キーが設定されていれば `YouTubeDataAPIService`、無ければ `UnconfiguredVideoMetadataService`（apiKeyMissing で失敗）。
- テスト/プレビューでは `HomeViewModel(metadataService:)` に Mock やスタブを注入する。
- テストは `StubHTTPClient`（VideoMetadataTests.swift 内）で HTTP を差し替え、実通信を一切行わない。

## 8. 必要なGitHub Secrets

- `YOUTUBE_API_KEY`: YouTube Data API v3 の APIキー。**現在は未設定**（`gh secret list` 空）。
- 設定後の用途: 実API通信の手動検証、および将来キーを Info.plist へ注入するビルド工程を設ける場合の供給元。現行ワークフローは Secrets を使わず、モック/スタブでビルド・テストが成功する構成。
- アプリ実行時にキーを渡す方法: Info.plist の `YouTubeAPIKey` にビルド時注入するか、開発時は環境変数 `YOUTUBE_API_KEY`（Xcode スキームの Run 環境変数）を使う。`configuredAPIKey` は環境変数を優先し、次に Info.plist を読む（`$(...)` 形式の未展開プレースホルダはキーとして扱わない）。

## 9. APIキーの安全管理方法

- ソースコード・リポジトリへの直書きは禁止（Phase 2 でもコミットしていない）。
- GitHub Secrets に保管し、ログやドキュメントに値を書かない。
- 注意: アプリに組み込んだキーは最終的に解析・抽出され得る。**本番ではバックエンドプロキシ経由（サーバー側でキーを保持し、アプリは自前バックエンドとだけ通信）を推奨**する。その場合 `YouTubeDataAPIService` の向き先をプロキシに差し替えるだけで済むよう、通信は Service 層に分離してある。
- キーには Google Cloud Console 側で API 制限（YouTube Data API v3 のみ）とクォータ上限を設定すること。

## 10. テスト結果

GitHub Actions run 45379350930（PR #1、コミット 6e5672f）で確認:
- Unit: 65件全件成功（Phase 1 の VYRATests 27件 + URLValidationTests 14件 + VideoMetadataTests 15件 + ViewModelTests 9件）
- UI: 4件全件成功（VYRAUITests 3件 + LaunchTests 1件）
- 合計: **69件成功 / 0件失敗**（`** TEST SUCCEEDED **`）
- 初回 PR run 45378952713 はテスト側のコンパイルエラー（XCTAssert の autoclosure 内 await）で失敗し、原因を特定して1件だけ修正後に再実行して成功した。
- 本ハンドオフを含むドキュメントコミットの検証は、同じ PR の後続 run で行う（最終結果は PR #1 の checks を参照）。

## 11. GitHub Actionsの実行結果

- PR: https://github.com/museai-sia/VYRA/pull/1 （branch `phase-2-metadata` → `main`）
- 成功 run: https://github.com/museai-sia/VYRA/actions/runs/45379350930 — `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`
- 環境: Xcode 26.6、iOS Simulator SDK 26.5、テスト実行シミュレータ iPhone 17 Pro、ランナー macos-26。
- Artifacts: `vyra-build-logs-and-results`（build.log / test.log / TestResults.xcresult / launch.png、保持14日）。
- Secrets 未設定でも成功する構成（実API通信テストは行わない）。

## 12. 既知の問題

- 実API通信が未検証（§2）。キー設定後、実在動画での取得・クォータエラー時の表示・サムネイル表示の目視確認が必要。
- APIキー未設定のままアプリを実行すると、取得操作は常に apiKeyMissing エラーになる（仕様どおりの意図的な挙動。モックへの自動フォールバックはしない）。
- ローカル（Linux）ではコンパイル確認ができないため、Swift / SwiftUI のコンパイル可否は GitHub Actions の結果でのみ確定する。
- スクリーンショット自動取得は Home（起動画面）のみ（Phase 1 から継続）。
- recentFetches はインメモリのみで、アプリ再起動で消える。

## 13. 第3フェーズで変更が必要な箇所

- ダウンロードの実処理を実装する場合の接続点は `DownloadService`（protocol + Mock）と `DownloadViewModel`、`VideoPreviewViewModel.makeDownloadItem()` が生む `DownloadItem`。
- メタデータとの接続: Video Preview で選択された形式・品質と、`Video` のブリッジ項目（externalID = YouTube動画ID、sourceURLString、thumbnailURL）を `DownloadItem` 経由で渡す設計が既にある。第3フェーズではこの流れを壊さず、実処理を Service 層の差し替えとして実装すること。**ただし実際の動画ファイル取得は YouTube の利用規約上、公式に許可された手段が存在する場合に限る**。許可手段が無い場合は実装せず、その旨を報告すること（Phase 2 で確立した「無理に実装しない」原則を継続）。
- Library の SwiftData 本格永続化（現状 ModelContainer のみ設定、画面は LibraryViewModel のインメモリ配列が正）。
- 開始には開発者の明示承認が必須。

## 14. 第3フェーズで変更してはいけない箇所

- デザイン: 3色（#090909 / #FFFFFF / #888888）、背景への直接配置、Liquid Glass の限定使用（タブバー・小ボタン等）。カードのネストや色付き装飾を追加しない。
- `URLValidationService` の検証仕様と `VideoMetadata` / DTO の分離構造（API固有構造を View に持ち込まない）。
- APIキーの管理方法（直書き禁止、Secrets/プロキシ方針）。
- 禁止事項: yt-dlp、FFmpeg、ストリーミングURL抽出、スクレイピング、制限回避、Cookie/ログイン利用は第3フェーズでも導入しない。※ Phase 2 作業中に開発者から yt-dlp 利用の要望があったが、Phase 2 指示書 §5 の禁止規定に基づき採用しなかった。メタデータ取得は公式APIで代替済みであり、この判断を第3フェーズでも維持すること。
- Phase 1 の形式・品質選択と推定サイズ表示（「推定（モック）」表記）の意味を勝手に変えない。

## 15. 第3フェーズ開始時に読むべきファイル

1. `AGENTS.md`
2. `Documentation/MASTER.md`
3. `Documentation/ARCHITECTURE.md`
4. `Documentation/DESIGN_SYSTEM.md`
5. `Documentation/DEVELOPMENT_RULES.md`
6. `Documentation/Phases/PHASE_2_METADATA.md`
7. `Documentation/Phases/PHASE_3_DOWNLOAD.md`
8. `Documentation/HANDOFF/PHASE_2_HANDOFF.md`（本書）
9. ソース: `VYRA/Services/`（全ファイル）、`VYRA/Models/VideoMetadata.swift`、`VYRA/Models/API/YouTubeAPIResponse.swift`、`VYRA/ViewModels/HomeViewModel.swift`、`VYRA/ViewModels/VideoPreviewViewModel.swift`
10. ワークフロー: `.github/workflows/ios-build.yml`
