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

## HEIC: ImageIO, with two hard rules

Apple's encoder is the only practical option, and it has hardware support. A naive re-encode has
three failure modes, all observed on real iPhone photos:

| What | Naive (bare bitmap) | Copy from source |
|---|---|---|
| ICC profile (all 8 were Display P3) | kept | kept |
| EXIF orientation (7 of 8 are rotated) | **lost, photo displays sideways** | kept |
| HDR gain map (2 of 8 have one) | **lost** | **lost** |

1. **Always encode by copying from the source image** (`CGImageDestinationAddImageFromSource`),
   never from a decoded bitmap. This alone fixes orientation, at identical file size.
2. **Refuse images with an HDR gain map** in v1, and say why. ImageIO cannot carry the gain map
   across. It is also dangerous because the loss looks like a win: one HDR photo "shrank" to 40%
   of its size, and that saving was the HDR layer being deleted, not compression.

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
