# CHANGELOG

## [1.9.0] — 公開リリース（POT WebView の待ち方式を刷新）

初の公開版。あわせて POT（POトークン）オンデバイス生成の WebView 経路を根本修正した。

- **WebView の待ち方式**: POT ホストがメインスレッドを手回しのランループ spin で塞いで WebKit のコールバックを待っていたため、環境によっては WebContent プロセスの起動・ページ読み込みがその spin に阻害され、読み込みがタイムアウトし続ける問題があった。読み込みと JS 評価をメインキューへディスパッチし、呼び出し側がセマフォで待つ方式に変更（メインのランループは通常通り回る）。遅れて完了した古いナビゲーションが新しい読み込みの状態を壊す競合も修正。
- **事前ウォームアップ**: エンジン初期化時に WebView のプロセス起動と初回読み込みをバックグラウンドで開始し、初回 mint がコールド起動を待たないようにした。
- **テスト**: 全 209 件（ユニット + UI）が GitHub Actions のフルスイートで通過。UI テストの存在待ちは CI シミュレータの実測に合わせて 30 秒に調整（検証内容は不変）。
- **公開準備**: アプリバージョンを 1.9.0 に統一。内部引き継ぎ文書（HANDOFF）と古い開発ルールを削除し、LICENSE（MIT）を追加。README の POT 既定値（オンデバイス）の記述を実態に合わせて修正。

## [1.8.1] — アプリアイコン設定

しあ が指定したアイコン画像（赤〜オレンジのグラデーションに白の「V＋下矢印」）をアプリアイコンに設定した。

- **アイコン素材**: 指定画像は角丸＋黒い四隅のJPEGだったため、そのままでは使えない。四隅と角丸の影を含まない内側の正方形を切り出し、1024×1024 PNG（アルファなし）に変換して `VYRA/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png` に配置。iOS側の角丸マスクはOSが適用する。
- **プロジェクト設定**: これまでアセットカタログ自体が無く `ASSETCATALOG_COMPILER_APPICON_NAME` は空だった。`Assets.xcassets` を新規追加し、Debug/Release両方で `AppIcon` を指定した。

## [1.8.0] — Phase 4 追補（HLS 対応 + ダウンロードを yt-dlp 本体へ委譲）

しあ の指示2件: (1) **HLS (m3u8) 対応は必須**（セッションによっては 360p 超が HLS 結合形式 itag 91〜96 でしか返らないため）、(2) **ダウンロードは独自実装でなく yt-dlp に頼る**（「ダウンロードとかは独自じゃなくてYT-dlpに頼っちゃって」）。これまでの「HLS は未対応」という記述（1.5.0 以前）は本節で置き換える。

- **ダウンロード経路（ブリッジ）**: 選択ごとに **1 ジョブ**。`download_start` が `audio_format_id` を受け取れるようになり、分割選択も単一ジョブで処理する。進捗フックがファイル単位の進捗をジョブ内で合算（合計バイトは全ファイルの合計が判明したときだけ報告）し、`download_status` は `job.files`（単一形式なら1件、分割なら [映像, 音声]）を返す。ポストプロセッサは一切設定しない（yt-dlp が ffmpeg を起動することはない。M3U8 fixup も ffmpeg バイナリ不在のため不活性）。
- **分割を「1回の `vid+aid` 要求」にしなかった理由（実測）**: ピン留め yt-dlp 2026.11.23 のソース（YoutubeDL.py の requested_formats 処理）を確認すると、ffmpeg 不在で結合形式を要求すると `ignoreerrors` 未設定では **"Aborting due to --abort-on-error" で中断** する。`ignoreerrors` を付ければ2ファイル残るが、本物のダウンロード失敗まで握り潰す。よって **同一ジョブ内で形式ごとの厳密な単一形式ダウンロードを2回** 実行する方式にした（Swift からは1回の要求・1本の進捗・1つの最終ファイルに見える）。CLI 実測でも ffmpeg なし PATH で両ファイルが残る経路と、中断する経路の両方を確認済み。
- **エンジン（Swift）**: `YtDlpDownloadService` の脚（leg）オーケストレーションを廃止し `EmbeddedYtDlpEngine.performDownload`（1選択=1ブリッジジョブ）に一本化。`SplitProgressCombiner` は削除（合算はブリッジ側が担う）。キャンセルはその1ジョブへの `download_cancel`（進捗フックが HLS フラグメント途中でも即時中断）+ 実行中 remux/transcode の C キャンセルフラグ。公開状態・進捗 UI の意味・リトライ挙動は不変。
- **HLS の提供（MediaFormatService）**: HLS 結合形式が高さごとに競合するようになった。高さごとの優先順位は (1) HTTPS 結合でそのまま保存（.direct）→ (2) HLS 結合（.remuxSingle: ネイティブ HLS ダウンロード + TS→MP4 remux）→ (3) 分割ペア（.remux）→ (4) 最良の残り（.transcode）。**HLS がその高さの唯一の供給源でも黙って落とさない**。HLS の映像のみ形式は引き続き除外（ペアは同一プロトコル内で組むため）。音声のみ覧の HLS 除外と、ペア音声の HLS 除外は従来どおり。
- **FFmpeg**: `scripts/bootstrap_ffmpeg.sh` の最小構成に **mpegts デマルチプレクサ** を追加（LGPL 最小のまま）。`RemuxBridge` に単一入力版 `vyra_remux_run_single` を追加（内容で判定するので拡張子不問、映像/音声どちらか一方だけでも可）。`MediaProcessingKind.remuxSingle` と `FFmpegRemuxer.remuxSingle` が HLS 経路を担う。
- **ローカル実測（ブリッジ実経路、ffmpeg なし PATH、実 yt-dlp 2026.11.23）**: 分割ジョブ → 2ファイル + 合算進捗（13,065 + 18,786 バイト）を確認。HLS ジョブ → MPEG-TS バイト列（0x47 同期、188 バイト周期）を確認。コミットした2セグメント HLS フィクスチャでは、ダウンロード結果が両セグメント合計 **43,616 バイトちょうど** で、セグメント境界にも同期バイトがあることを確認。
- **テスト**: 提供テスト5件（HLS のみの高さが .remuxSingle で出る／優先順位2件／非コピー可能 HLS は transcode／HLS 映像のみは出ない）を SplitFormatTests に追加、従来の「HLS は出ない」テストを提供側の検証に置き換え、TS remuxSingle の単体テスト（AVAsset で映像+音声トラック・再生可能）を追加。さらにシミュレータスイートに **実 HLS E2E** を追加: コミットした HLS フィクスチャ（`VYRATests/Fixtures/hls/`、既存 remux フィクスチャから生成した2セグメント）をテスト内 localhost HTTP サーバーで配信し、抽出→ネイティブ HLS ダウンロード（生 TS バイト列を検証）→ .remuxSingle（AVAsset で映像+音声・約2秒・再生可能）を実経路で通す。モックのみの検証にはしていない。
- **検証状況**: Build IPA run 45636017398 **成功**（アプリ+テストターゲットのコンパイル成功を含む。初回 run 45634757811 はテスト側のコンパイルエラー3件で失敗し、修正コミット ac70636 で解消）。IPA **27,560,879 bytes**、展開してブリッジの `audio_format_id` 配線、`pot_ondevice.py` / bgutil プラグインの存続、バイナリ内の `mpegts demuxer` 文字列・`vyra_remux_run_single`・`remuxSingle` を確認し、`~/workspace/VYRA-unsigned.ipa` に保存・配布済み。**iOS Build（シミュレータでのテスト実走）run 45636017517 は macos-26 プール待ちでキュー中**（本節執筆時点では未実行＝合否未確定）。しあ の判断で、フル CI グリーンを待たず IPA を先行配布した。実走結果は確定次第この節に追記する。実機確認（YOASOBI の URL で HLS のみの 720p/1080p が選べて、ダウンロード完了し、ライブラリで再生できること）は しあ の実機待ち。

