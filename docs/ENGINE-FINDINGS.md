# Engine findings (milestone 1)

Everything in this file was **measured on real images from the maintainer's own machine**,
not taken from vendor claims. The images themselves are not in this repository; only sizes
and quality scores were recorded.

**Method.** Quality is measured with `ssimulacra2` (a perceptual metric: ~70 is "good",
~85 "high quality", ~90 "very high"; the same scale as the JPEG XL project uses). To compare
encoders that use different quality knobs, each was swept across several settings and the file
size was **interpolated at a fixed ssimulacra2 target**. That makes "X is N% smaller" mean
"smaller at the same perceived quality", rather than "smaller at a setting with the same name".
The reference for every comparison is the decoded original, so the score measures only the
damage a re-encode adds.

Samples: 30 JPEGs (camera and phone, 0.3–15 MB), 24 PNGs (screenshots and graphics),
8 iPhone HEICs. Fixed random seed; reproducible from the corpus.

## JPEG: use jpegli

Median output size, as a percentage of the **original** file, at equal perceived quality:

| Encoder | ssim2 80 | ssim2 85 | ssim2 90 |
|---|---|---|---|
| **jpegli** | **32.6%** | **46.6%** | 70.7% |
| mozjpeg | 35.5% | 52.2% | 72.2% |
| Apple ImageIO | 39.9% | 55.2% | 79.0% |
| libjpeg-turbo | 41.7% | 60.4% | 74.3% |

Head-to-head at ssim2 85: jpegli is **8% smaller than mozjpeg, 13% smaller than ImageIO,
19% smaller than libjpeg-turbo**. (An earlier version of the plan said "20–35% better than
Apple's"; that was optimistic. 13% is the measured figure.)

At the high-quality target the app will use, a typical camera JPEG ends up at about **47% of its
original size**.

**Homebrew does not ship jpegli.** The `jpeg-xl` formula has no `cjpegli`: jpegli moved out of
libjxl into <https://github.com/google/jpegli>, which has no release tags. We build it from a
pinned commit with `scripts/build-jpegli.sh`.

## PNG: Apple's writer is unusable; bundle oxipng and pngquant

| Variant | Median % of original | Whole set | Verified |
|---|---|---|---|
| Apple ImageIO rewrite | **132.5%** | 92.1% | pixel-exact 24/24 |
| oxipng `-o 4`, lossless | 82.0% | 61.4% | pixel-exact 24/24 |
| oxipng `-o max`, lossless | 81.0% | 61.3% | pixel-exact 24/24 (up to 11.8 s per image) |
| **pngquant 80–98 + oxipng** | **35.6%** | **26.5%** | ssim2 median 88.6, min 73.3 |
| pngquant 60–85 + oxipng | 52.3% | 31.7% | ssim2 median 67.6, **min 50.8** |

- Rewriting a PNG through ImageIO makes the median file **32% larger**. Without oxipng the app
  would regularly make files worse.
- `-o max` buys 1% over `-o 4` for a large time cost. Use level 4.
- The lossy default is **pngquant 80–98**: about 64% smaller with a median perceptual score of
  88.6. The aggressive 60–85 range dropped as low as 50.8, which is visibly damaged; not a default.
- "Lossless" claims are verified by hashing decoded pixels, not assumed.

## HEIC: ImageIO, with hard rules

Apple's encoder is the only practical option, and it has hardware support. A naive re-encode has
three failure modes, all observed on real iPhone photos:

| What | Naive (bare bitmap) | Copy from source |
|---|---|---|
| ICC profile (all 8 were Display P3) | kept | kept |
| EXIF orientation (7 of 8 are rotated) | **lost, photo displays sideways** | kept |
| HDR gain map (2 of 8 have one) | **lost** | **lost** |

1. **Re-encode the decoded bitmap and pass the orientation explicitly.** (Superseded: the first
   draft copied from the source with `CGImageDestinationAddImageFromSource`, which keeps
   orientation but also keeps EXIF capture time and camera model; ImageIO can only exclude the
   GPS. Re-encoding the bitmap with `kCGImagePropertyOrientation` set strips GPS, capture time
   and camera model, and keeps orientation and the Display P3 profile. Verified.)
2. **Refuse images with an HDR gain map** in v1, and say why. ImageIO cannot carry the gain map
   across. It is also dangerous because the loss looks like a win: one HDR photo "shrank" to 40%
   of its size, and that saving was the HDR layer being deleted, not compression.

3. **Refuse portrait photos (depth maps) for the same reason**: the bitmap route deletes the depth
   data Photos uses for portrait editing.

None of the 30 sampled JPEGs carried a gain map, so this is a HEIC problem in practice.

## Platform floor: a trap that applies to bundling

Homebrew builds against the newest macOS, so its binaries refuse to launch on older systems
(`minos` is the oldest OS a binary will run on):

| Binary | minos | Verdict |
|---|---|---|
| cjpegli (our build) | 14.0 | links system libraries only: nothing to bundle |
| oxipng (Homebrew) | 11.0 | no non-system dependencies: safe to bundle as-is |
| pngquant (Homebrew) | 11.0 | **but its libraries are not**: `lcms2` needs 27, `libpng` needs 26 |
| ssimulacra2 | 27.0 | test-only oracle, never shipped |

So **pngquant must be built from source** against macOS 14 with libpng and lcms2 compiled in,
rather than bundled from Homebrew. This is a packaging-milestone task. ImageOptimizer's
documented minimum macOS must follow what is actually bundled, and be verified rather than
asserted.

## Versions measured

jpegli `031a007`, oxipng 10.2.1, pngquant 3.0.3, mozjpeg 4.1.5, libjpeg-turbo 3.2.0,
ssimulacra2 from jpeg-xl 0.12.0, macOS 27, Apple Silicon.

## The finished product, validated on real images (milestone 4)

The real `ImageOptimizerCLI` (the whole pipeline, not the individual encoders) was run over the same
sample in every mode, working on copies, and each result scored against its source with ssimulacra2
on viewer-equivalent renders (upright, colour-managed).

| Format | Mode | Output size, median % of original | ssimulacra2 min / median |
|---|---|---|---|
| JPEG | High quality | 69% | 86.0 / 88.3 |
| JPEG | Balanced | **51%** | 80.9 / 85.6 |
| JPEG | Smallest | **26%** | 68.3 / 77.1 |
| PNG | High quality (lossless) | 82% | 100 (pixel-exact) |
| PNG | Balanced | **35.5%** | 73.3 / 88.6 |
| PNG | Smallest | 35.3% | 73.3 / 88.6 |
| HEIC | High quality | every file discarded as no smaller | |
| HEIC | Balanced | 89.5% | 80.8 / 83.9 |
| HEIC | Smallest | 62.7% | 72.1 / 76.4 |

Speed: a JPEG takes about 0.24 s, a HEIC about 0.23 s, and a PNG about 1 s (worst case 2.8 s).

What the validation changed:

- **PNG "smallest" was worse than "balanced".** The first ladder used pngquant 70-95; measured on 24
  real PNGs it was 0.7% smaller at the median but had a worse tail and visibly lower quality
  (min 71.6, median 82 vs 88.6). pngquant has effectively one useful lossy operating point: speed and
  oxipng level move the median by under 0.5%. Smallest now uses the same range with the slowest search.
- **HEIC savings are modest by nature.** iPhone HEICs are already well compressed by Apple's hardware
  encoder, so a re-encode at equal perceived quality saves about 10%. High quality mode correctly
  finds nothing worth keeping. The README says so rather than overselling.
- A harness bug worth recording: run from a directory without `.tools/bin`, all 160 JPEG and PNG
  jobs failed with the clear message "The cjpegli encoder is missing from this install".

## Camera RAW to JPEG (v1.1.0)

**Development uses Apple's `CIRAWFilter`**, the engine behind Preview and Photos: no extra decoder to bundle,
it handles iPhone ProRAW and Canon CR2 (and the other makers macOS supports), and the result matches what the
Mac shows. Measured on a real ProRAW DNG and CR2: developed in 0.3-0.7 s. Two traps:

- `CIRAWFilter` applies the camera's rotation itself (a CR2 stored 5472x3648 with orientation 8 comes out
  3648x5472), so the pixels must not be rotated again. A test compares the JPEG's dimensions to the
  orientation-adjusted native size.
