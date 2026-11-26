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

## Developer ID の証明書と公証用の API キーの準備

Developer ID で署名すると、署名の designated requirement（DR）がバンドル ID とチーム ID で決まります。そのため、バージョンを上げても macOS のプライバシーの許可（オートメーション・アクセシビリティ）が引き継がれます。ad-hoc 署名では DR がバイナリのハッシュになるため、ビルドのたびに許可をやり直すことになります。

### Developer ID Application 証明書

Developer ID の証明書を作れるのは、Apple Developer Program のアカウント保持者（Account Holder）だけです。有効期間は 5 年で、1 つのチームで作れる数には上限があるため、作った証明書は秘密鍵ごと保管してください。

Xcode から作る場合:

1. Xcode > Settings… > Accounts で Apple ID を追加します。
2. チームを選んで Manage Certificates… を開き、左下の + から Developer ID Application を選びます。秘密鍵と証明書がログインキーチェーンに入ります。

Web（developer.apple.com）から作る場合:

1. キーチェーンアクセス（`open -a "Keychain Access"`）のメニューで、キーチェーンアクセス > 証明書アシスタント > 認証局に証明書を要求… を選びます。メールアドレスと通称を入力し、CA のメールアドレスは空欄のまま「ディスクに保存」を選ぶと、CSR が保存されます。秘密鍵はこの Mac のログインキーチェーンに作られます。
2. [Certificates](https://developer.apple.com/account/resources/certificates/list) の + から Developer ID Application を選び、Profile Type は G2 Sub-CA を選びます。CSR をアップロードし、ダウンロードした `.cer` を CSR を作った Mac でダブルクリックして取り込みます。

確認:

```bash
security find-identity -v -p codesigning
```

`"Developer ID Application: Your Name (TEAMID)"` が表示されれば完了です。この文字列を `CODESIGN_IDENTITY`（CI ではシークレットの `MACOS_SIGN_IDENTITY`）に設定します。表示されない場合や、証明書が「信頼されていません」になる場合は、[Apple PKI](https://www.apple.com/certificateauthority/) から Developer ID - G2 の中間証明書を取り込んでください。

署名した後は `codesign -d -r- build/Taffy.app` で DR を確認できます。`certificate leaf[subject.OU] = "TEAMID"` が含まれていれば、アップグレード後も許可が引き継がれます。

別の Mac や CI で使う場合は、キーチェーンアクセスの「自分の証明書」で証明書の下に秘密鍵があることを確認し、右クリック > 書き出す… で `.p12`（個人情報交換）形式でパスワードを付けて書き出します。CI のシークレット `MACOS_CERT_P12_BASE64` には、`base64 -i Certificates.p12 | pbcopy` で base64 にしたものを設定します。

作成時に出るエラー:

| エラー | 対処 |
| --- | --- |
| `Unable to process request - PLA Update available` | Program License Agreement が更新されています。[developer.apple.com/account](https://developer.apple.com/account) にサインインし、バナーから契約に同意してください。App Store Connect の「ビジネス」に未同意の契約があれば、そちらにも同意します。 |
| `This operation can only be performed by the Account Holder.` | 選んでいるチームでの役割がアカウント保持者ではありません。Membership details で役割を確認してください。アカウント保持者でも Xcode では Admin と表示されて作れないことがあります。その場合は Xcode のアカウントを削除して追加し直すか、Web から作ってください。 |

### 公証用の API キー

公証（notarization）には App Store Connect の API キーを使います。

1. [App Store Connect > ユーザとアクセス > 統合](https://appstoreconnect.apple.com/access/integrations/api) の Team Keys で + を押し、アクセスに Developer を選んでキーを作ります。
2. `AuthKey_<Key ID>.p8` をダウンロードします。ダウンロードは 1 回しかできません。画面に表示される Key ID と Issuer ID も控えます。CI のシークレット `NOTARY_KEY_BASE64` には `base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy` で base64 にしたものを、`NOTARY_KEY_ID` と `NOTARY_ISSUER_ID` にはそれぞれの ID を設定します。
3. 手元で公証する場合は、notarytool のプロファイルとしてキーチェーンに保存します。

   ```bash
   xcrun notarytool store-credentials taffy-notary \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

4. `TAFFY_NOTARY_PROFILE=taffy-notary` を設定して `make release` を実行すると、署名の後に公証と staple まで行います（「手元でのリリース用 zip の作成」を参照）。

`.p12` と `.p8` は秘密情報です。リポジトリに含めず、パスワードマネージャーなどに保管してください。漏れた場合は、developer.apple.com で証明書を失効させ、App Store Connect で API キーを取り消します。
