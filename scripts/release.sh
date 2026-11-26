#!/bin/bash
# 配布用の zip を dist/ に作る（ユニバーサルバイナリ）。
# usage: scripts/release.sh <version>
#
# 環境変数:
#   CODESIGN_IDENTITY     署名に使う ID。既定 "-"（ad-hoc 署名）
#                         例: "Developer ID Application: Your Name (TEAMID)"
#   TAFFY_NOTARY_PROFILE  公証に使う、`xcrun notarytool store-credentials` で保存したプロファイル名。
#                         Developer ID で署名し、これを設定した場合だけ公証し、Taffy.app に staple する
#   TAFFY_NOTARY_KEYCHAIN 上のプロファイルを既定以外のキーチェーンに保存した場合、そのキーチェーンのパス
#
# GitHub Actions の中では、zip のパスと SHA-256 を $GITHUB_OUTPUT（zip / sha256）に書く。
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${TAFFY_NOTARY_PROFILE:-}"
NOTARIZE=false
if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "ad-hoc 署名では公証できません（TAFFY_NOTARY_PROFILE を外すか、Developer ID で署名してください）" >&2
    exit 1
  fi
  NOTARIZE=true
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  [[ -n "${TAFFY_NOTARY_KEYCHAIN:-}" ]] && NOTARY_ARGS+=(--keychain "$TAFFY_NOTARY_KEYCHAIN")
fi

# 公証に出して結果を待つ。Accepted 以外ならログを出して失敗にする
notarize() {
  local result status
  result="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json)"
  status="$(jq -r .status <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    echo "公証に失敗しました（$1: $status）" >&2
    xcrun notarytool log "$(jq -r .id <<<"$result")" "${NOTARY_ARGS[@]}" >&2 || true
    exit 1
  fi
  echo "公証済み: $1"
}

cd "$(dirname "$0")/.."
SOURCE_VERSION="$(sed -n 's/.*current = "\(.*\)"/\1/p' Sources/Taffy/Version.swift)"
if [[ "$SOURCE_VERSION" != "$VERSION" ]]; then
  echo "バージョンが一致しません: 指定 $VERSION / Version.swift $SOURCE_VERSION" >&2
  exit 1
fi

UNIVERSAL=1 CODESIGN_IDENTITY="$IDENTITY" scripts/build-app.sh
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Taffy.app/Contents/Info.plist)" = "$VERSION"

rm -rf dist
mkdir -p dist
ZIP="dist/Taffy-${VERSION}-macos-universal.zip"
ditto -c -k --keepParent build/Taffy.app "$ZIP"

if $NOTARIZE; then
  notarize "$ZIP"
  # 公証のチケットを staple し、オフラインでも Gatekeeper が確認できるようにしてから zip を作り直す
  xcrun stapler staple build/Taffy.app
  spctl --assess --type execute --verbose build/Taffy.app
  rm -f "$ZIP"
  ditto -c -k --keepParent build/Taffy.app "$ZIP"
fi

SHA256="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "zip=$ZIP"; echo "sha256=$SHA256"; } >> "$GITHUB_OUTPUT"
fi
echo "完成: $ZIP"
echo "SHA-256: $SHA256"
echo "cask: scripts/cask.sh $VERSION $SHA256"
