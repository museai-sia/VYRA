# PHASE 1 — UI（実装仕様・本フェーズの正本）

## 範囲

全画面UIとモック動作のみ。実ダウンロード、実メタデータ取得、外部API通信は行わない。

## 画面

- Home: VYRAヘッダー+設定アイコン、「動画を保存する」、URL入力欄（貼り付け/クリア付き、検証エラー表示）、取得ボタン、最近の履歴・保存数・空状態。
- Video Preview: 16:9サムネイル、タイトル、投稿者、時間、ソース。
- Format Selection: MP4 / MOV / M4A、品質 360p / 720p / 1080p / Original。M4A選択時は品質を非表示。選択に応じてファイル名・推定サイズ表示が変化。
- Download Confirmation: ファイル名、形式、品質、サイズ（「推定（モック）」と明示）、保存先、開始ボタン。
- Download Progress: サムネイル、進捗バー、%、状態（Waiting / Downloading / Completed / Failed / Cancelled）、キャンセル。進捗は実際に更新される。
- Library: 一覧（サムネイル、形式、サイズ、日時、共有、削除）、モック追加/削除、空状態。
- Settings: アプリ情報、バージョン、保存先、ストレージ情報、キャッシュ管理UI、ライセンス。

## タブ

Home / Library / Settings。Liquid Glass フローティングタブバー。レイアウト内に配置しコンテンツと重ねない。Safe Area 対応。

## 遷移

Home → Preview → Format Selection（Preview内）→ Confirmation → Progress → 完了で Library へ追加。

## 検証項目

仕様書セクション11の20項目に対応するテストを VYRATests / VYRAUITests / GitHub Actions で担保する。
