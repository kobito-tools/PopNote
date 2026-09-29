#!/bin/zsh
# GitHubのReleasesへ添付するdmgを作る。dist/PopNote_<版>_universal.dmg（GitHub は名前の「!」を使えないため付けない）
set -euo pipefail
cd "${0:A:h}/.."
./build.sh >/dev/null
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build.sh)
mkdir -p dist
archive="dist/PopNote_${version}_universal.dmg"
rm -f "$archive"
# 開くと PopNote!.app と Applications フォルダが並び、ドラッグでインストールできる形にする。
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "PopNote!.app" "$stage/PopNote!.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "PopNote!" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$archive" >/dev/null
echo "$PWD/$archive"
