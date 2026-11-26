# リリースの流れ

[README](../README.ja.md) | [開発者向け情報](development.md)

1. main に PR をマージすると、tagpr（`.github/workflows/tagpr.yaml`）がリリース用の PR を作ります。`Sources/Taffy/Version.swift` のバージョンもこの PR で更新されます（`minor` / `major` ラベルで上げ幅を変えられます）
2. リリース用の PR をマージすると、tagpr が `vX.Y.Z` のタグと GitHub Release を作ります
3. タグの push で `.github/workflows/release.yaml`（macOS の runner）が動きます
   1. `scripts/import-certificate.sh` で Developer ID の証明書と公証用の API キーを一時的なキーチェーンに入れる
   2. `scripts/release.sh` で Developer ID で署名・公証し、公証のチケットを staple した `Taffy-X.Y.Z-macos-universal.zip` を作り、Release に添付する
   3. `scripts/cask.sh` で `packaging/taffy.rb` の version と sha256 を書き換え、tap（[`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask)）の `Casks/taffy.rb` を更新する
4. タグでのリリース時も、zip を作る前に `swift test` を実行します
5. PR と main への push では、`.github/workflows/ci.yaml` が同じ手順で zip を作ります。公証は時間がかかるのでタグのときだけ行い、ここでは Developer ID での署名までにします。シークレットを参照できない PR（fork からの PR など）では ad-hoc 署名でビルドします

## 必要な設定

taffy リポジトリの Settings > Secrets and variables > Actions:

| 種類 | 名前 | 内容 |
| --- | --- | --- |
| 変数 | `TAGPR_APP_ID` | tagpr 用の GitHub App の Client ID |
| シークレット | `TAGPR_APP_PRIVATE_KEY` | 同じ App の秘密鍵 |
| 変数 | `HOMEBREW_APP_ID` | Release の作成と tap の更新に使う GitHub App の Client ID（Contents: Read and write） |
| シークレット | `HOMEBREW_APP_PRIVATE_KEY` | 同じ App の秘密鍵 |
| シークレット | `MACOS_CERT_P12_BASE64` | Developer ID Application の証明書と秘密鍵を書き出した .p12 を base64 にしたもの |
| シークレット | `MACOS_CERT_PASSWORD` | .p12 のパスワード（付けていなければ不要） |
| シークレット | `MACOS_SIGN_IDENTITY` | 署名 ID（例: `Developer ID Application: Your Name (TEAMID)`） |
| シークレット | `NOTARY_KEY_BASE64` | 公証に使う App Store Connect API キー（.p8）を base64 にしたもの |
| シークレット | `NOTARY_KEY_ID` | 同じ API キーの Key ID |
| シークレット | `NOTARY_ISSUER_ID` | 同じ API キーの Issuer ID |

どちらの App も taffy にインストールし、`HOMEBREW_APP_ID` の App は `homebrew-cask` にもインストールしておきます。

## 手元でのリリース用 zip の作成

`make release` を実行し、表示された `scripts/cask.sh <version> <sha256>` で tap に置く cask を出力できます。何も指定しなければ ad-hoc 署名になります。

```sh
# Developer ID で署名する場合
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# 公証もする場合
export TAFFY_NOTARY_PROFILE=taffy-notary   # xcrun notarytool store-credentials で作成
make release
```