## [1.7.0] — Phase 4 追補（POトークンのオンデバイス生成 + サーバー方式の配管バグ修正）

しあ の希望（「POトークンサーバーもオンデバイスで出来ない？なるべくそうして欲しい」）で、PO トークンを端末内で生成する経路を実装した。調査と実測の詳細は Documentation/POT_ONDEVICE.md。

- **オンデバイス生成（新プロバイダ `vyra:ondevice`）**: `PythonBridge/pybridge/pot_ondevice.py` が yt-dlp の POT プロバイダ API を実装。BotGuard チャレンジ取得（抽出済み動画ページ→ホームページの順、yt-dlp の通信で抽出と同じセッション）→ BotGuard VM 実行 → GenerateIT → コンテンツバインディング（yt-dlp が算出する visitor data / 動画 ID）で mint、という bgutil サーバーと同一の手順を端末内で行う。JS 実行環境は `_host.pot_js`（新規）: 主経路は **WKWebView**（youtube.com オリジンの空ページ、本物の WebKit DOM）、予備は持続 JavaScriptCore コンテキスト（`pot_driver.js` のシム）。ドライバは実 DOM 環境では Node + JSDOM 相当の構成で実 Google から実トークンの mint まで実証済み（開発マシンでの実測）。素のエンジンではスナップショットが環境不足で integrity token が発行されず fallback のみになることも実測で確認し、それが WKWebView を主経路にした根拠。
- **Settings は方式選択に**: POトークン節が「オフ（既定）/ オンデバイス / サーバー」のセグメント選択になった。旧トグル ON の設定はサーバー方式へ移行する。オンデバイスの失敗は抽出を止めず（トークンなしで続行）、デバッグログに kind `pot` で残る。GenerateIT が fallback トークンのみの場合は、セッションバインドの GVS 要求に限ってそれを使う（理由とログ方針は POT_ONDEVICE.md）。
- **サーバー方式の配管バグを発見・修正**: 従来ブリッジが渡していた `youtube:pot_provider=bgutil:base_url=...` は、ピン留め yt-dlp 2026.11.23 のどこでも読まれない無効な引数だった（ソース grep で確認）。正しい `youtubepot-bgutilhttp: base_url` 名前空間に変更。つまり 1.6.1 までのサーバー方式は実際にはサーバーへ届いていなかった。
- **テスト**: PotOnDeviceTests を追加（レジストリ登録と設定ゲーティング、フェイク VM での全フロー+バインディング伝播の検証、実チャレンジフィクスチャでの実 VM スナップショットを JSC / WKWebView 両方で）。opts_probe の検証も両プロバイダの新配線に更新。プロバイダ配管はローカル（実 yt-dlp 2026.11.23 + スタブ _host）でも14項目全通過を確認済み。
- **検証状況**: Build IPA run 45607228881 成功（アプリ+テストターゲットのコンパイル成功を含む）、IPA **27,542,661 bytes**、展開して `pybridge/pot_ondevice.py` / `pot_driver.js` の同梱と bgutil プラグインの存続を確認し、`~/workspace/VYRA-unsigned.ipa` に保存済み。iOS Build（シミュレータでのテスト実走）run 45607228705 は macos-26 プールの容量不足で attempt 1〜8 すべてキューキャンセル（ステップ未実行＝テスト失敗ではない）に終わり、実走はプール復旧待ち（復旧後の再キューで PotOnDeviceTests を含む全件の結果が確定する）。Google の受理（実機 WKWebView で integrity token が発行されるか）は しあ の実機・自宅回線での確認待ち（CI の IP はボット判定されるため CI では証明できない）。

## [1.6.1] — Phase 4 追補（bgutil POトークンプラグイン同梱 — POトークン設定が稼働）

しあ の明示的な了承を受け、1.6.0 で設定と配管のみ先行していた PO トークンを実際に同梱した:

