# PHASE 2 — METADATA（実装済み）

Phase 2 は実装済み。詳細な引き継ぎは `../HANDOFF/PHASE_2_HANDOFF.md` を参照。
※ 実APIキー（GitHub Secret `YOUTUBE_API_KEY`）が未設定のため、**実API通信は未検証**。テストはすべてスタブHTTP/モックで実行している。

## 実装内容

- `URLValidationService`: URLComponents による構造化解析。対応ホスト: youtube.com / www.youtube.com / m.youtube.com / music.youtube.com / youtu.be。対応形式: `/watch?v=`、youtu.be/<id>、`/shorts/<id>`、`/embed/<id>`、`/live/<id>`。動画IDは `^[A-Za-z0-9_-]{11}$`。類似ホスト（youtube.com.evil.com 等）は拒否。エラーは empty / invalidFormat / unsupportedHost / missingVideoID / invalidVideoID に分離。
- `VideoMetadata` モデル（id=動画ID, title, channelTitle, thumbnailURL?, durationSeconds, publishedAt?, description?, sourceURL）と、API DTO `YouTubeVideosListResponse`（`Models/API/`）を分離。ISO8601 duration（PT1H2M3S 等）と publishedAt をパース。
- `YouTubeDataAPIService`: 公式 YouTube Data API v3 `videos.list`（part=snippet,contentDetails）のみ。async/await、HTTPClient 抽象化、ステータス確認（403/429→quotaExceeded、その他→httpError）、空items→notFound、デコード/通信/キャンセルエラー分離、サムネイル優先順位 maxres>high>medium>default、タイムアウト15秒。
- APIキーは Info.plist `YouTubeAPIKey` または環境変数 `YOUTUBE_API_KEY` からのみ読む（直書き禁止）。未設定時は `UnconfiguredVideoMetadataService` が `apiKeyMissing` で明示的に失敗する。モックを実データとして表示することはしない。
- HomeViewModel: FetchState（idle/validating/loading/loaded/failed）、重複実行防止、cancel()、retry()、recentFetches（インメモリ履歴）、エラー種別ごとの日本語メッセージ。
- Video Preview: AsyncImage サムネイル（無い場合は既存プレースホルダ）、タイトル/チャンネル/時間/公開日/ソース/説明を表示。取得できない項目は推測で埋めず非表示。

## 禁止事項（Phase 2 でも継続）

yt-dlp、FFmpeg、動画ファイルの直接取得、ストリーミングURL抽出、非公式API、スクレイピング、Cookie/ログイン利用、ダウンロード機能全般は実装しない。作業中に yt-dlp 利用の要望があったが、指示書 §5 に基づき採用せず、公式APIで代替した。

## 開始条件（満たした）

Phase 1 完了と、開発者による Phase 2 開始の明示承認（2026-11-24 に受領）。
