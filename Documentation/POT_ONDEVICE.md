# PO トークンのオンデバイス生成 — 調査と実装（2026-11-25）

しあ の希望（「POトークンサーバーもオンデバイスで出来ない？なるべく
そうして欲しい」）を受け、bgutil サーバー（自宅 LAN の PC）なしで
端末内で PO トークンを生成する経路を調査・実装した記録。結論から:
**実装した。生成方式は Settings > POトークン で「オンデバイス /
サーバー (bgutil) / オフ（既定）」から選ぶ。** ただし Google 側の
受理（実トークンが発行されるか）の最終確認は しあ の実機・自宅回線
でのテスト待ちであり、CI からは証明できない（理由は後述）。

## mint の実フロー（ソースで確認した事実）

bgutil サーバー（Brainicism/bgutil-ytdlp-pot-provider、LuanRT の
bgutils-js ベース）の mint は次の手順。VYRA の実装
（`PythonBridge/pybridge/pot_ondevice.py` + `pot_driver.js`）は
これを端末内で再現する:

1. **BotGuard チャレンジ取得**: YouTube ページ内の
   `window.ytAtN({...})` → `R.bgChallenge`（program / globalName /
   interpreterHash / interpreterUrl）。チャレンジと**同じページ**の
   `ytcfg.set({...})` を対で使う（サーバー側のコメント明記:
   別ページの ytcfg と組にすると EVENT_ID 不一致で拒否される）。
   VYRA は抽出済みの動画ページ → 取得できなければホームページを
   yt-dlp の通信（`_request_webpage`、抽出と同じ Cookie/セッション）
   で取り直す。
2. **インタプリタ JS 実行**: interpreterUrl から取得した JS を
   JavaScript 環境で評価し、BotGuard VM（`globalName` の
   オブジェクト）を得る。`vm.a(program, setupCallback, ...)` が
   非同期スナップショット関数を返す。
3. **スナップショット**: 非同期スナップショットを実行し、
   応答文字列と WebPO の minter 関数（webPoSignalOutput[0]）を得る。
4. **GenerateIT**: `POST https://jnn-pa.googleapis.com/$rpc/
   google.internal.waa.v1.Waa/GenerateIT`、body は
   `[リクエストキー, スナップショット応答]`、ヘッダは bgutils の
   getHeaders と同一（`application/json+protobuf`、
   `x-goog-api-key`（公開 Web クライアントキー）、
   `x-user-agent: grpc-web-javascript/0.1`、user-agent）。
   応答は `[integrityToken, estimatedTtlSecs, mintRefreshThreshold,
   websafeFallbackToken]`。
5. **mint**: minter に integrityToken を渡して mint コールバックを
   得て、**コンテンツバインディング**（yt-dlp の
   `get_webpo_content_binding` が算出: GVS は visitor data /
   data sync ID、PLAYER・SUBS は動画 ID）を mint する。
   バインディングは yt-dlp の POT フレームワークが
   PoTokenRequest として渡すものをそのまま使う（独自セッションは
   作らない）。

yt-dlp 側の契約（ピン留め 2026.11.23 のソースで確認）:
プロバイダは `PoTokenProvider` サブクラス（クラス名末尾 `PTP`、
`@register_provider`）で、`is_available()` と
`_real_request_pot(request) -> PoTokenResponse` を実装する。
設定は extractor_args の `youtubepot-<プロバイダキー小文字>`
名前空間から渡る。失敗時は `PoTokenProviderError` を投げれば
ディレクタが記録して**トークンなしで抽出を続行**する。

## 経路の評価とスパイク証拠

候補は2つ: (A) JavaScriptCore + 手書きシム、(B) WKWebView。
決め手は「BotGuard VM が要求する環境の忠実度」であり、Node 上で
実測した（2026-11-25、このマシンから実 Google エンドポイントへ）:

| 環境 | スナップショット | minter 関数 | GenerateIT | mint |
|---|---|---|---|---|
| Node + JSDOM（bgutils-js 純正経路） | 4,347 文字 | あり | **実 integrity token**（TTL 43200） | **実トークン 724 文字** |
| 本実装のドライバ + JSDOM の実 DOM | 4,407 文字 | あり | **実 integrity token** | **実トークン 724 文字** |
| 本実装のドライバ + 素のエンジン（シムのみ） | 959〜2,895 文字 | **なし** | integrity token なし（websafe fallback のみ） | 不可 |

- ドライバ（`pot_driver.js`）自体の正しさは実 DOM 環境で実証済み
  （実チャレンジ→実 integrity token→実トークン）。
- 素のエンジンでは VM は動作しスナップショットも完了するが、
  環境シグナルが不足し Google が integrity token を出さない。
  これは「機械は動くが受理されない」状態であり、素の JSContext
  だけに賭けるのは根拠が弱い。
- JSDOM（実ブラウザより弱い DOM 実装）で受理される以上、それより
  忠実な **WKWebView（本物の WebKit DOM）が主経路として妥当**。
  Android の NewPipe が WebView で PO トークンを生成する先行例と
  同じクラス。

よって実装は **プロバイダ（Python）+ JS ホストの2バックエンド**:
主 = WKWebView（youtube.com オリジンの空ページ、YouTube の
スクリプトは走らせないクリーンルーム。抽出セッションの Cookie は
共有せず、バインディングは yt-dlp の要求に従う）、
副 = 持続 JSContext（WebView が作れない場合のフォールバック。
ドライバは実 DOM があればそれを使い、無ければシムを入れる）。

## ついでに見つけた既存バグ（修正済み）

サーバー方式の配管が、ピン留め yt-dlp 2026.11.23 では**黙って
無効**だった: ブリッジは `youtube:pot_provider=bgutil:base_url=...`
を渡していたが、この引数を読むコードは yt-dlp のソースツリーの
どこにも存在しない（grep で確認）。正しくは
`youtubepot-bgutilhttp: {base_url: [...]}`。今回の変更で修正し、
`opts_probe` の検証も新しい配線に合わせた。

## フォールバックと失敗時の挙動

- mint のどの段階で失敗しても `PoTokenProviderError` → 抽出は
  トークンなしで続行（従来動作）。失敗はブリッジ応答の
  `pot_events` 経由でアプリのデバッグログに kind `pot` で残る。
  リトライのループはしない（minter キャッシュが古い場合の
  再構築は1回だけ）。
- GenerateIT が integrity token を返さず websafe fallback
  トークンのみの場合: セッションバインドの GVS 要求に限り
  fallback トークンを返す（YouTube の Web クライアント自身の
  フォールバックと同じ使い方）ことを明示ログに残す。動画 ID
  バインド（PLAYER/SUBS）では使わず、失敗として扱う。
- トークンの捏造はしない。モックで証明したのは機械と配管まで。

## 証明済み / 未証明

証明済み:
- ドライバ+実 DOM で実 Google 相手の全フロー（上表）。
- プロバイダの配管: 登録・設定ゲーティング・フェイク VM での
  全フロー（バインディング伝播を検証）— ローカル + シミュレータ。
- 実チャレンジフィクスチャでの実 VM スナップショット実行
  （JSC / WKWebView 両バックエンド、シミュレータ）。

未証明（しあ の実機確認待ち）:
- iPhone 実機の WKWebView 環境で Google が integrity token を
  発行するか（CI の IP は Google にボット判定されており、CI から
  の失敗は実機の失敗を意味しない。抽出と同じ構図）。
- 発行されたトークンで YOASOBI の URL の形式選択肢が増えるか。
