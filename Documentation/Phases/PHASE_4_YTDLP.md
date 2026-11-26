# PHASE 4 — yt-dlp エンジン（CPython 組み込み）

## 方針転換の記録（重要）

Phase 2 / Phase 3 の「yt-dlp は iOS では実現不可能・組み込まない」という
結論は、**2026-11-25 にプロジェクトオーナー（しあ）の明示指示により
覆された**。根拠は実在する動作事例:

- Squirrel（NatanRA）: CPython 3.14（BeeWare Python-Apple-support）を
  アプリ内に組み込み、実 yt-dlp をオンデバイスで実行する iOS アプリ。
- kewlbear/YoutubeDL-iOS、FreeTube の iOS フォーク: 同じ方式の先行事例。

Phase 2 調査の誤りは「yt-dlp のサブプロセス依存（外部 JS ランタイム /
ffmpeg）は置換不可能」という前提にあった。実際には yt-dlp の
**JS チャレンジプロバイダ API** により JavaScriptCore をインプロセスで
登録でき、ffmpeg は単一ファイル形式に限定すれば不要になる。

## アーキテクチャ

サブプロセスは一切起動しない（iOS サンドボックスでも許可されない）。

```
Swift (YtDlpRuntime / EmbeddedYtDlpEngine)
  │  JSON 文字列で呼び出し（専用スレッド、16MB スタック）
C 層 (PythonBridge/PyBridge.c)
  │  CPython 埋め込み API + 組み込みモジュール `_host`（run_js）
Python (PythonBridge/pybridge/vyra_bridge.py)
  │  yt_dlp を import、JSC プロバイダを登録
  ├─ メタデータ抽出: YoutubeDL.extract_info
  └─ ダウンロード: 別スレッドで実行し、Swift が状態をポーリング
JavaScriptCore (Swift: JSCRunner)
  └─ yt-dlp-ejs の公式ソルバスクリプトを実行（console.log 出力が戻り値）
```

### バージョン（ピン留め: `scripts/bootstrap_python.sh`）

- Python-Apple-support **3.14-b14**（CPython **3.14.10**）
- yt-dlp **2026.11.23**
- yt-dlp-ejs **0.8.0**
- certifi（HTTPS 検証用）

バイナリはリポジトリにコミットしない。両ワークフローの
`./scripts/bootstrap_python.sh` が `Vendor/`（gitignore 済み）に取得し、
Xcode プロジェクトはそこを参照する。クリーンチェックアウトからでも
ワークフロー単体でビルドできる。

### Xcode 構成

- `Vendor/Python.xcframework` をリンク + Embed Frameworks（署名付きコピー）。
- ビルドフェーズ「Install Python Runtime」が BeeWare の `utils.sh` の
  `install_python` を実行し、標準ライブラリと拡張モジュール
  （`.so` → 署名済み `.framework` 化）をアプリバンドルへ配置、
  `Vendor/app_packages`（yt-dlp 等）と `PythonBridge/pybridge` をコピー。
  - 汎用シミュレータビルドでは `ARCHS` が複数値になるため、スクリプト内で
    単一アーキ（arm64 優先）に正規化している（BeeWare 側の `lib-$ARCHS`
    パス前提への対処）。
- ブリッジヘッダ経由で `PyBridge.h` を Swift から利用。

### JSC プロバイダ（`PythonBridge/pybridge/jsc_provider.py`）

- yt-dlp 2026.11.23 の JS チャレンジプロバイダ API
  （`EJSBaseJCP` + `BuiltinIEContentProvider`、クラス名は `JCP` 終端必須）
  を実装し、`@register_provider` / `@register_preference` で登録。
- `_run_js_runtime(stdin)` はプログラム全体（EJS ライブラリ + ソルバ）を
  `_host.run_js` 経由で JavaScriptCore に渡し、`console.log` の出力を返す。
- yt-dlp オプションに `'js_runtimes': {'jsc': {}}` を渡して有効化。

### yt-dlp オプション方針

