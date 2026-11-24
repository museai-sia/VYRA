# AGENTS.md — VYRA

このプロジェクトで作業するAIエージェント向けの最小ガイド。仕様の正本は下記ドキュメントであり、ここには重複を書かない。

## 現在フェーズ

Phase 1 Completed / Phase 2 Pending Approval

## 作業前に読むもの（Phase 1）

- `Documentation/MASTER.md`
- `Documentation/DESIGN_SYSTEM.md`
- `Documentation/DEVELOPMENT_RULES.md`
- `Documentation/Phases/PHASE_1_UI.md`

必要に応じて `Documentation/ARCHITECTURE.md` を参照する。全ドキュメントを毎回読む必要はない。

## 絶対条件

- Phase 2 / Phase 3 の機能を実装しない（実ダウンロード、yt-dlp、FFmpeg、実API通信は禁止）。すべてモック。
- 色は #090909 / #FFFFFF / #888888 の3色のみ。背景に異色カードを重ねない。
- ビルドとテストは GitHub Actions（macOS ランナー）で確認する。開発者にMac操作を要求しない。
- 作業終了時は `Documentation/HANDOFF/PHASE_1_HANDOFF.md` を更新する。
