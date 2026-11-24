# PHASE 2 — METADATA（実装済み・改訂仕様準拠）

Phase 2 は改訂仕様に基づき実装済み。詳細な引き継ぎは `../HANDOFF/PHASE_2_HANDOFF.md` を参照。
**YouTube Data API には依存しない**（完成条件）。APIキー/Secrets は不要。

## yt-dlp 調査結果（組み込まない結論）

yt-dlp のアプリ内実行は iOS では実現不可能かつ規約不適合と判断し、組み込まない。

- ライセンス: yt-dlp 本体は Unlicense。ただし同梱バイナリ等には GPLv3+ 等のコンポーネントが含まれる。
- 動作要件: CPython 3.11+（または PyPy 3.11+）が必要。ffmpeg / ffprobe が強く推奨される。
- YouTube 完全対応には yt-dlp-ejs と外部 JavaScript ランタイム（deno / node / bun / QuickJS）が YouTube の n/sig チャレンジ解読のために必要。これらのランタイムにネイティブ iOS ビルドは存在しない。
- コミュニティの a-Shell 等の回避策は存在するが、サブプロセス起動に依存する。iOS のサンドボックスは通常アプリでの外部プロセス起動を禁止しており、サイドローディングでもこの制限は解除されない。
- さらに n/sig の解読は署名回避そのものであり、本仕様 §4（署名・認証・DRM 回避の禁止）と正面から抵触する。

結論: Python の組み込み、外部プロセス実行、シェルアウトは一切行わない。yt-dlp は `YtDlpIntegrationProvider` というインターフェーススタブとしてのみ存在し、常に `integrationUnavailable` を返す（Phase 3 での再評価用）。

## 方式比較（4候補）

| # | 方式 | 概要 | 判定 |
|---|---|---|---|
| 1 | ネイティブ実装 | Swift で各ソースの取得を直接実装 | 不採用（YouTube 向けは署名回避が必要になり §4 抵触。保守コストも過大） |
| 2 | Python ランタイム組み込み（yt-dlp） | CPython + yt-dlp をアプリ内で実行 | 不採用（上記調査のとおり iOS では実現不可能・不適合） |
| 3 | 外部の許可済みサービス | 許可が確認できた外部サービス/バックエンド経由で取得 | 将来候補（許可済みソースに限る。`AuthorizedSourceProvider` の接続先として想定） |
| 4 | yt-dlp 非依存の MetadataProvider 設計 | プロバイダ抽象化 + 集約サービス。許可済みプロバイダだけが実データを返す | **採用** |

## 採用構成

- `MetadataProvider` protocol（id / displayName / canHandle / fetchMetadata）。
- `VideoMetadataService`（集約サービス）: 検証済みURLに対して処理可能なプロバイダを選択し、無ければ `unsupportedSource` を投げる。
- `MockMetadataProvider`: テスト/プレビュー専用。出力は常にモックと明示（sourceName = "Mock"）。
- `YtDlpIntegrationProvider`: 常に `integrationUnavailable`（理由は iOS の制約）。実行コードは存在しない。
- `AuthorizedSourceProvider`: 許可が明示的に確認できたホスト + 接続済み fetcher の場合のみ返す骨格。デフォルトは未確認 → `permissionNotVerified`。
- アプリのデフォルト配線は集約サービス（Authorized + YtDlp スタブ）。実URLは「取得元が未設定です」等の行動可能なエラーで失敗し、モックを実データとして見せることはしない。

## URL解析

- URLComponents による構造化解析。HTTPS 必須（非HTTPSは拒否）。
- ソース種別: youtube / genericHTTPS / unsupported に分類。類似ホスト（youtube.com.evil.com 等）は拒否。
- YouTube 形式: `/watch?v=`、youtu.be/<id>、`/shorts/<id>`、`/embed/<id>`、`/live/<id>`。動画IDは `^[A-Za-z0-9_-]{11}$`。

## Phase 3 への接続設計（設計のみ・実装なし）

`Models/DownloadCapability.swift`: DownloadSource / AvailableMediaFormat / DownloadPermission（unknown / verified / denied、デフォルト unknown）/ DownloadCapability。メタデータ取得だけではダウンロード許可は得られず、unknown / denied ではダウンロード不可。verified かつ形式が判明している場合のみダウンロード可能と判定する。`DownloadManager` はインターフェースのプレースホルダのみ。

## 経緯メモ

当初仕様では yt-dlp は禁止だった。作業中に開発者から yt-dlp 利用の要望があり、その後改訂仕様で「セーフガード付きの調査」が認められた。最終判断は改訂仕様に従い「調査のうえ組み込まない」であり、本書とハンドオフに根拠を残す。
