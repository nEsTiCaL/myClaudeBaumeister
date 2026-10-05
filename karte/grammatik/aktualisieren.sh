#!/usr/bin/env bash
# GDScript-Grammatik auf einen neuen upstream-Stand bringen (siehe gdscript/HERKUNFT.md).
#   bash grammatik/aktualisieren.sh [commit]    # ohne commit: neuester Stand
set -euo pipefail
HIER=$(cd "$(dirname "$0")" && pwd)
URL=https://github.com/PrestonKnopp/tree-sitter-gdscript
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

git clone -q "$URL" "$tmp/g"
[[ -n ${1:-} ]] && git -C "$tmp/g" checkout -q "$1"
stand=$(git -C "$tmp/g" log -1 --format='%H (%cs)')

ziel=$HIER/gdscript
rm -rf "$ziel/src"; mkdir -p "$ziel/src"
cp -r "$tmp/g/src/parser.c" "$tmp/g/src/scanner.c" "$tmp/g/src/tree_sitter" "$ziel/src/"
cp "$tmp/g/LICENSE" "$ziel/LICENSE"
sed -i "s|^Stand:  .*|Stand:  $stand|" "$ziel/HERKUNFT.md"
echo "gdscript: $stand"
(cd "$HIER/.." && go test ./...)
