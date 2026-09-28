#!/bin/zsh
# README用のデモGIF（docs/images/demo.gif）を撮り直す。ffmpegが必要。
# 一時フォルダの保存先で本物の画面を動かして撮るので、PopNote!本体の設定やメモには触れない。
set -euo pipefail
cd "${0:A:h}/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"; defaults delete recorder >/dev/null 2>&1 || true' EXIT
cp -R web schema "$work/"
xcrun swiftc -o "$work/recorder" Sources/{SQLiteDatabase,Dataset,MemoRules,LocalMemoStore,TickTockTomeLink,MemoRouter,PageSchemeHandler}.swift \
  tests/demo/main.swift -framework Cocoa -framework WebKit -lsqlite3
mkdir -p "$work/base" "$work/frames" docs/images
"$work/recorder" tests/demo/setup.js tests/demo/director.js "$work/base" "$work/frames" 19.5
ffmpeg -loglevel error -y -framerate 10 -i "$work/frames/frame_%04d.png" \
  -vf "scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 docs/images/demo.gif
echo "$PWD/docs/images/demo.gif"
