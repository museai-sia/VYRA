# VYRA — DEVELOPMENT_RULES

## コーディング

- MVVM を守る。View にビジネスロジックを書かない。UI から直接通信しない。
- Swift Concurrency を優先する。状態は ViewModel に集約する。
- 認証情報をコード・ログに含めない。不要な外部ライブラリを追加しない。
- Phase 境界を守る。モックである箇所はUI文言でも「モック」「推定」と明示する。

## メタデータ取得（Phase 2 改訂仕様）

- **YouTube Data API に依存しない。** APIキーや Secrets を前提にしない。
- **yt-dlp を組み込まない。** Python の同梱、外部プロセス実行、シェルアウトは禁止。yt-dlp は調査記録とインターフェーススタブ（`YtDlpIntegrationProvider`）としてのみ存在する。
- 署名・認証・DRM の回避、n/sig 解読、スクレイピング、ストリーミングURL抽出、Cookie/ログイン情報の利用は禁止。
- 新しい取得元は `MetadataProvider` として追加し、そのサービスの利用規約・許可が確認できた場合に限る。許可未確認のソースから実データを取得しない。
- 取得できない情報は推測で埋めない（nil で表現し、UIでは非表示）。
- メタデータ取得はダウンロード許可を意味しない。許可判定は `DownloadCapability` / `DownloadPermission` で明示的に行う。

## テスト

- 仕様の検証項目に対応する Unit Test を `VYRATests` に置く（URL検証、プロバイダ、集約、権限判定、形式/品質、進捗、キャンセル、完了、ライブラリ追加/削除 等）。
- UI Test は起動・Home表示・タブ切替・URL入力を `VYRAUITests` で担保する。
- テストは外部ネットワークや Secrets なしで全件実行できること。
- テストが成功するまで Phase 完了と報告しない。

## GitHub 運用

- ビルドとテストは GitHub Actions（`.github/workflows/ios-build.yml`）で実行する。main への push と Pull Request で起動。
- ビルドログとテスト結果（.xcresult）は Artifacts に保存する。
- 開発者にMacでの操作を要求しない。
- 作業終了時は必ず `Documentation/HANDOFF/` の引き継ぎを更新する。