- **プラグイン同梱**: `scripts/bootstrap_python.sh` が `bgutil-ytdlp-pot-provider==2.0.2`（PyPI、GPL-3.0）を yt-dlp / yt-dlp-ejs と同じ pip 取得でピン留めし、`app_packages/yt_dlp_plugins/extractor/`（`getpot_bgutil.py` + `getpot_bgutil_http.py`）に配置。yt-dlp 2026.11.23 が sys.path 上の `yt_dlp_plugins` から in-process で自動検出する。**HTTP モード（base_url）のみ**: サブプロセスを起動する script モードのモジュール（`getpot_bgutil_script.py`）は bootstrap 直後に削除し、iOS では選択不能にしてある。同梱は無改変で、対応ソースは PyPI / GitHub の公開物と同一（記録は THIRD_PARTY_LICENSES.md）。
- **Settings**: POトークン節とステータス文から「プラグイン未同梱のため不活性」の注記を撤去。ベース URL + トグル ON で同梱プラグインがそのサーバーからトークンを取得する。既定は OFF/空のまま。
- **検証（ブリッジ）**: `opts_probe` を拡張し、プラグインモジュールの import（yt-dlp のプラグインローダと同じ経路）後に yt-dlp の POT プロバイダレジストリ（`_pot_providers`）へ `bgutil:http` が登録されることと、script モジュールが不在であることを報告するようにした。`EmbeddedPythonRuntimeTests` のアサーションを「未同梱=false」から「同梱=true + レジストリ登録 + script 不在」に反転。トークンの実 mint はしていない（到達可能な bgutil サーバーが CI に無いため、捏造しない）。
- **IPA 検証済み**: Build IPA run 45591871063 成功、**27,500,900 bytes**（1.6.0 比 +21,794）。展開して `Payload/VYRA.app/app_packages/yt_dlp_plugins/extractor/getpot_bgutil.py` / `getpot_bgutil_http.py`（+ .pyc）の存在と、`getpot_bgutil_script.py` が含まれないことを確認済み。同 run でテストターゲットのコンパイル（build-for-testing）も成功している。
- **未完（ランナー容量）**: iOS Build run 45591870994 は macos-26 プールの容量不足でキューキャンセルが続いており（attempt 1〜4、いずれもステップ未実行のまま15分でキャンセル = テスト失敗ではない）、シミュレータでのレジストリ検証テストの実走はプール復旧待ち。復旧後に同 run を rerun すればよい。

## [CI] — iOS Build の最適化（シミュレータ固定 / Vendorキャッシュ / 選択的テスト）

実測で iOS Build の約30分（run 45575011865: 30分35秒）の内訳は、テスト実行 約19分52秒、FFmpeg のソースビルド 約4分18秒、起動スクリーンショット（任意）約3分48秒、アプビルド 約1分、Python bootstrap 約7秒だった。しあ の指示（実機基準は iPhone 17 Pro、変更していない部分のテストは毎回やらない）で以下を入れた:

- **シミュレータ固定**: テスト先を「利用可能な iPhone」から **iPhone 17 Pro**（名前で解決し UDID 指定、iOS 26.4 で使用を確認）に変更。イメージから消えた場合は黙って別機種で走らせずステップを落とす。
- **Vendor キャッシュ**: `actions/cache` で `Vendor/Python.xcframework` + `app_packages` と `Vendor/FFmpeg.xcframework` + `Vendor/FFmpeg` を再利用。キーは bootstrap スクリプトのハッシュ（完全一致のみ、prefix フォールバックなし＝古い生成物の誤用防止）。`bootstrap_python.sh` にはバージョンマーカーによる高速パスを追加し、キャッシュヒット時は pip 再インストールを省略。Build IPA も同じキャッシュを使う。
- **選択的テスト**（`scripts/select_tests.sh`、フィクスチャ付きセルフテスト内蔵）: 変更パスを分類してモードを決める。`full`（全部）/ `heavy`（高速 unit + 実エンジン系［埋め込み Python/JSC・FFmpeg remux/transcode］、UI テスト省略）/ `ui`（高速 unit + UI テスト、実エンジン系省略）/ `core`（高速 unit のみ）/ `none`（ドキュメントのみ）。実エンジン系は PythonBridge / FFmpegBridge / bootstrap / 当該テストの変更時のみ、UI テストは Views / Components / App / VYRAUITests の変更時のみ。Models / Services 等の共有コア、ワークフローやプロジェクト設定、分類不能なパスは安全側で `full`。モードと理由はログとステップサマリに残す。起動スクリーンショットは full のときだけ実行。
- **ドキュメントのみの push は両ワークフローとも起動しない**（`Documentation/**`、`**/*.md` を paths-ignore）。フルスイートは workflow_dispatch からいつでも実行可能（dispatch は常に full、`full_suite` 入力あり）。

## [1.6.0] — Phase 4 追補（yt-dlp生出力 / 任意Cookie / 失敗分類と失敗キャッシュ / POトークン設定 / worker.js からの採用）

実機で「選択肢が一個しかなかった」という報告を受け、原因切り分けの道具と、しあ が共有した LAN ワーカー（worker.js、公開 Web サービス用）の仕組みのうち個人アプリに合うものを採用した。worker.js は公開サービス向けにサーバー規模の運用機構（複数 Cookie のローテーション、アカウント切替リトライ、Cookie レース/クールダウン、03:00–08:30 の Cookie フリー時間帯、unavailable の5回連続カウント、LRU/inflight キャッシュ、LAN ゲート等）を持つが、**しあ の明示判断により、それらの運用プラットフォーム部分は個人用アプリには過剰として採用しない**（当初実装しかけたマルチスロット/ローテーション/フリー時間帯は撤回済み）。採用したのは以下:

