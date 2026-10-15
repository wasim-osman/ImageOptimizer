#!/bin/bash
#
# Builds the three encoders ImageOptimizer ships — cjpegli, oxipng, pngquant — into one folder,
# each a self-contained arm64 binary that links only system libraries and runs on macOS 14+.
#
# Why build instead of bundling Homebrew's: Homebrew builds against the newest macOS, so its
# binaries and dylibs refuse to launch on older systems (pngquant's lcms2 needs macOS 27, libpng 26).
# Building from pinned sources with MACOSX_DEPLOYMENT_TARGET=14.0 and static libraries avoids that.
# Every result is then verified: system libraries only, and a minimum OS no newer than we claim.
#
# usage: scripts/build-tools.sh [output-dir]      (default: .tools/bin)

set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="14.0"
OXIPNG_TAG="v10.2.1"
PNGQUANT_TAG="3.0.3"
GIFSICLE_VERSION="1.97"
GIFSICLE_SHA256="17d98f305372e8c6c47c3fa7c75a9ebd9a8dea0b47c739d0b3be6c30a1c1da7a"

mkdir -p "${1:-.tools/bin}"
OUT="$(cd "${1:-.tools/bin}" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export PATH="$HOME/.cargo/bin:$PATH"

command -v cargo >/dev/null || { echo "needs Rust (https://rustup.rs)"; exit 1; }
command -v cmake >/dev/null && command -v ninja >/dev/null || { echo "needs cmake and ninja (brew install cmake ninja)"; exit 1; }

echo "==> cjpegli"
./scripts/build-jpegli.sh "$OUT"

echo "==> oxipng $OXIPNG_TAG"
git clone --quiet --depth 1 --branch "$OXIPNG_TAG" https://github.com/shssoichiro/oxipng.git "$WORK/oxipng"
(cd "$WORK/oxipng" && cargo build --release --locked 2>&1 | tail -1)
cp "$WORK/oxipng/target/release/oxipng" "$OUT/oxipng"
cp "$WORK/oxipng/LICENSE" "$OUT/LICENSE.oxipng"

echo "==> pngquant $PNGQUANT_TAG (static libpng + lcms2: the colour management is not optional)"
git clone --quiet --depth 1 --branch "$PNGQUANT_TAG" --recursive https://github.com/kornelski/pngquant.git "$WORK/pngquant"
# --features static compiles libpng and lcms2 in. Without lcms2, pngquant would drop a wide-gamut
# image's colour profile WITHOUT converting the pixels, visibly shifting every colour.
(cd "$WORK/pngquant" && cargo build --release --features static 2>&1 | tail -1)
cp "$WORK/pngquant/target/release/pngquant" "$OUT/pngquant"
cp "$WORK/pngquant/COPYRIGHT" "$OUT/LICENSE.pngquant"

echo "==> gifsicle $GIFSICLE_VERSION"
curl -fsSL -o "$WORK/gifsicle.tar.gz" "https://www.lcdf.org/gifsicle/gifsicle-$GIFSICLE_VERSION.tar.gz"
[ "$(shasum -a 256 "$WORK/gifsicle.tar.gz" | cut -d' ' -f1)" = "$GIFSICLE_SHA256" ] || { echo "gifsicle checksum mismatch"; exit 1; }
mkdir "$WORK/gifsicle" && tar -xf "$WORK/gifsicle.tar.gz" -C "$WORK/gifsicle" --strip-components=1
# Plain C, no external libraries. The viewer and diff tools are not built.
(cd "$WORK/gifsicle" \
  && CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS" LDFLAGS="-mmacosx-version-min=$MIN_MACOS" \
     ./configure --disable-gifview --disable-gifdiff >/dev/null \
  && make -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1)
cp "$WORK/gifsicle/src/gifsicle" "$OUT/gifsicle"

echo "==> Verifying every binary"
status=0
for tool in cjpegli oxipng pngquant gifsicle; do
  bin="$OUT/$tool"
  [ -x "$bin" ] || { echo "  FAIL $tool was not produced"; status=1; continue; }
  bad="$(otool -L "$bin" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/)' || true)"
  minos="$(otool -l "$bin" | grep -A4 LC_BUILD_VERSION | awk '/minos/{print $2}')"
  if [ -n "$bad" ]; then echo "  FAIL $tool links a non-system library:"; echo "$bad"; status=1
  elif [ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -1)" != "$MIN_MACOS" ]; then
    echo "  FAIL $tool needs macOS $minos, newer than the $MIN_MACOS we claim"; status=1
  else echo "  ok   $tool  (system libraries only, minos $minos, $(du -h "$bin" | cut -f1 | tr -d ' '))"; fi
done
exit $status
