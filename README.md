# ImageOptimizer

A native macOS drag-and-drop image optimiser for Apple Silicon, and the sister app to
[VideoOptimizer](https://github.com/wasim-osman/VideoOptimizer).

Drop an image on the window and it is re-encoded to the smallest file that still looks the same as the
original, in the **same format**, saved next to the source as `name_optimized.jpg`. Like VideoOptimizer, it
refuses to make a file worse, and tells you why when it refuses.

## What you get

Measured on 30 real JPEGs, 24 real PNGs and 8 real iPhone HEICs, scored for how different the result
*looks* from the original (ssimulacra2; 85 is "high quality"):

| Format | Mode | Output size (median) | Looks |
|---|---|---|---|
| JPEG | Balanced | **51%** of the original | score 85.6 |
| JPEG | Smallest | **26%** | score 77.1 |
| PNG | Balanced | **35%** | score 88.6 |
| PNG | High quality | 82%, **pixel-for-pixel identical** | exact |
| HEIC | Balanced | 90% | score 83.9 |

A JPEG takes about a quarter of a second. Full tables, methods and caveats are in
[docs/ENGINE-FINDINGS.md](docs/ENGINE-FINDINGS.md).

**HEIC gains are modest, by nature.** iPhone HEICs are already well compressed by Apple's hardware
encoder, so re-encoding at the same quality saves about 10%. High quality mode correctly finds nothing
worth keeping for them. JPEG and PNG are where this app earns its keep.

## What it does to your images

- **Looks the same.** Quality is chosen per format from measured data, not guessed, and checked in the test
  suite by scoring outputs against their originals.
- **Orientation stays correct.** Photos stored sideways with an EXIF rotation tag come out upright. (A naive
  re-encode turned 7 of 8 real iPhone photos sideways.)
- **Colour stays correct.** Wide-gamut (Display P3) profiles are kept, and lossy PNG converts colours rather
  than dropping the profile, which would visibly shift every colour.
- **Privacy by default.** Location (GPS), capture time and camera model are removed. Only what's needed to
  display the image correctly (orientation and colour profile) is kept.
- **Never makes a file worse.** A source that's already efficient is refused, and a result that isn't
  meaningfully smaller is discarded and never written. Drop the same refused file again and it asks
  **"Optimise anyway?"**.
- **Asks before removing an HDR layer.** Most iPhone photos carry one. Re-encoding keeps how the photo
  looks in standard brightness but drops the extra HDR brightness, so the app asks first ("Optimise Without
  HDR") rather than doing it silently.
- **Refuses what it can't do safely**, and says why: animated images, CMYK, **portrait photos with depth
  data** (a re-encode would delete the depth map), and formats other than JPEG, PNG and HEIC (GIF, TIFF,
  WebP, AVIF, RAW). Forcing never overrides these.

## Modes

| Mode | JPEG | PNG | HEIC |
|---|---|---|---|
| **High quality** | very high quality | lossless (identical pixels) | very high quality |
| **Balanced** (default) | looks the same | lossy palette reduction | looks the same |
| **Smallest** | squeezes hardest | same as Balanced, slowest search | squeezes hardest |

"Reduce PNG colours" in Settings turns lossy PNG off entirely.

## Using it

Drop images (or a folder) on the window, or double-click the window to browse. Drop more while it works and
they queue; the status line names what's waiting. The stop button in the top-left, **File ▸ Stop** (⌘.) or
Esc cancels. The gear in the top-right opens Settings. When idle, the window shows how much space the app has
saved you in total, across every launch.

Quitting while images are being processed asks first, then stops the encoders cleanly.

## Installation

Requires **macOS 14 or later** on Apple Silicon. Download the DMG from [Releases](../../releases) and drag
ImageOptimizer to Applications. Nothing else to install: the encoders are bundled.

The app is **not signed with a Developer ID** (that needs a paid Apple account), so macOS blocks it on first
launch. Right-click it and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/ImageOptimizer.app
```

### Building from source

```sh
git clone https://github.com/wasim-osman/ImageOptimizer.git
cd ImageOptimizer
brew install cmake ninja   # and Rust: https://rustup.rs
make package               # builds the encoders, runs the tests, writes dist/ImageOptimizer-<version>.dmg
```

`make tools` builds just the encoders into `.tools/bin`; `make test` runs the suite against them.

## How it works

```
Sources/
  ImageOptimizerCore/   Probe (ImageIO), Planning (pure), Encoding (runner, queue), Models
  ImageOptimizerApp/    the AppKit window, Settings, menu
  ImageOptimizerCLI/    drives the whole core headlessly: ImageOptimizerCLI --plan photo.jpg
Tests/                  114 tests, against real files and the real encoders
scripts/                build-tools.sh, build-jpegli.sh, generate-app-icon.swift
```

`EncodePlanner` turns an `ImageInfo` plus `Settings` into a list of steps as a pure function, which is why the
quality rules are cheap to test. The encoders are separate programs run as separate processes:

| Format | Engine |
|---|---|
| JPEG | **jpegli**, ~13% smaller than Apple's encoder at equal quality |
| PNG | **pngquant** (lossy palette reduction) then **oxipng** (lossless recompression). Apple's own PNG writer makes the median PNG 32% *bigger*. |
| HEIC | Apple's encoder, in-process |

The encoders are built from pinned sources by `scripts/build-tools.sh` rather than taken from Homebrew,
because Homebrew's binaries need the newest macOS and refuse to start on older ones. The script verifies that
every binary links only system libraries and is no newer than macOS 14, and `package.sh` re-checks every
binary in the finished app.

## Testing

```sh
make test
```

The suite uses real image files, written by ImageIO with the awkward properties that break naive optimisers
(all 8 EXIF orientations, Display P3, 16-bit alpha, greyscale, CMYK, animated GIF, a truncated file), and the
real encoders, with no stubs. It checks that an optimised photo displays upright, keeps its colours, loses its
GPS, that lossless PNG is verified pixel-exact, that cancelling a running job really kills the encoder, and,
using ssimulacra2, that outputs still look like their originals. The thresholds come from the real-photo
validation, not from whatever the synthetic fixtures happen to score.

`ssimulacra2` ships with libjxl and is a development-only dependency (`brew install jpeg-xl`); tests that need
it are skipped when it's absent. Contributors: this project is developed on a Mac with Apple's Command Line
Tools but no full Xcode, where **XCTest does not exist**. The suite uses swift-testing and `Package.swift`
passes an explicit `-plugin-path` so its macros resolve; that flag is harmless with full Xcode.

## Known limitations

- **Not signed or notarised.** Gatekeeper warns on first launch.
- **HEIC savings are small** (see above), and HDR photos need your confirmation and portrait photos are refused.
- **JPEG, PNG and HEIC only.** Everything else is refused with a message.
- Lossy PNG can show banding on smooth gradients in rare cases; use High quality mode to stay lossless.
- The interactive dialogs (Optimise anyway, quit confirmation), the double-click picker and the Settings
  window are AppKit code with no automated UI test. They were verified by build, launch and, where possible,
  observation of the running app, but not by scripted clicking.

## Licence

MIT: see [LICENSE](LICENSE).

The release DMG bundles three encoders (pngquant, jpegli's cjpegli, oxipng) that carry their own licences,
including **GPL-3.0-or-later** for pngquant. They run as separate programs and are not covered by the MIT
licence. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for versions, sources and what the GPL means
here.