- **yt-dlp生出力ビューア**: ブリッジの `extract` が整形済みの生 info JSON（formats 配列を含む完全な辞書、10MB で明示マーカー付き切り詰め、直列化できない値は repr フォールバック）を返すようになった。Swift 側 `RawOutputStore` が Application Support/VYRA/raw/ に URL+時刻ヘッダ付きで直近3件を保存し（メタデータ取得のたび）、Settings「yt-dlp生出力」からモノスペース表示・共有・コピーができる。失敗した抽出では部分 JSON が存在しないため保存しない（捏造しない）。
- **任意 Cookie（単一セット）**: Settings「Cookie」から Netscape 形式 cookies.txt を取り込み可能にした（検証: 空ファイル/形式不一致は保存しない。件数のみ数え、値は表示・ログ・共有に一切出さない。共有 UI 自体を作らない）。保存先は Application Support/VYRA/cookies/cookies.txt（FileProtectionType.completeUnlessOpen）。有効トグルが ON のときだけ、ブリッジが extract / download / 診断テストすべてに `cookiefile` を渡す。OFF は単に「Cookieなし」という通常の選択肢。
- **失敗分類**（`YtDlpFailureClassifier`、worker.js `classifyTerminalFailure` の分類体系を移植）: レート制限（アカウント単位）は最初に判定し**決して終端的扱いにしない**。live_scheduled / premiere_scheduled は「in N units」を解析して日本語化。members_only / deleted / private / copyright_removed / account_terminated / drm_protected / unavailable を分類し、分類できた失敗は日本語メッセージを主表示にする（メタデータ取得エラー、進捗画面、Settings の診断テスト結果。生文は詳細行とデバッグログに残る）。
- **失敗キャッシュ（軽量版のみ）**（`TerminalFailureStore`）: 終端的な失敗を動画ID（厳密な11文字検証を通ったものだけ）ごとに JSON ファイルへ記録。members_only は恒久、その他は15分で失効。記録がある動画は yt-dlp を実行せず、キャッシュ判定である旨を添えて即座に失敗を返す。unavailable とレート制限は記録しない。カウンタ・連続失敗カウント・統計類は入れていない。
- **POトークン（設定のみ）**: Settings「POトークン」にベース URL 欄+有効トグルを追加し、有効時はブリッジが worker と同じ `youtube:pot_provider=bgutil:base_url=<url>` を extractor_args に入れる（extract/download/診断テスト共通、`opts_probe` で配管をテスト可能）。**ただし bgutil プラグイン本体（bgutil-ytdlp-pot-provider 2.0.2、GPL-3.0）は未同梱**のため、現時点ではこの設定は不活性（プラグインを取り込んだ時点でそのまま効く。経緯は THIRD_PARTY_LICENSES.md の「同梱予定」節）。
- **形式 URL の有効期限**（worker.js `getExpireMs` の規則）: ブリッジが形式ごとの URL をメタデータに載せ、`FormatURLExpiry` が `expire` パラメータから「期限−60秒」を導出。選択肢（分割ペアは早い方）に伝搬し、確認画面で期限切れの選択はダウンロード開始を止めて再取得を促す（ダウンロード自体は yt-dlp が format_id から URL を再解決するので、これは中途失敗の予防ガード）。
- テスト: 分類（worker のパターンをフィクスチャ化）、失敗キャッシュの TTL/恒久性/記録拒否、単一 Cookie セットの取り込み/検証/トグル/削除、expire 解析、POT 配管（ブリッジ `opts_probe` の実ランタイム確認を含む）を追加。

## [1.5.0] — Phase 4 追補（全解像度対応: コーデック/コンテナで絞らない + transcode 実装、README 全面書き直し）

実機で「まだ 360p しか選べない」という報告を受け、しあ の指示（コーデックやコンテナで選択肢を絞らない。ffmpeg で後々できるから）で全面対応した。

### 診断（なぜ 360p しか選べなかったか — 実地確認）

しあ のテスト動画 `qwYhKlY4Tx0`（YOASOBI「咲き誇れ」）を、ピン留め済み yt-dlp 2026.11.23 + ブリッジと同一のクライアント構成でこのマシンから抽出し、全形式を表にした:

- 返ってきたメディア形式は **HLS の結合形式（itag 91〜96: 144p〜1080p、avc1+AAC、m3u8）が 6 件と、itag 18（360p、https 結合）のみ**。DASH の分割形式（137/248/140 等）は **1 件も返らなかった**（web/web_safari/mweb の https 形式は SABR 実験で URL 欠落としてスキップされ、この回線では tv 等が bot 判定で拒否された。しあ の自宅回線では事情が違いうるが、「360p 超が HLS でしか返らないセッションが存在する」ことは実証された）。
- つまりこの動画・このセッションでは、**アプリが HLS を除外していること自体が 360p 上限の直接原因**になりうる（HLS は今回も対象外のまま — 下記「残る制約」参照）。
- 加えてコード側の絞り込みが2段あった: (1) `YtDlpMetadataMapper.supportedContainers` が mp4/m4a のみで、**WebM 形式はメタデータ段階で破棄**されていた。(2) `MediaFormatService` が動画は MP4 コンテナ + avc1 分割ペアしか出さなかった。DASH 形式が返る動画でも VP9 の高さ（1440p/2160p 等）は永遠に選べなかった。

### 対応

