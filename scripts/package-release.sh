#!/bin/zsh
# GitHubのReleasesへ添付するzipを作る。dist/PopNote_<版>_universal.zip（GitHub は名前の「!」を使えないため付けない）
set -euo pipefail
cd "${0:A:h}/.."
./build.sh >/dev/null
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build.sh)
mkdir -p dist
archive="dist/PopNote_${version}_universal.zip"
rm -f "$archive"
# Finderの「圧縮」と同じ形式（拡張属性・署名を保ったまま）で固める。
ditto -c -k --keepParent "PopNote!.app" "$archive"
echo "$PWD/$archive"
