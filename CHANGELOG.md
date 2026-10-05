# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.0.1] — 2026-10-05

### Fixed
- Dropping an iPhone photo did nothing visible. Most iPhone photos carry an HDR layer, and the app
  refused them with only a small line of text. It now asks straight away, with an "Optimise Without
  HDR" button. Tried on a real iPhone photo: 4.2 MB to 2.0 MB, ssim2 85.3, Display P3 and dimensions kept.

### Changed
- HDR photos are no longer a hard refusal. Animated, CMYK, portrait-depth and oversized images still are.

## [1.0.0] — 2026-10-05

First release.

### Added
- Drag-and-drop optimiser for JPEG, PNG and HEIC, keeping each image's format.
- Three modes (High quality, Balanced, Smallest) with quality levels chosen from measurements on real
  images and checked in tests with a perceptual metric.
- jpegli for JPEG, pngquant plus oxipng for PNG, Apple's encoder for HEIC.
- Correct orientation and colour profiles; GPS, capture time and camera model removed.
- Pre- and post-flight guards against making a file worse, an "Optimise anyway?" prompt, and a refusal (with
  the reason) for images that can't be optimised safely: animated, CMYK, HDR and portrait photos, and other
  formats.
- Queue with visible queued names, Stop (button, ⌘., Esc), clean quit-time cancellation, double-click to
  browse, and a lifetime savings counter.
- Encoders built from pinned sources for macOS 14, verified to link only system libraries.