- **選択肢の全面開放**（`MediaFormatService`）: 高さごとに1つの選択肢を出す。勝者の優先順位は (1) MP4 にストリームコピーできる形式（avc1、結合済みを分割より優先）→ (2) その高さの最良品質（コーデック/コンテナ不問、VP9/AV1/WebM 含む）。分割の音声ペアは AAC（m4a）を優先し、なければ最良の音声（opus 等）。音声のみ形式は全コンテナを M4A 選択肢として出す（opus は AAC に変換）。`DownloadQuality` に 144/240/480/1440/2160 を追加し、「Original = 全体の最高の高さ」を常に併記する。マッパーは webm を保持するようになった（mhtml 等は引き続き破棄）。
- **transcode 実装**（`FFmpegBridge/TranscodeBridge.c` + `FFmpegTranscoder`）: コピーできない形式は、ダウンロード後にデコード → libavfilter で形式変換（映像は NV12、音声は FLTP）→ 再エンコードする。映像は **h264_videotoolbox**（ハードウェア。使えなければ実エラーを返す。GPL の x264 は入れない）、音声は FFmpeg ネイティブ AAC エンコーダ。ビットレートはソースの推定サイズ/長さから導出（不明時は高さ別テーブル）。進捗は変換の実進捗（処理済み時間割合）を進捗画面に「変換中…」+ % で表示し、キャンセル（割込みコールバック+ループ確認）と実エラーの伝搬（進捗詳細 + デバッグログ種別 transcode）も remux と同水準にした。
- **FFmpeg 構成の拡張**（`scripts/bootstrap_ffmpeg.sh`）: matroska デマルチプレクサ、ネイティブデコーダ（h264/vp9/av1/aac/opus/mp3/vorbis）、h264_videotoolbox + ネイティブ aac エンコーダ、libavfilter（buffer/buffersink/abuffer/abuffersink/format/aformat/scale/aresample/null/anull）+ libswscale/libswresample を有効化し、xcframework に同梱。configure 出力で **LGPL-2.1-or-later** を再確認（GPL 部品・外部ライブラリなし）。アプリには VideoToolbox / CoreMedia / CoreVideo / CoreFoundation をリンク追加。
- **事前検証**: TranscodeBridge は CI 前に Linux 上で FFmpeg 9.1（同一コンポーネント構成）をビルドして実地テストした（VP9+Opus 分割 / 結合 WebM / Opus 単体の3経路とも正常な MP4/M4A を出力。エンコーダだけ mpeg4 で代替 — VideoToolbox は macOS 専用のため）。
- **テスト**: 選択肢/優先順位の単体テストを新仕様に更新・追加し、`FFmpegTranscodeTests` で VP9/Opus フィクスチャ（lavfi 生成、各 50KB 未満）の実 transcode をシミュレータで実行して AVAsset で H.264/AAC 化・長さ・再生可否・進捗 1.0 到達を検証する。全161件成功（iOS Build run 45556670928）。
- **README.md を全面書き直し**: Phase 2 時点の記述（「yt-dlp は組み込まない」「Phase 3 が最新」等）が実態と乖離していたため、現在のアプリ（組み込み yt-dlp、remux/transcode、保存先選択、診断/デバッグログ、正直な制約）に合わせて再作成した。
- IPA run 45556670919 成功、IPA 27,380,166 bytes。アプリ本体バイナリ内に `h264_videotoolbox` / vp9 デコーダの文字列と yt-dlp 2026.11.23 が含まれることを展開して確認済み。

### 残る制約（正直な記録）

- **HLS は引き続き未対応**。上記診断のとおり、セッションによっては 360p 超が HLS でしか返らず、その場合は今回の対応でも選べる解像度が限られる。HLS 対応（ネイティブ HLS ダウンローダの TS 出力を FFmpeg で MP4 化する等）は別課題として残す。
- transcode は時間がかかり非可逆（再エンコード）。コピー可能な形式は従来どおり無劣化・高速。

## [1.4.0] — Phase 4 追補（FFmpeg 組み込み: 複数解像度 / 保存先選択 / タブバー刷新 / 歯車削除）

実機でダウンロード成功を確認したが、選べるのは 360p（映像+音声がセットの形式）だけだった。しあ の指示で4件を実施。

- **FFmpeg 組み込み（ソースビルド）**: `scripts/bootstrap_ffmpeg.sh` を新設し、FFmpeg **9.1**（ffmpeg.org で最新安定版を実地確認）を CI でソースからビルドする。構成は remux に必要な最小限（file プロトコル、mov/mp4/m4a デマルチプレクサ、mp4 マルチプレクサ、h264/aac パーサ、aac_adtstoasc）で、configure の出力どおり **LGPL-2.1-or-later**（GPL 部品・外部ライブラリなし）。デバイス arm64 + シミュレータ fat（arm64+x86_64 — 汎用シミュレータ宛先が x86_64 でもリンクするため）の静的 `FFmpeg.xcframework` を `Vendor/` に生成し、アプリにリンクする（IPA 増分は約 +0.6MB）。プリビルドへのフォールバックは不要だった。
- **remux 実装**: `FFmpegBridge/RemuxBridge.c` が libavformat で映像のみ MP4 + 音声のみ M4A をストリームコピー結合する（サブプロセスなし、トランスコードなし）。タイムスタンプは入力コンテナの start_time 補正のみで他は素通しにし、movenc の編集リスト処理に任せる方式が `ffmpeg -c copy` と完全一致の出力を返すことを Linux 上で実地比較して確定。キャンセルは FFmpeg の割込みコールバックで受ける。Swift 側は `FFmpegRemuxer` / `FFmpegRemuxJob`。
- **複数解像度の選択**: `MediaFormatService` が avc1 映像のみ MP4 と最良の m4a 音声のみ（最高ビットレート）をペアとして選択肢に出すようになった。720p / 1080p / Original（avc1 の最高解像度）が選べる。同じ高さでは結合済み形式を優先し、「Original」は最高の高さ→結合済み優先→最大サイズで選ぶ。ペアの推定サイズは両ストリームの合計。VP9/AV1/WebM の分割形式はトランスコードが必要なため引き続き出さない（今後の課題）。HLS も引き続き除外。
- **分割ダウンロードの流れ**: 映像レグ→音声レグ→remux。進捗は `SplitProgressCombiner` が合算し、総バイト数は両レグ分が判明するまで不確定のままにする（嘘の % を出さない）。remux 中は進捗画面に「結合中…」の不確定表示を出す（`DownloadProgress.phase`）。キャンセルは両レグと remux の両方に効き、一時ファイルは残さない。remux 失敗時は FFmpeg の実エラー（工程名+内容）を進捗画面の詳細とデバッグログ（種別 remux）に残す。Settings のダウンロードテストも最良選択がペアの場合は実 remux まで通す。
- **保存先の選択**: Settings「保存先」でフォルダを選択可能にした（ドキュメントピッカー、セキュリティスコープ付きブックマークを UserDefaults に永続化）。既定は従来どおりアプリ内フォルダ（Documents/VYRA）。外部フォルダへ保存したアイテムはファイル単位のブックマークを保持し、Library の再生（AVKit）・共有・削除・起動時復元がそのまま動く。ブックマークが無効になった場合はアプリ内フォルダへフォールバックし、Settings に「アクセスできません」と明示する。確認画面の保存先表示も実状態に連動。
- **ホームの歯車を削除**: 右上の歯車は装飾（無機能）だったため削除。設定は設定タブにある。
- **タブバーを Liquid Glass で刷新**: `GlassEffectContainer` 内で選択中タブに白ティントのガラスカプセルを割り当て、`glassEffectID` でタブ間にモーフィングさせる `.glassEffect()` 構成に再構築。選択中は黒文字+太字で判別しやすくした（モノクロ3色のみ）。タブの accessibility identifier と選択 trait は維持。
- テスト: 新規24件（実 remux を AVAsset で検証する `FFmpegRemuxTests` 3件、ペアリング/選択/コンバイナ/マネージャの `SplitFormatTests` 14件、保存先の `SaveDestinationTests` 7件）。既存の「結合必須形式は出さない」前提のテストは新仕様に更新。**全149件成功**（iOS Build run 45549265293）。IPA run 45549265307 成功、IPA **25,554,780 bytes**。アプリ本体バイナリ内に FFmpeg シンボルと aac_adtstoasc が含まれることを展開して確認済み。

