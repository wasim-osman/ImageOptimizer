#!/bin/bash
#
# Builds ImageOptimizer.app and wraps it in a DMG.
#
# The app is ad-hoc signed only: without a paid Developer ID it cannot be notarised, so macOS will
# quarantine it on any machine that didn't build it (see README "Installation").
#
# usage: ./package.sh [version]

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP_NAME="ImageOptimizer"
MIN_MACOS="14.0"
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"
DIST="dist"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Encoder tools"
./scripts/build-tools.sh .tools/bin >/dev/null
for t in cjpegli oxipng pngquant; do [ -x ".tools/bin/$t" ] || { echo "missing $t"; exit 1; }; done

echo "==> Building release binary"
swift build -c release --product ImageOptimizerApp 2>&1 | tail -1

echo "==> Running tests"
swift test > "$STAGE/test.log" 2>&1 || { tail -30 "$STAGE/test.log"; echo "TESTS FAILED"; exit 1; }
grep -oE "Test run with .*" "$STAGE/test.log" | sed 's/^/    /'

echo "==> Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/licenses"
cp .build/release/ImageOptimizerApp "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for t in cjpegli oxipng pngquant; do cp ".tools/bin/$t" "$APP/Contents/Resources/bin/$t"; done
cp licenses/* "$APP/Contents/Resources/licenses/"
cp THIRD_PARTY_LICENSES.md LICENSE "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>         <string>com.imageoptimizer.app</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>LSMinimumSystemVersion</key>     <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.photography</string>
    <key>NSHumanReadableCopyright</key>   <string>© 2026 Md Wasim Osman. MIT licence. Bundled encoders carry their own licences (see THIRD_PARTY_LICENSES.md).</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>   <string>Images</string>
            <key>CFBundleTypeRole</key>   <string>Viewer</string>
            <!-- Alternate: appear in "Open With" without taking over Preview as the default. -->
            <key>LSHandlerRank</key>      <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
                <string>public.png</string>
                <string>public.heic</string>
                <string>public.heif</string>
                <string>public.camera-raw-image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Verifying the bundle (every binary: system libraries only, and no newer than macOS $MIN_MACOS)"
fail=0
while IFS= read -r -d '' f; do
  file "$f" | grep -q "Mach-O" || continue
  name="${f#$APP/}"
  bad="$(otool -L "$f" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/|@rpath/libswift)' || true)"
  minos="$(otool -l "$f" | grep -A4 LC_BUILD_VERSION | awk '/minos/{print $2}')"
  if [ -n "$bad" ]; then echo "  FAIL $name loads a non-system library:"; echo "$bad" | sed 's/^/        /'; fail=1
  elif [ -n "$minos" ] && [ "$(printf '%s\n%s\n' "$minos" "$MIN_MACOS" | sort -V | tail -1)" != "$MIN_MACOS" ]; then
    echo "  FAIL $name needs macOS $minos but the app claims $MIN_MACOS"; fail=1
  else echo "  ok   $name  (minos ${minos:-n/a})"; fi
done < <(find "$APP" -type f -print0)
[ "$fail" = 0 ] || { echo "BUNDLE VERIFICATION FAILED"; exit 1; }

echo "==> Signing (ad-hoc)"
for t in cjpegli oxipng pngquant; do codesign --force --sign - "$APP/Contents/Resources/bin/$t"; done
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Building DMG"
mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
ln -s /Applications "$STAGE/Applications"
rm -f "$STAGE/test.log"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
[ -f "$DMG" ] || { echo "DMG was not created"; exit 1; }
echo
echo "Done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
