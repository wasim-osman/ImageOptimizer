# Third-party licences

ImageOptimizer's own source (`Sources/`, `Tests/`, `scripts/`) is **MIT**: see [LICENSE](LICENSE).

**The release DMG also bundles three command-line encoders**, built from source by
[`scripts/build-tools.sh`](scripts/build-tools.sh). They are separate programs that the app runs as
separate processes; they are not linked into the Swift code, and they are not covered by the MIT licence.
Each licence's full text is in [`licenses/`](licenses/) and is copied into the app at
`ImageOptimizer.app/Contents/Resources/licenses/`.

## Bundled programs

| Program | Version | Licence | Source |
|---|---|---|---|
| **pngquant** (lossy PNG palette reduction) | 3.0.3 | **GPL-3.0-or-later** | <https://github.com/kornelski/pngquant/tree/3.0.3> |
| **cjpegli** (JPEG encoder, from jpegli) | commit `031a007` | BSD-3-Clause | <https://github.com/google/jpegli/tree/031a0077f5799a6041004267fc12b956c1f52a20> |
| **oxipng** (lossless PNG recompression) | 10.2.1 | MIT | <https://github.com/shssoichiro/oxipng/tree/v10.2.1> |

Statically compiled into those binaries:

| Library | Inside | Licence |
|---|---|---|
| libimagequant | pngquant | GPL-3.0-or-later |
| libpng | pngquant | libpng licence |
| zlib | pngquant | zlib licence |
| Little CMS 2 (lcms2) | pngquant | MIT |
| Highway | cjpegli | Apache-2.0 or BSD-3-Clause |
| Little CMS 2 (lcms2) | cjpegli | MIT |
| 63 Rust crates | oxipng | MIT, Apache-2.0, Zlib, Unlicense (all permissive) |
| 32 Rust crates | pngquant | MIT, Apache-2.0, Zlib, Libpng, CC0, and GPL-3.0-or-later (libimagequant) |

The exact crate names, versions and licences are generated from each project's lockfile in
[`licenses/OXIPNG-DEPENDENCIES.txt`](licenses/OXIPNG-DEPENDENCIES.txt) and
[`licenses/PNGQUANT-DEPENDENCIES.txt`](licenses/PNGQUANT-DEPENDENCIES.txt).

## What the GPL means here

pngquant and libimagequant are GPL-3.0-or-later, so distributing the DMG means distributing GPL
binaries. This project meets that by:

- shipping the full GPL-3.0 text ([`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt)) and pngquant's own
  notice ([`licenses/PNGQUANT-COPYRIGHT.txt`](licenses/PNGQUANT-COPYRIGHT.txt)) inside the app;
- bundling **unmodified** upstream pngquant, built from the pinned tag above with no patches;
- publishing the build script that reproduces the binary exactly, and linking the exact source tag, so the
  corresponding source is one `git clone --branch 3.0.3` away.

If you need the source supplied another way, open an issue and it will be provided.

## Why the encoders are built, not downloaded

Homebrew builds against the newest macOS, so its binaries (and the libraries they load) refuse to start on
older systems. Measured while building this project: Homebrew's pngquant loads an `lcms2` that needs
macOS 27 and a `libpng` that needs macOS 26. The build script compiles pinned sources with
`MACOSX_DEPLOYMENT_TARGET=14.0` and static libraries, and **verifies every result**: system libraries
only, and no newer a minimum OS than the app claims.

## Not shipped

`ssimulacra2` (from libjxl, BSD-3-Clause) is used only by the test suite to check that optimised images
still look like their originals. It is a development dependency and is not in the app.
