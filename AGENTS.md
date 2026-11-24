# AGENTS.md — VYRA

このプロジェクトで作業するAIエージェント向けの最小ガイド。仕様の正本は下記ドキュメントであり、ここには重複を書かない。

## 現在フェーズ

Phase 1 Completed / Phase 2 Completed（改訂仕様: MetadataProvider 方式、YouTube Data API 非依存、yt-dlp 非組み込み）/ Phase 3 Pending Approval

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
- YouTube Data API に依存しない（APIキー/Secrets 前提の実装をしない）。
- yt-dlp / FFmpeg を組み込まない。Python 同梱・外部プロセス実行・シェルアウト禁止。スクレイピング / ストリーミングURL抽出 / 署名回避 / 非公式API も禁止。
- 新しい取得元は `MetadataProvider` として、利用許可が確認できた場合にのみ接続する。
- 色は #090909 / #FFFFFF / #888888 の3色のみ。背景に異色カードを重ねない。
- ビルドとテストは GitHub Actions（macOS ランナー）で確認する。開発者にMac操作を要求しない。
- 作業終了時は対応する `Documentation/HANDOFF/PHASE_<n>_HANDOFF.md` を更新する。
