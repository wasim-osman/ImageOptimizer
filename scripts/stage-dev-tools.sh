#!/bin/bash
#
# Puts cjpegli, oxipng and pngquant in .tools/bin so `swift test` and the CLI can find them.
#
# DEV ONLY. oxipng and pngquant are copied from Homebrew, whose pngquant depends on libraries
# built for a newer macOS than we support — fine for testing on this machine, NOT what ships.
# Release builds use scripts/build-tools.sh, which builds everything for macOS 14.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=".tools/bin"
mkdir -p "$OUT"
[ -x "$OUT/cjpegli" ] || ./scripts/build-jpegli.sh "$OUT"
for tool in oxipng pngquant; do
  src="$(command -v "$tool" || true)"
  [ -n "$src" ] || { echo "missing $tool — brew install $tool"; exit 1; }
  cp "$src" "$OUT/$tool"
done
echo "staged in $OUT:"; ls -1 "$OUT"
