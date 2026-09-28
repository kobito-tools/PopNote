#!/bin/zsh
# GitHubのReleasesへ添付するzipを作る。dist/PopNote!_<版>_universal.zip
set -euo pipefail
cd "${0:A:h}/.."
./build.sh >/dev/null
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build.sh)
mkdir -p dist
archive="dist/PopNote!_${version}_universal.zip"
rm -f "$archive"
# Finderの「圧縮」と同じ形式（拡張属性・署名を保ったまま）で固める。
ditto -c -k --keepParent "PopNote!.app" "$archive"
echo "$PWD/$archive"
