#!/bin/bash
# GitHub Actions の中で、Developer ID Application の証明書と公証用の App Store Connect API キーを
# 一時的なキーチェーンに入れる（.github/workflows/ci.yaml と release.yaml から使う）。
#
# 環境変数:
#   P12               証明書と秘密鍵を書き出した .p12 の base64。空なら何もしない（シークレットを参照できない PR など）
#   P12_PASSWORD      .p12 のパスワード（付けていなければ空でよい）
#   NOTARY_KEY        App Store Connect API キー（.p8）の base64
#   NOTARY_KEY_ID     API キーの Key ID
#   NOTARY_ISSUER_ID  API キーの Issuer ID
#   TAFFY_NOTARIZE    "1" なら、後のステップの scripts/release.sh で公証するように
#                     TAFFY_NOTARY_PROFILE と TAFFY_NOTARY_KEYCHAIN を $GITHUB_ENV に書く
set -euo pipefail

if [[ -z "${P12:-}" ]]; then
  echo "::notice::MACOS_CERT_P12_BASE64 を参照できないため、証明書の取り込みを省略します"
  exit 0
fi
: "${RUNNER_TEMP:?GitHub Actions の中で実行してください}"
: "${GITHUB_ENV:?GitHub Actions の中で実行してください}"

kc="${RUNNER_TEMP}/build.keychain-db"
kcpw="$(uuidgen)"
security create-keychain -p "${kcpw}" "${kc}"
security set-keychain-settings -lut 21600 "${kc}"
security unlock-keychain -p "${kcpw}" "${kc}"

p12="${RUNNER_TEMP}/cert.p12"
p8="${RUNNER_TEMP}/notary.p8"
trap 'rm -f "${p12}" "${p8}"' EXIT

echo "${P12}" | base64 -d > "${p12}"
security import "${p12}" -k "${kc}" -P "${P12_PASSWORD:-}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${kcpw}" "${kc}" > /dev/null

# 既存のキーチェーンを残したまま、作ったキーチェーンを検索リストの先頭に加える
keychains=()
while IFS= read -r k; do keychains+=("${k}"); done < <(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
security list-keychains -d user -s "${kc}" "${keychains[@]}"

# PR でも store-credentials までは行い、API キーが使えることを確かめる
echo "${NOTARY_KEY:?NOTARY_KEY_BASE64 を設定してください}" | base64 -d > "${p8}"
xcrun notarytool store-credentials taffy-notary \
  --key "${p8}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}" --keychain "${kc}"

if [[ "${TAFFY_NOTARIZE:-}" == "1" ]]; then
  {
    echo "TAFFY_NOTARY_PROFILE=taffy-notary"
    echo "TAFFY_NOTARY_KEYCHAIN=${kc}"
  } >> "${GITHUB_ENV}"
fi
