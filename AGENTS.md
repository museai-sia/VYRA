# AGENTS.md — VYRA

このプロジェクトで作業するAIエージェント向けの最小ガイド。仕様の正本は下記ドキュメントであり、ここには重複を書かない。

## 現在フェーズ

Phase 1 Completed / Phase 2 Completed（実APIキーは未設定のため実通信は未検証）/ Phase 3 Pending Approval

## 作業前に読むもの（Phase 2 以降）

- `Documentation/MASTER.md`
- `Documentation/ARCHITECTURE.md`
- `Documentation/DESIGN_SYSTEM.md`
- `Documentation/DEVELOPMENT_RULES.md`
- `Documentation/Phases/PHASE_2_METADATA.md`
- `Documentation/HANDOFF/PHASE_2_HANDOFF.md`

Phase 1 の経緯が必要な場合のみ `Documentation/Phases/PHASE_1_UI.md` と `Documentation/HANDOFF/PHASE_1_HANDOFF.md` を参照する。全ドキュメントを毎回読む必要はない。

## 絶対条件

- Phase 3 の機能を実装しない（実ダウンロード等は開発者の明示承認があるまで禁止）。
- yt-dlp / FFmpeg / スクレイピング / ストリーミングURL抽出 / 非公式API は全フェーズで禁止。メタデータは公式 YouTube Data API v3 のみ。
- APIキーをソースコードに直書きしない。キーは Info.plist `YouTubeAPIKey` / 環境変数 `YOUTUBE_API_KEY`（GitHub Secrets）からのみ読む。
- 色は #090909 / #FFFFFF / #888888 の3色のみ。背景に異色カードを重ねない。
- ビルドとテストは GitHub Actions（macOS ランナー）で確認する。開発者にMac操作を要求しない。
- 作業終了時は対応する `Documentation/HANDOFF/PHASE_<n>_HANDOFF.md` を更新する。
