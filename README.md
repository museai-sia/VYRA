# VYRA

iPhone 専用 SwiftUI アプリ「VYRA」。動画の URL を入力すると、アプリ内に組み込んだ **yt-dlp** がその場で動画情報を取得し、解像度を選んでダウンロード、ライブラリで再生・共有・削除まで完結します。サーバーは介在しません — 抽出もダウンロードも形式変換も、すべてオンデバイスで動きます。

## できること

- **URL → 動画情報**: YouTube 等の動画 URL を貼ると、タイトル・投稿者・長さ・サムネイル・公開日と、実際に取得できた形式一覧を表示します（取得できない情報は表示しません。モックを実データとして見せることはしません）。
- **解像度は絞らない**: yt-dlp が返した解像度はすべて選択肢に出します（360p〜2160p 等、実際に存在するものだけ）。保存ファイルは常に AVKit で再生できる MP4（音声のみは M4A）です。
  - avc1 + AAC の形式はそのまま保存、または分割形式をストリームコピーで結合（**remux**、無劣化・高速）。
  - VP9 / AV1 / WebM / Opus などコピーできない形式は、組み込み **FFmpeg** で H.264（VideoToolbox ハードウェアエンコード）+ AAC に**変換（transcode）**してから保存します。
- **ダウンロード**: 進捗（実バイト数・速度・残り時間。変換中は変換の実進捗 %）、キャンセル、失敗時のリトライ。ダウンロード自体は **yt-dlp 本体が一括して行います**（1つの選択 = 1つのダウンロードジョブ。分割形式も HLS も yt-dlp のネイティブダウローダが処理し、アプリ側はダウンロード後の結合・変換だけを内蔵 FFmpeg で行います）。フォアグラウンドのみ（バックグラウンドダウンロードは未対応）。
- **ライブラリ**: SwiftData で永続化し、起動時に実ファイルの存在確認と修復を行います。再生（AVKit）、共有、削除（確認付き）ができます。
- **保存先の選択**: 設定タブでアプリ内フォルダ（Documents/VYRA）か、ファイルアプリ等で選んだ外部フォルダかを選べます（セキュリティスコープ付きブックマークで保持）。
- **診断とデバッグログ**: 設定タブにエンジン診断（Python / yt-dlp / yt-dlp-ejs の実バージョン、JavaScriptCore ソルバの状態、抽出テスト、ダウンロードテスト）と、失敗時の実エラーと yt-dlp ログを残すデバッグログ（閲覧・共有可能）があります。エラーは汎用メッセージで握り潰しません。
- **yt-dlp生出力**: 直近の抽出で yt-dlp が返した生の JSON（formats 配列を含む）を設定タブから閲覧・共有できます。形式の選択肢が少ないときに「セッションが実際に何を受け取ったか」を切り分けるための機能です（直近3件を端末内に保存）。
- **失敗の分類表示**: メンバー限定・削除・非公開・著作権削除・アカウント停止・DRM・配信/プレミア予約などの失敗は、分類した日本語メッセージを主表示にします（生の yt-dlp 文は詳細とデバッグログに残ります）。終端的な失敗は動画IDごとに記録し（メンバー限定は恒久、その他は15分）、記録がある間は yt-dlp を実行せず即座に同じ判定を返します。アカウントのレート制限は終端的には扱いません。
- **Cookie（任意）**: 設定タブから Netscape 形式の cookies.txt（YouTube にログイン済みのブラウザから書き出したもの）を取り込むと、抽出とダウンロードがログイン状態のセッションで行われます（選択肢が増える場合があります）。有効/無効の切り替えと削除ができ、Cookie の内容がログや共有に出ることはありません。
- **POトークン（任意）**: 設定タブで取得方式（オフ / オンデバイス / サーバー）を選びます。既定はオンデバイスです。オンデバイスは端末内の JavaScript 環境（WKWebView、予備は JavaScriptCore）で BotGuard を実行して端末内でトークンを生成します（実験的。失敗した場合はトークンなしで続行し、失敗はデバッグログに kind `pot` で残ります）。サーバーは LAN 内の bgutil POトークンサーバーから、同梱の bgutil プラグイン（bgutil-ytdlp-pot-provider 2.0.2、HTTP モードのみ）がトークンを取得します。詳細は Documentation/POT_ONDEVICE.md。
- 直接メディアファイル URL（HTTPS の .mp4 / .mov / .m4a）は、従来どおり URLSession エンジンでそのままダウンロードします。

