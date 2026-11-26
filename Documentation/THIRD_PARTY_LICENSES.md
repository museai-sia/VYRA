# THIRD-PARTY LICENSES — Phase 4 で同梱するコンポーネント

Phase 4（2026-11-25）から、VYRA はアプリ内に CPython と yt-dlp を同梱する。
バージョンは `scripts/bootstrap_python.sh` にピン留めされ、CI が毎回
取得する（リポジトリにはバイナリをコミットしない）。

| コンポーネント | バージョン | ライセンス | 備考 |
|---|---|---|---|
| CPython | 3.14.10（Python-Apple-support 3.14-b14 同梱ビルド） | Python Software Foundation License | 標準ライブラリ内の `LICENSE.txt` がアプリバンドルにも含まれる（`python/lib/python3.14/LICENSE.txt`） |
| Python-Apple-support（BeeWare） | 3.14-b14 | BSD-3-Clause（BeeWare スイートのライセンス） | ビルド支援パッケージ。`Python.xcframework` と `build/utils.sh` を使用 |
| yt-dlp | 2026.11.23 | Unlicense | pip パッケージをそのまま `app_packages` に同梱。`License-Expression: Unlicense` を dist-info で確認 |
| yt-dlp-ejs | 0.8.0 | Unlicense AND MIT AND ISC | JS チャレンジソルバ。`License-Expression: Unlicense AND MIT AND ISC` を dist-info で確認 |
| certifi | 2026.11.20 | MPL-2.0 | CA 証明書バンドル。yt-dlp の HTTPS 検証用 |
| FFmpeg（libavformat / libavcodec / libavfilter / libswscale / libswresample / libavutil） | 9.1 | LGPL-2.1-or-later | 分割形式の結合（remux、ストリームコピー）と、コピーできない形式の変換（transcode: VP9/AV1/WebM 等 → H.264 + AAC の MP4）用にライブラリとして静的リンク。`scripts/bootstrap_ffmpeg.sh` が ffmpeg.org の公式ソースから最小構成でビルドする（file プロトコル、mov/matroska デマルチプレクサ、mp4 マルチプレクサ、ネイティブデコーダ h264/vp9/av1/aac/opus/mp3/vorbis、h264_videotoolbox エンコーダ、ネイティブ aac エンコーダ、libavfilter の format/aformat + libswscale/libswresample による形式変換のみ有効化。GPL コンポーネント（libx264 等）・外部ライブラリ・プログラムは一切含まない。configure の出力でも "License: LGPL version 2.1 or later" を確認済み。H.264 エンコードは OS の VideoToolbox（ハードウェア）を使うため FFmpeg 側に GPL エンコーダは不要） |
| OpenSSL / libffi / bzip2 / xz / zstandard / mpdecimal | Python-Apple-support 同梱版（VERSIONS 参照） | 各プロジェクトのライセンス（Apache-2.0 / MIT / BSD 系など） | CPython ビルドの依存として xcframework 内に含まれる |
| bgutil-ytdlp-pot-provider（プラグイン） | 2.0.2（PyPI、2026-11-25 同梱） | GPL-3.0 | PO トークンプロバイダプラグイン。`scripts/bootstrap_python.sh` が yt-dlp / yt-dlp-ejs と同じ pip 取得で `bgutil-ytdlp-pot-provider==2.0.2` を `app_packages/yt_dlp_plugins/extractor/` に配置し、yt-dlp が sys.path 上の `yt_dlp_plugins` パッケージから自動検出する（yt-dlp >= 2025.05.22 必須、同梱 yt-dlp 2026.11.23 と互換）。**HTTP モードのみ同梱**（設定は extractor_args の `youtubepot-bgutilhttp: base_url`）: サブプロセスを起動する script モードのモジュール（`getpot_bgutil_script.py`）は bootstrap 時に削除し、iOS では選択不能にしてある。同梱は無改変（PyPI 配布物のまま）。対応ソースは PyPI / GitHub（Brainicism/bgutil-ytdlp-pot-provider）で公開されているものと同一 |
| BgUtils（bgutils-js、LuanRT） | ソース参照のみ（コード同梱なし） | MIT | オンデバイス PO トークン生成（`pot_ondevice.py` / `pot_driver.js`）のフロー設計の出典。BotGuard チャレンジ取得 → VM 実行 → GenerateIT → mint という手順と、Waa の公開クライアント値（リクエストキー / Google API キー）はこのプロジェクトの公開ソースに基づく。VYRA のドライバ/プロバイダは手順を独自実装したもので、BgUtils のコード自体は同梱していない。経緯と実測証拠は Documentation/POT_ONDEVICE.md |

## 参考実装について（コードは複製していない）

- **Squirrel（github.com/NatanRA/squirrel）は GPLv3**。VYRA はそのコードを
  一切コピーしていない。採用したのは公開情報としてのアーキテクチャ
  （BeeWare CPython のアプリ内組み込み、JavaScriptCore による
  yt-dlp JS チャレンジプロバイダ、サブプロセスを使わない構成）のみで、
  実装は yt-dlp 公式のプロバイダ API ドキュメントと公開 API に基づき
  独自に書いた。
- kewlbear/YoutubeDL-iOS は方式の先行事例として参照したのみで、
  SPM 依存としては採用していない（同梱 yt-dlp / Python が古いため）。

## ライセンス上の注意

- VYRA はサイドロード配布（App Store 外）。アプリ本体のコードに GPL の
  コピーレフトは及ばないが、bgutil-ytdlp-pot-provider プラグインは
  GPL-3.0 であり、そのコンポーネントには GPL-3.0 の条件が適用される
  （無改変で同梱し、対応ソースは PyPI / GitHub で公開されているものと
  同一である旨を上表に明記）。
- Squirrel（GPLv3）は上記のとおり参照のみで、コードは含まない。
- MPL-2.0（certifi）はファイル単位のコピーレフトであり、証明書バンドルを
  そのまま同梱する利用は問題ない。
