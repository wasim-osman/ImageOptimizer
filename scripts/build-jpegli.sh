#!/bin/bash
#
# Builds cjpegli — Google's jpegli JPEG encoder — as a self-contained arm64 binary.
#
# Why this exists: Homebrew's `jpeg-xl` formula does NOT ship cjpegli (jpegli was split
# out of libjxl into its own repository), so there is nothing to `brew install`.
#
# The flags are not cosmetic. cjpegli's image-reader helpers pull in the system GIF, PNG,
# libjpeg and OpenEXR libraries at configure time, and Homebrew's copies of those are built
# for a far newer macOS than we support (OpenEXR needs 27, libpng 26). Hiding them gives a
# binary that links only /usr/lib/libc++ and libSystem, targets macOS 14.0, and needs nothing
# bundled alongside it. The trade-off is that it reads PPM/PFM only — the app pipes pixels to it.
#
# usage: scripts/build-jpegli.sh <output-dir>      (writes cjpegli + djpegli there)

set -euo pipefail

# jpegli has no release tags; pin the exact commit that was benchmarked and verified.
JPEGLI_COMMIT="031a0077f5799a6041004267fc12b956c1f52a20"
OUT="${1:?usage: build-jpegli.sh <output-dir>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v cmake >/dev/null && command -v ninja >/dev/null || { echo "needs cmake and ninja (brew install cmake ninja)"; exit 1; }

echo "==> Cloning google/jpegli @ ${JPEGLI_COMMIT:0:7}"
git clone --quiet https://github.com/google/jpegli.git "$WORK/jpegli"
git -C "$WORK/jpegli" checkout --quiet "$JPEGLI_COMMIT"
git -C "$WORK/jpegli" submodule update --init --recursive --depth 1 --quiet

echo "==> Configuring (static, macOS 14.0, optional codec libraries hidden)"
mkdir "$WORK/build" && cd "$WORK/build"
# An empty pkg-config search path makes OpenEXR 'not found'; the prefix flags hide Homebrew.
PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH=/nonexistent \
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
  -DJPEGXL_ENABLE_TOOLS=ON -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
  -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
  -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGLI_ENABLE_OPENEXR=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON -DCMAKE_DISABLE_FIND_PACKAGE_OpenEXR=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON \
  -DCMAKE_PREFIX_PATH=/nonexistent -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  "$WORK/jpegli" > configure.log

echo "==> Building"
ninja -j "$(sysctl -n hw.ncpu)" tools/cjpegli tools/djpegli > build.log

mkdir -p "$OUT"
cp tools/cjpegli tools/djpegli "$OUT/"
cp "$WORK/jpegli/LICENSE" "$OUT/LICENSE.jpegli"

echo "==> Verifying the result is genuinely self-contained"
BAD="$(otool -L "$OUT/cjpegli" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/)' || true)"
[ -z "$BAD" ] || { echo "UNEXPECTED non-system dependency:"; echo "$BAD"; exit 1; }
MINOS="$(otool -l "$OUT/cjpegli" | grep -A4 LC_BUILD_VERSION | awk '/minos/{print $2}')"
echo "    links system libraries only; minos $MINOS"
echo "Done: $OUT/cjpegli ($(du -h "$OUT/cjpegli" | cut -f1))"
