# VYRA — DEVELOPMENT_RULES

## コーディング

- MVVM を守る。View にビジネスロジックを書かない。UI から直接API通信しない。
- Swift Concurrency を優先する。状態は ViewModel に集約する。
- 認証情報をコード・ログに含めない。不要な外部ライブラリを追加しない。
- Phase 境界を守る。モックである箇所はUI文言でも「モック」「推定」と明示する。

## テスト

- 仕様の検証項目に対応する Unit Test を `VYRATests` に置く（URL検証、モック取得、形式/品質、進捗、キャンセル、完了、ライブラリ追加/削除 等）。
- UI Test は起動・Home表示・タブ切替・URL入力を `VYRAUITests` で担保する。
- テストが成功するまで Phase 完了と報告しない。

## GitHub 運用

- ビルドとテストは GitHub Actions（`.github/workflows/ios-build.yml`）で実行する。main への push と Pull Request で起動。
- ビルドログとテスト結果（.xcresult）は Artifacts に保存する。
- 開発者にMacでの操作を要求しない。
- 作業終了時は必ず `Documentation/HANDOFF/` の引き継ぎを更新する。