## 技術構成

- Swift / SwiftUI / MVVM / SwiftData / Swift Concurrency、Deployment Target: iOS 26.0
- デザイン: モノクロ3色（#090909 / #FFFFFF / #888888）のみ。タブバーは Liquid Glass（`GlassEffectContainer` / `.glassEffect()` / `glassEffectID` によるモーフィング選択カプセル）
- **サブプロセスは一切起動しません**（iOS サンドボックスでは不可能なため）。yt-dlp の外部依存は2つともインプロセスに置換しています:
  - JS チャレンジ解決 → **JavaScriptCore**（yt-dlp 公式の JS チャレンジプロバイダ API 経由、`PythonBridge/pybridge/jsc_provider.py`）
  - ffmpeg → **FFmpeg ライブラリの静的リンク**（`FFmpegBridge/` の C ブリッジが libavformat 等を直接呼ぶ）

### 組み込みコンポーネント（バージョンはピン留めが正本）

| コンポーネント | バージョン | 取得元 |
|---|---|---|
| CPython（Python-Apple-support 3.14-b14） | 3.14.10 | `scripts/bootstrap_python.sh` |
| yt-dlp | 2026.11.23 | 同上 |
| yt-dlp-ejs | 0.8.0 | 同上 |
| FFmpeg（LGPL 最小構成、ソースビルド） | 9.1 | `scripts/bootstrap_ffmpeg.sh` |

バイナリはリポジトリに含めず、CI がビルド前に `Vendor/`（gitignore）へ取得・ビルドします。ライセンス一覧は `Documentation/THIRD_PARTY_LICENSES.md`。

### アーキテクチャの要点

- メタデータ: `MetadataProvider` 抽象化の背後に組み込み yt-dlp エンジン（`YtDlpIntegrationProvider` / `EmbeddedYtDlpEngine`）。YouTube Data API には依存しません（API キー不要）。
- プレイヤー JS のバリアントは `player_js_variant: ['tv']` に固定し、クライアント順序は GVS PO トークン不要なものを優先します（根拠は `vyra_bridge.py` のコメントと `Documentation/Phases/PHASE_4_YTDLP.md`）。
- 形式選択: `MediaFormatService` が「高さごとに1つ、HTTPS 結合 → HLS 結合 → 分割ペア → 最良品質の順に優先」を選び、`MediaProcessingKind`（direct / remuxSingle / remux / transcode）をダウンロード経路に伝えます。HLS しか返らない高さも選択肢から落としません。
- ダウンロード: `DownloadTaskManager` が URLSession エンジン（直接ファイル）と yt-dlp エンジン（ページ URL）を使い分け、状態遷移・進捗・永続化を管理します。

## ビルドとテスト

開発者に Mac がないため、ビルドとテストは **GitHub Actions**（macOS ランナー）で実行します。