- ImageIO's dimensions for a RAW can describe an embedded preview, so the probe asks the RAW engine for the true size.

**The ladder had to be re-measured.** A RAW render keeps all its detail and noise, so the JPEG ladder's
distance of 1.0 scored only 82.8 (the same distance scores 85.6 on JPEG sources). Sweep on 12 RAWs, scored
against the lossless render (ssimulacra2, size as % of the RAW):

| jpegli | Size | Score median (min) |
|---|---|---|
| d 0.3 | 11.8% | 88.0 (84.6) |
| d 0.4 | 9.6% | 87.0 (84.1) |
| d 0.5 | 8.1% | 86.3 (83.7) |
| **d 0.7** | **6.2%** | **85.2 (82.7)** |
| d 1.0 | 4.5% | 83.3 (81.0) |
| d 1.7 + 4:2:0 | 2.5% | 77.9 (74.5) |

Chosen to match the JPEG modes' quality levels (88 / 85 / 77): High quality d 0.3, Balanced d 0.7,
Smallest d 1.7 with 4:2:0. Full run of the shipped ladder over all 33 RAWs (99 conversions, none failed):

| Mode | DNG size / score (min) | CR2 size / score (min) |
|---|---|---|
| High quality | 12.1% / 86.0 (81.3) | 11.8% / 88.3 (84.6) |
| Balanced | 6.6% / 84.4 (80.3) | 5.7% / 85.3 (82.7) |
| Smallest | 2.9% / 78.2 (75.1) | 2.3% / 76.8 (71.0) |

Speed: a CR2 takes about 1 s, an iPhone ProRAW DNG 2-8 s (heavier development and, in this run, three runs at once).

**Not found:** a way to generate a RAW for the test suite. ImageIO cannot write one, and a hand-built linear DNG
(valid per exiftool and tiffutil) is not accepted by Apple's reader. The end-to-end RAW tests use a RAW found on the
machine and skip when there is none.