## [1.3.2] — Phase 4 追補（抽出失敗の修正: player_js_variant 固定 + バージョン最新化）

実機（しあ・自宅回線）で再テストしたところ、今度は抽出自体が失敗した。Settings のデバッグログに残った `TypeError: a.addOnDisposeCallback is not a function`（player b485e332、N / SIG 両チャレンジ）から原因を特定した。

- **本当の原因**: クライアントではなく「プレイヤー JS のバリアント」の問題。yt-dlp 2026.8.19 の既定バリアントは `main`（player_ias 系）で、現在の player_ias ビルドは Closure の `goog.Disposable` 系コードを含み、yt-dlp-ejs 0.8.0 のソルバが抽出関数を実行する環境には `addOnDisposeCallback` が存在しないため前処理で落ちる。JavaScriptCore 固有の問題ではなく、Node（V8）でも同一エラーが再現することをオフラインで確認した。yt-dlp 2026.11.23 では既定バリアントが `tv` に変更されており、この経路では発生しない。
- **証拠（決定的再現）**: 実プレイヤー b485e332 を取得し、yt-dlp-ejs のソルバ生成物に実チャレンジを食わせるハーネスで検証 — ias バリアントでは実機と同一の TypeError、tv / es6 バリアントでは正常解決（n 変換結果も一致）。yt-dlp 2026.11.23 の実 CLI フロー（しあ の実 URL + VYRA のクライアント列）でも tv バリアントが強制され正常解決した。
- **修正**（`vyra_bridge.py`）: `extractor_args.youtube.player_js_variant` を `['tv']` に明示固定。yt-dlp 本体の既定が将来また変わっても再発しないようにした（既定任せにしない）。
- **バージョン最新化**（`scripts/bootstrap_python.sh` のピンのみ変更）: yt-dlp 2026.8.19 → **2026.11.23**（PyPI 最新を実地確認。3ヶ月古いまま「最新」と記録されていた）、Python-Apple-support 3.14-b11（CPython 3.14.7）→ **3.14-b14**（CPython **3.14.10**）。yt-dlp-ejs 0.8.0 は現行最新のため据え置き。
- **Settings**: 診断に yt-dlp-ejs のバージョン行を追加（従来は未表示だった）。
- **回帰テスト（シミュレータ・実 JavaScriptCore）**: `EmbeddedPythonRuntimeTests` に2件追加 — (1) `testPlayerJSVariantIsForcedToTV`: ブリッジ経由で解決されるプレイヤー URL が tv バリアントであること。(2) `testJSCSolverSolvesBundledPlayerFixture`: 実プレイヤー b485e332（tv バリアント）をテストフィクスチャとして同梱し、本物の登録済み JSC プロバイダ + `_host` 経由で N / SIG チャレンジを解かせ、N の結果が既知の正解と一致することまで検証。あわせてランタイムのバージョンテストに yt-dlp 2026.11.23 / yt-dlp-ejs 0.8.0 のピン主張を追加（ピンとテストがずれたら落ちる）。
- テスト: 全125件成功（iOS Build run 45541311488。新規2件とも合格、JSC ソルバ実地テストは 1.7 秒）。IPA run 45541311422 成功、IPA 24,953,407 bytes。IPA 内の `yt_dlp/version.py` が `2026.11.23` であること、ブリッジに `player_js_variant` 固定が含まれることをダウンロードして確認済み。

## [1.3.1] — Phase 4 追補（ダウンロード失敗の修正: エラー可視化 + クライアント設定 + 形式選択）

実機（しあ・自宅回線）で抽出は成功するのにダウンロードが 4% で失敗し、汎用メッセージしか出ない問題への対応。