- `.github/workflows/ios-build.yml`（macos-26）: bootstrap（Python / FFmpeg）→ シミュレータ向けビルド → Unit / UI テスト。main への push / Pull Request で起動。テストの実行デバイスは **iPhone 17 Pro シミュレータに固定**（実機の基準に合わせ、名前で解決して UDID 指定。イメージから消えたら落として気付けるようにしてある）。
  - **Vendor キャッシュ**: Python / FFmpeg の `Vendor/` 生成物は bootstrap スクリプトのハッシュをキーに `actions/cache` で再利用し、変更がない限り再ビルドしない（完全一致キーのみ。古い生成物を誤って使わないため prefix フォールバックは付けていない）。
  - **選択的テスト**: `scripts/select_tests.sh` が変更パスを分類し、必要なスイートだけを実行する。モードは `full`（全部）/ `heavy`（高速 unit + 実エンジン系、UI テスト省略）/ `ui`（高速 unit + UI テスト、実エンジン系省略）/ `core`（高速 unit のみ）/ `none`（ドキュメントのみ）。実エンジン系（埋め込み Python/JSC、FFmpeg remux/transcode）はブリッジ・bootstrap・当該テストの変更時のみ、UI テストは UI コードの変更時のみ実行。共有コア（Models / Services）や分類不能な変更は安全側に倒して `full`。選択モードと理由は run のログとステップサマリに残る。
  - **ドキュメントのみの push では起動しない**（`Documentation/**` と `**/*.md` を paths-ignore）。フルスイートはいつでも Actions の workflow_dispatch から実行できる（dispatch は常に full）。
- `.github/workflows/build-ipa.yml`（macos-15-intel）: 未署名 IPA を生成します。**インストールには自分の Apple ID での署名が必要**です（SideStore / AltStore / Sideloadly 等）。リポジトリに証明書やプロファイルは含まれません。こちらも同じ Vendor キャッシュを使い、ドキュメントのみの push では起動しません。
- Mac がある場合は通常の Xcode プロジェクトとして開けます（先に `./scripts/bootstrap_python.sh` と `./scripts/bootstrap_ffmpeg.sh` を実行して `Vendor/` を用意してください）。

## プロジェクト構成

```
VYRA/            アプリ本体（App / Views / ViewModels / Models / Services / Components）
PythonBridge/    CPython 埋め込みの C ブリッジ + pybridge（vyra_bridge.py, jsc_provider.py）
FFmpegBridge/    RemuxBridge.c（ストリームコピー結合）/ TranscodeBridge.c（変換）
scripts/         bootstrap_python.sh / bootstrap_ffmpeg.sh（Vendor/ の生成）
VYRATests/       Unit テスト（実 remux / 実 transcode をシミュレータで検証するフィクスチャ含む）
VYRAUITests/     UI テスト
Documentation/   仕様・判断記録（入口は Documentation/MASTER.md）
```

## 正直な制約

- **YouTube 側の仕様変更で抽出が壊れることがあります**: PO トークン要件や JS チャレンジの変更により、yt-dlp の更新が出るまで一時的に取得・ダウンロードできなくなる場合があります。失敗時は設定のデバッグログに実エラーが残ります。
- **HLS 形式には対応しています**（yt-dlp のネイティブ HLS ダウンローダで取得し、MPEG-TS を内蔵 FFmpeg で MP4 に remux）。セッションによっては 360p 超が HLS でしか返りませんが、その場合も HLS の解像度がそのまま選べます。HLS の映像のみ形式（音声トラックを持たないもの）だけは選択肢に出ません。
- **変換（transcode）は時間がかかり、非可逆**です。コピーできる形式（remux / direct）は無劣化・高速ですが、VP9/AV1 等の変換は端末性能なりの時間と、再エンコードによる画質劣化を伴います。
- ダウンロードは**フォアグラウンドのみ**で、一時停止（paused）状態はありません。
- 実機でのみ確認できる項目（大きなファイルのダウンロード、実回線での抽出可否など）は、CI では検証できません。

## フェーズ

- Phase 1: UI / モック動作（完了）
- Phase 2: URL 解析・MetadataProvider によるメタデータ取得基盤・権限設計（完了）
- Phase 3: 実際のファイル取得・保存・Library 完成（完了）
- Phase 4: CPython + yt-dlp のアプリ内組み込み（完了）。以降、FFmpeg 結合（remux）、保存先選択、Liquid Glass タブバー、全解像度対応（transcode）を追補として実装

詳細は `Documentation/` を参照してください。入口は `Documentation/MASTER.md` です。
