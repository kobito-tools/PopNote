#!/bin/zsh
# TomeletのDB更新（migrations/*.sql）を schema/ へ写す。
# PopNote!は新しい保存先のDBをこの内容で作るため、Tomeletと同じ形式になる。
# 使い方: scripts/sync-schema.sh <Tomeletのフォルダ>
set -euo pipefail
cd "${0:A:h}/.."
source_dir="${1:?Tomeletのフォルダを指定してください}/migrations"
[[ -d "$source_dir" ]] || { echo "migrationsが見つかりません: $source_dir" >&2; exit 1; }
rm -f schema/*.sql
cp "$source_dir"/[0-9]*_*.sql schema/
ls schema