- **本当の原因の内訳**: (1) 形式選択バグ — 音声のみの超低ビットレート MP4（itag 599 等、約2.2MB）が「MP4 / Original」として選ばれていた（yt-dlp は形式を悪い順に並べるのに最初の一致を取っていた＋360/720/1080 以外の全高さが Original に潰れていた）。映像が入っていない上に、その形式のクライアントは PO トークン必須で googlevideo が途中 403 になる条件が揃っていた。(2) ダウンロード自体のクライアント設定 — 既定クライアント（web 等）は GVS PO トークンが必須（yt-dlp 2026.8.19 の `INNERTUBE_CLIENTS` ポリシーで実地確認）。
- **ブリッジ**（`vyra_bridge.py`）: `extractor_args.youtube.player_client` を `['tv', 'web_safari', 'web_embedded', 'web', 'mweb', 'ios']` に設定（PO トークン不要の tv / web_embedded と、結合済み HLS を返す web_safari を先頭にし、共有 itag の URL は先行クライアント優先で決まる）。`android_vr` はこの版では必須側＋全形式 403 の報告があるため除外。`http_chunk_size` 10MB、`concurrent_fragment_downloads` 4 を追加。形式マップに protocol / tbr / abr / width を追加し、ジョブエラーに traceback を含めた。
- **形式選択**（`MediaFormatService`）: 音声のみ形式を動画コンテナの選択肢に出さない。HLS(m3u8) 形式は TS データが .mp4 名になるため remux 実装まで選択肢から除外。「Original」は最大高さ→最大サイズの最良単一ファイル形式を選ぶ `selectOption` に一本化（リゾルバと既知サイズ表示で共用）。
- **エラー可視化**: Python 例外は `DownloadError.detailMessage`（最後の意味のある行）→ `DownloadItem.errorDetail` → 進捗画面の失敗表示（小さな灰色テキスト、選択可）まで伝搬。`DebugLogStore` を新設し、抽出・ダウンロードの失敗を Application Support/VYRA/logs/ にセッション保存（最新5件、例外＋yt-dlp ログ末尾30行＋traceback）。Settings「デバッグログ」セクションで閲覧・ShareLink 共有が可能。
- **Settings**: 「ダウンロードテスト」を追加（固定テスト動画の最良単一ファイル MP4 を実際にダウンロードし、バイト数 or 完全なエラーを表示）。
- テスト: 新規8件（Original 選択の回帰、HLS 除外、エラー詳細の伝搬、ダウンロードテスト、ログローテーション）。全123件成功（iOS Build run 45528329962）。ブリッジはローカルでも検証（opts / 形式マップ / ローカル HTTP の DL 成功・失敗時の error+log+traceback）。

## [1.3.0] — Phase 4（yt-dlp エンジン: CPython 組み込み）

※ **方針転換**: Phase 2/3 の「yt-dlp は iOS で実現不可能・組み込まない」という結論は、2026-11-25 のプロジェクトオーナーの明示指示により撤回された。実在する動作事例（Squirrel 等）の方式を、コードを複製せず独自実装した。

- 埋め込みランタイム: BeeWare Python-Apple-support 3.14-b11（CPython 3.14.7）の `Python.xcframework` をリンク+同梱。`scripts/bootstrap_python.sh` が CI で yt-dlp 2026.8.19 / yt-dlp-ejs 0.8.0 / certifi を取得し `Vendor/`（gitignore）に配置。標準ライブラリと拡張モジュールは「Install Python Runtime」ビルドフェーズがアプリバンドルへ配置する。
- Python ブリッジ: C 層（`PythonBridge/PyBridge.c`）が CPython をプロセス内で初期化し、組み込みモジュール `_host`（run_js）を提供。Python 側 `vyra_bridge.py` が JSON API（configure / versions / run_js / extract / download_start / download_status / download_cancel）を提供。サブプロセスは一切使わない。
- JSC プロバイダ: yt-dlp 公式の JS チャレンジプロバイダ API を実装した `jsc_provider.py` が、yt-dlp-ejs のソルバを JavaScriptCore（Swift 側 `JSCRunner`）で実行する。
- Swift エンジン: `YtDlpRuntime`（インタプリタ寿命管理、16MB スタックの専用スレッド）、`EmbeddedYtDlpEngine`（抽出 / ポーリング式ダウンロード / 協調的キャンセル）、`YtDlpDownloadEngine`（`DownloadService` 実装）、`MockYtDlpEngine`（テスト用）。
- 配線: `YtDlpIntegrationProvider` をスタブから実プロバイダ化（形式一覧は実 yt-dlp 出力のみ、formatID・サイズ付き）。`DirectMediaResolver` に yt-dlp 経路を追加し、`DownloadTaskManager` が formatID の有無でエンジンを選択。直接ファイル URL は従来の URLSession 経路のまま。
- 制限: 結合（マージ）が必要な形式はダウンロード対象外（ffmpeg 未組み込み）。HLS はネイティブダウローダ使用、ポストプロセッサなし。
- Settings: 「エンジン」診断セクションを追加（実エンジンが返す Python / yt-dlp バージョン、JSC プロバイダ状態、固定 URL への抽出テスト）。ライセンス文言を実態に合わせて修正。
- テスト: `YtDlpEngineTests`（マッパー / 選択肢 / リゾルバ / マネージャ / 設定診断）と `EmbeddedPythonRuntimeTests`（シミュレータ上で実インタプリタ起動・バージョン取得・JSC 往復、リソース不在時はスキップ）を追加。ライブネットワークテストは CI では行わない。
- ドキュメント: `Phases/PHASE_4_YTDLP.md`、`HANDOFF/PHASE_4_HANDOFF.md`、`THIRD_PARTY_LICENSES.md` を追加。AGENTS / MASTER / ARCHITECTURE / Phase 2・3 文書に方針転換を記録。
- IPA: 無署名 IPA は約 24.8 MB（従来 0.5 MB）。アプリバンドル展開時 76 MB。

## [1.2.0] — Phase 3（ダウンロード・保存・Library 完成）