- プレイヤー JS バリアントは `player_js_variant: ['tv']` に明示固定する
  （ブリッジ `_base_opts`）。既定の `main`（player_ias）バリアントは
  現在のプレイヤービルドで yt-dlp-ejs ソルバが
  `addOnDisposeCallback is not a function` で落ちるため。yt-dlp 本体の
  既定変更に追従せず、アプリ側で固定する（CHANGELOG [1.3.2] 参照）。
- ポストプロセッサなし（yt-dlp に ffmpeg を呼ばせない）。分割形式の
  結合はアプリ側が組み込み FFmpeg ライブラリで行う（下記）。
- `hls_prefer_native: true`（ネイティブ HLS ダウンローダ使用）。
- ダウンロードは **単一ファイル形式**、または **分割ペア**
  （avc1 映像のみ MP4 + 最良の m4a 音声のみ）: 分割ペアは2形式を
  ダウンロードしてから組み込み FFmpeg で結合する。それ以外の
  結合必須形式（VP9/AV1 等）は選択肢から除外する。

## アプリへの配線

- `YtDlpIntegrationProvider`（Phase 2 のスタブ）を実プロバイダ化:
  HTTPS の非直接ファイル URL を処理し、実 yt-dlp 出力から
  `VideoMetadata` を構築。形式一覧は実出力のみ。
- `YtDlpDownloadEngine`（`DownloadService` 実装）を
  `DownloadTaskManager` に接続: リクエストに yt-dlp formatID があれば
  yt-dlp 経路、なければ従来の URLSession 経路（直接ファイル URL）。
- 進捗は Python 側プログレスフック → 状態ポーリングで SwiftUI に反映。
  キャンセルはフック内例外による協調的キャンセル。
- Settings に「エンジン」診断セクションを追加: 実際のエンジンが返す
  Python / yt-dlp バージョンと JSC プロバイダ状態を表示し、固定の
  テスト動画 URL への実抽出テストボタンを持つ。

## 制限（正直な記録）

- **マージは avc1+m4a ペアのみ**（2026-11-25 実装で旧「マージ不可」は
  supersede）: FFmpeg 9.1（LGPL 最小構成を CI でソースビルド）を
  静的リンクし、`FFmpegBridge` がストリームコピーで結合する。
  720p / 1080p / Original（avc1 の最高解像度）が選択可能になった。
  VP9/AV1/WebM の分割形式はトランスコードが必要なため未対応
  （今後の課題）。HLS 形式も引き続き未対応。
- **PO トークン**: YouTube の Proof-of-Origin トークン要件により、
  時期・クライアントによっては抽出が失敗する場合がある。yt-dlp 本体の
  更新で追随する（バージョンは bootstrap スクリプトで更新可能）。
- **ライブ検証**: GitHub Actions の IP は YouTube にブロックされやすい
  ため、実際の YouTube 抽出は CI では検証できない。**受け入れ確認は
  しあ の実機・自宅回線での診断ボタンによる確認を正とする。**
- ダウンロードは従来どおりフォアグラウンドのみ。
- IPA は無署名。インストール時に しあ 自身の Apple ID で署名する。

## 検証状況（2026-11-25 時点）

- Python ブリッジ単体検証（Linux 上、Node を `_host` 代替として）:
  バージョン取得、JSC ソルバ実行（スタブプレイヤーの正しい拒否）、
  ローカル HTTP サーバに対する抽出・ダウンロード — 全 10 項目通過。
- GitHub Actions `Build IPA (unsigned)` run 45519477986
  （macos-15-intel）: 成功。IPA 24,827,606 bytes（約 24.8 MB、
  アプリバンドル展開時 76 MB、拡張モジュールフレームワーク 68 個、
  yt-dlp / yt-dlp-ejs / certifi の同梱をダウンロードして確認）。
- GitHub Actions `iOS Build` run 45519478040: 成功。
  **テスト 115 件全件成功**。うち `EmbeddedPythonRuntimeTests` は
  iOS シミュレータ上で実際の埋め込み CPython を起動し、バージョン
  取得と JavaScriptCore ブリッジ往復（yt-dlp-ejs ソルバ経路）を
  検証した。詳細は `HANDOFF/PHASE_4_HANDOFF.md`。
- 実機での YouTube 実抽出は未検証（上記の通り実機確認が受け入れ条件）。
