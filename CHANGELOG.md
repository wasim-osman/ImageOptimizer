# Changelog

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.3.0] — 2026-10-16

### Added
- **Choose which metadata to remove.** Settings > Metadata has a tick box per group: location, date and time,
  camera and lens, exposure settings, author/copyright/software, titles/descriptions/keywords, and everything else,
  with "Remove all", "Location only" and "Keep all" buttons. The rest of the source's metadata is now kept
  instead of always being dropped. Works for JPEG, HEIC, PNG and the JPEG made from a RAW.
- CLI: `--remove-metadata all|none|location,date,camera,exposure,author,description,other`.

### Changed
- **Default:** only the location is removed (it used to be everything). Settings saved by an earlier version get
  the same default, so an upgrade never starts leaking the location. To get the old behaviour, tick "Remove all".
- Settings files from older versions with missing keys now load instead of being reset.

### Safety
- The picture is untouched by the metadata step (identical pixels, same rotation and colour profile). If a removed
  group can't be verified as gone, the file is written with no metadata at all.

## [1.2.3] — 2026-10-16

### Changed
- **A big GIF now uses every core.** gifsicle is single-threaded, so one large GIF ran on one core. In Balanced
  and Smallest, a GIF of 8 MB or more with enough frames is split into chunks (up to one per core), each
  optimised by its own gifsicle, then joined. Each chunk after the first starts from a keyframe (the fully
  composited frame, rendered by ImageIO) because a GIF can't be cut at an ordinary frame. Your 88 MB, 446-frame
  recording: Smallest 44 s -> 16 s, Balanced 68 s -> 22 s, about 2.6% larger (the keyframes). All 446 frames,
  every delay and the loop count are unchanged, and every frame matches the single-run result to within 0.8/255.
- A chunk only starts on a frame that doesn't clear the picture behind it (a GIF "disposal" setting); if no
  such frame exists the GIF is run whole. High quality is lossless and is never chunked.

## [1.2.2] — 2026-10-16

### Changed
- **Uses every CPU core.** The number of images converted at once was fixed at 4 (max 8), and each encoder is
  single-threaded per file, so a 12-core Mac sat mostly idle. It is now Automatic (one per core) by default, and
  Settings > Advanced can still set a fixed number up to the core count. A saved setting of 4 (the old default)
  moves to Automatic. Measured on 14 RAW files: 6.1 s with 1 at a time, 3.0 s with 4, 1.6 s with 12.
- A single file still uses one core, because gifsicle, cjpegli and pngquant can't split one image.

## [1.2.1] — 2026-10-16

### Changed
- **Balanced and Smallest scale big GIFs down** to fit 1280 px and 960 px on the longer side (never up, and
  never in High quality). Reported on an 88 MB, 1912 px, 446-frame screen recording, where lossy compression
  saved 0.2% and a palette cut cost too much quality: it now comes out at 47 MB (Balanced) and 28.5 MB
  (Smallest), with every frame, the timing and the loop count unchanged.

## [1.2.0] — 2026-10-15

### Added
- **GIF support**, animated or still. Repacked with gifsicle: only what changes between frames is stored,
  and the palette is searched for a smaller encoding. Every frame, every delay and the loop count are kept
  (checked in tests, and across 20 real GIFs). High quality is lossless (frames identical); Balanced and
  Smallest add light and stronger lossy compression, and fall back to the lossless result when lossy can't
  beat the 92% bar, instead of discarding a real saving.
- ImageOptimizer now appears in Finder's "Open With" for GIFs.

### Honest numbers
- Most GIFs on a typical machine are already tightly packed. Over 20 real GIFs: 16 shrank at all; the set fell
  to 93% of its bytes lossless, 91% Balanced, 89% Smallest. Screen recordings and photo loops gain the most.
  An 88 MB GIF takes about 75 s.

## [1.1.0] — 2026-10-07

### Added
- **Camera RAW support.** Drop a RAW (DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2 and others macOS opens) and it
  is developed into the most efficient JPEG, saved as `name_optimized.jpg` beside the original. Developed
  with Apple's own RAW engine, so the result matches Preview and Photos; rotation applied once, Display P3
  colour kept, camera and location details left out. Measured on 19 iPhone ProRAW and 14 Canon CR2 files: High
  quality 12% of the RAW's size, Balanced 6%, Smallest 2.5%, at the same perceptual quality levels as the JPEG modes.
- ImageOptimizer now appears in Finder's "Open With" for RAW files.

### Changed
- "Move the original to the Trash" never applies to a RAW file: it is the negative.

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