- ダウンロードエンジン: yt-dlp は組み込まず（iOS 実行不可能、Phase 2 調査を踏襲）、直接 HTTPS メディアファイル URL 専用の `URLSessionDownloadEngine` を `DownloadService` プロトコルの背後に実装。ページ URL は `DirectMediaResolver` が開始前に拒否し、明確なエラーで失敗する。
- `DirectMediaProvider` を追加し、集約の既定配線に接続: 直接ファイル URL（.mp4/.mov/.m4a）は HEAD で確認し、ファイル自身の形式のみを `availableFormats` とする。
- `DownloadTaskManager` を追加: 開始・実進捗・キャンセル（タスク停止 + 一時ファイル処理、Library 未登録）・再試行（新規タスク）・複数タスク・状態遷移検証。Phase 2 の `DownloadManager` プロトコルは `DownloadCapabilityEvaluating` に改名。
- `DownloadState` に queued / preparing を追加（waiting は互換維持）。paused は再開を保証できないため実装しない。`DownloadProgress`（割合は総サイズ判明時のみ）と `DownloadError`（日本語 userMessage / ログ用詳細を分離）を追加。
- `MediaFormatOption` / `MediaFormatService` を追加: 形式・品質の選択肢は実在する情報からのみ生成。M4A では品質 UI 非表示を維持。
- `FileStorageService`（Documents/VYRA、一時領域、移動・削除・重複名解決・サイズ/存在確認）と `FileNameValidator`（サニタイズ・空拒否・拡張子保護）を追加。
- Download Confirmation: ファイル名編集、判明している情報のみ表示、保存先表示、ダウンロード不可理由の表示。Download Progress: 実バイト数・速度・残り時間、総サイズ不明時は % 非表示。
- Library: SwiftData 永続化（起動時復元・実ファイル確認・孤児レコード修復・中断分は failed 扱い）、AVKit 再生、実ファイル ShareLink、確認付き削除（ファイル + レコード同期）。モック追加ボタンは廃止。
- テスト: `Phase3DownloadTests` を追加（マネージャ/ストレージ/ファイル名/状態遷移/形式/Library+SwiftData/URLProtocol スタブによるエンジン、全てオフライン）。
- バックグラウンドダウンロードは実装しない（フォアグラウンドのみ、UI とドキュメントに明記）。実機 IPA 作成・インストールは未検証。

## [1.1.0] — Phase 2（改訂仕様: MetadataProvider 方式）

- `URLValidationService` を追加・一般化: URLComponents による構造化解析、HTTPS必須、ソース種別分類（youtube / genericHTTPS / unsupported）、類似ホスト拒否。YouTube 形式（watch / youtu.be / shorts / embed / live）と動画ID検証（11文字）を維持。
- `VideoMetadata` モデルを追加（id, title, creatorName, sourceName, thumbnailURL?, durationSeconds, publishedAt?, description?, sourceURL, availableFormats?）。取得できない項目は nil（推測で埋めない）。
- `MetadataProvider` protocol と集約サービス `VideoMetadataService` を追加。プロバイダ: `MockMetadataProvider`（テスト/プレビュー専用、明示的にモック）、`YtDlpIntegrationProvider`（インターフェーススタブ、常に integrationUnavailable）、`AuthorizedSourceProvider`（許可確認済みの場合のみ返す骨格、デフォルト未確認）。
- アプリのデフォルト配線は集約（Authorized + YtDlp スタブ）。実URLは明確なエラーで失敗し、モックを実データとして見せない。
- `Models/DownloadCapability.swift` を追加（Phase 3 への設計のみ）: DownloadSource / AvailableMediaFormat / DownloadPermission（デフォルト unknown）/ DownloadCapability / DownloadManager プレースホルダ。ダウンロード実装はなし。
- HomeViewModel: FetchState、重複実行防止、キャンセル、再試行、recentFetches（インメモリ）、エラー種別ごとの日本語メッセージ。
- VideoPreviewViewModel / Views: メタデータ表示（AsyncImage サムネイル、公開日・説明）、再試行ボタン、最近取得表示。Phase 1 のデザインと形式・品質ロジックは不変。
- テスト: URLValidationTests 19件、VideoMetadataTests（プロバイダ/集約/権限）15件、ViewModelTests 11件を追加・改訂。Secrets・外部ネットワークなしで全件実行可能。
- ドキュメント: MASTER / ARCHITECTURE / DESIGN_SYSTEM / DEVELOPMENT_RULES / PHASE_2_METADATA / AGENTS / README を改訂し、`HANDOFF/PHASE_2_HANDOFF.md` を作成。

※ 方針変更の経緯: 当初 Phase 2 は YouTube Data API v3 方式で実装を進めたが、改訂仕様により **YouTube Data API 依存を全て撤去**した（サービス・DTO・APIキー関連の記述を削除）。
※ yt-dlp は改訂仕様に基づき調査した結果、iOS では実現不可能・不適合（CPython/ffmpeg/JSランタイム要件、サンドボックスの外部プロセス禁止、n/sig 解読は署名回避）と判断し、**組み込んでいない**。根拠は `Phases/PHASE_2_METADATA.md`。
※ ビルド・テスト結果（2026-11-24）: GitHub Actions run 45381348474（PR #1）でビルド成功・テスト76件全件成功（Unit 72件 + UI 4件）。Xcode 26.6 / iOS Simulator SDK 26.5 / iPhone 17 Pro。
※ 途中経過: 公式API方式時点の run 45379350930 でもビルド・テスト成功（69件）を確認したが、その実装は改訂仕様により置き換え済み。

## [1.0.0] — Phase 1

- VYRA プロジェクトを新規構築（SwiftUI / MVVM / SwiftData、iOS 26.0）。
- 全画面を実装: Home、Video Preview、Format Selection、Download Confirmation、Download Progress、Library、Settings。
- Liquid Glass フローティングタブバー（Home / Library / Settings）を実装。
- URL入力・貼り付け・クリア・バリデーション、モック動画情報表示、形式/品質選択（M4A時は品質非表示）、モック進捗（キャンセル/完了/失敗）、ライブラリへのモック追加・削除を実装。
- Unit Test / UI Test を追加。
- GitHub Actions ワークフロー（macos-26、Simulatorビルド、テスト、Artifacts保存）を追加。
- ドキュメント一式（MASTER / ARCHITECTURE / DESIGN_SYSTEM / DEVELOPMENT_RULES / Phases / HANDOFF）を作成。

※ ビルド・テスト結果（2026-11-24）: GitHub Actions run 45372323350 でビルド成功・テスト31件全件成功を確認。詳細は HANDOFF 参照。
- 修正履歴: SDKROOT=iphoneos の追加（宛先エラー修正）、DownloadProgressScreen.swift への改名（同名ファイル衝突修正）、スクリーンショット取得ステップの改善（シミュレータ起動+アプリ起動で Home を撮影）。
