# Changelog

## [Unreleased]

### Breaking Changes
- **`io: Io` parameter**: image filters, resampling transforms, order-statistic filters, `convert`/flips/`insert`, codec `encode`/`loadFromBytes`, `Matrix` products, `Pca`, `ImagePyramid.build` and `Orb.detect` take an `io: Io` after `self` and run in row bands on it; a `process.Init` pool runs them in parallel, `Io.Threaded.global_single_threaded.io()` or `std.Io.failing` runs them serially, output is byte-identical either way. ([#437](https://github.com/arrufat/zignal/pull/437)-[#448](https://github.com/arrufat/zignal/pull/448), [#464](https://github.com/arrufat/zignal/pull/464)-[#468](https://github.com/arrufat/zignal/pull/468))
- **Argument order**: out-param image methods follow `(self, io, allocator, out, ...)`, `diff` takes `(self, other, out, opts)`, ORB helpers take the allocator first. ([#354](https://github.com/arrufat/zignal/pull/354), [#359](https://github.com/arrufat/zignal/pull/359), [#434](https://github.com/arrufat/zignal/pull/434))
- **`DrawOptions`**: canvas primitives take `opts: DrawOptions { mode, blending }` instead of a `DrawMode`; the `.soft`/`.fast` presets reproduce the old output, every primitive can use any of the 12 blend modes, and `setPixel`/`setPoint` gain a `blending` parameter. ([#400](https://github.com/arrufat/zignal/pull/400))
- **`Canvas.drawText(font: Font, size: ?f32)`**: takes the `Font` union and a pixel size instead of a `BitmapFont` and a scale (`null` uses `font.defaultSize()`), and returns `!void`. ([#403](https://github.com/arrufat/zignal/pull/403))
- **`Matrix` chains**: `Matrix(T)` ops return `MatrixError!Matrix(T)`; the deferred-error `.eval()` design moved to `Chain(T)` (`m.chain()`, `toOwned()`), which frees each intermediate. ([#346](https://github.com/arrufat/zignal/pull/346))
- **`Matrix` renames**: `inverse` to `inv`, `determinant` to `det`, `pseudoInverse` to `pinv`, `cholesky` to `chol`, `times` to `hadamard` (`timesBy` to `hadamardBy`), `ProjectiveTransform.inverse` to `inv`; the SVD `with_u` flag became `mode = .no_u`. ([#360](https://github.com/arrufat/zignal/pull/360))
- **`RunningStats(T, config)`**: `.all`/`.variance`/`.summary` selects the tracked quantities; `.all` is the previous behavior.
- **`terminal` namespace**: `sixel`, `kitty` and `iterm2` moved to `terminal.*` and `src/terminal/`. ([#381](https://github.com/arrufat/zignal/pull/381))
- **`Interpolation.nearest_neighbor` renamed to `.nearest`** in Zig, Python and the CLI. ([#358](https://github.com/arrufat/zignal/pull/358))
- **Python draws antialiased by default**: canvas methods default to `DrawMode.SOFT` and an omitted `blending` follows the mode's preset; pass `mode=DrawMode.FAST, blending=Blending.NORMAL` for the old output. ([#424](https://github.com/arrufat/zignal/pull/424))
- **Python `Font` replaces `BitmapFont`**: `Font.load` detects the format and `Canvas.draw_text` takes a pixel `size`. ([#403](https://github.com/arrufat/zignal/pull/403))
- **JPEG encodes write a restart marker per MCU row by default** (`EncodeOptions.restart_interval`, about 0.1 % larger files) so they decode in parallel; `.none` restores the old bytes. ([#466](https://github.com/arrufat/zignal/pull/466))
- **Minimum Zig version is 0.17.0-dev.1970.**

### Features
- **Vector fonts**: `VectorFont` parses TrueType (`.ttf`), CFF OpenType (`.otf`, including CID-keyed fonts, `seac` accents and CFF2 default instances) and collections (`.ttc`/`.otc`, `loadFace`) in place from a borrowed buffer with GPOS/`kern` kerning; every read is bounds-checked and the parser builds for `wasm32-freestanding`. The `Font` union (`bitmap`/`vector`) lets every text API accept either kind. ([#403](https://github.com/arrufat/zignal/pull/403)-[#405](https://github.com/arrufat/zignal/pull/405))
- **Text layout**: `Canvas.drawTextBox` wraps and aligns text in a rectangle under a `TextLayout` (`halign`, `valign`, `wrap`, `line_spacing`, `letter_spacing`), `Font.measureText` measures the block, and `drawTextOutline`/`drawTextBoxOutline` stroke glyph outlines with round joins. ([#406](https://github.com/arrufat/zignal/pull/406), [#407](https://github.com/arrufat/zignal/pull/407))
- **Glyph cache**: opt-in `Font.enableCache` memoizes lookups, outlines and quarter-pixel coverage masks; an 18 px paragraph draws 7.5x faster with TrueType and 17x with CFF. Python enables it automatically. ([#409](https://github.com/arrufat/zignal/pull/409))
- **Glyph rasterization**: `Canvas.fillGlyph` fills outlines with the nonzero rule; `Canvas(u8).rasterizeGlyph`/`rasterizePolygons` accumulate antialiased coverage into an 8-bit mask. ([#403](https://github.com/arrufat/zignal/pull/403))
- **QR codes**: `qrcode.encode`/`decode` with Reed-Solomon correction and a perspective-robust detector that returns the symbol corners; exposed through the `qr` CLI command, Python and a web example. ([#374](https://github.com/arrufat/zignal/pull/374), [#375](https://github.com/arrufat/zignal/pull/375))
- **Global optimization**: `GlobalOptimizer`/`findGlobalOptimum` (MaxLIPO + trust region) for bound-constrained mixed integer/continuous objectives, with parallel evaluation through `Io`. ([#368](https://github.com/arrufat/zignal/pull/368))
- **Flood fill**: `Image.floodFill` with 4/8-connectivity, seed- or neighbor-relative thresholds and Euclidean or Oklab distance; also in Python. ([#369](https://github.com/arrufat/zignal/pull/369))
- **Linear solvers and eigendecomposition**: `Matrix.solve`/`LuResult.solve` (pivoted LU, multiple right-hand sides), `SMatrix.solve`, symmetric `Matrix.eigh` with signed eigenvalues, and a `Matrix.diagonal` constructor. ([#367](https://github.com/arrufat/zignal/pull/367), [#376](https://github.com/arrufat/zignal/pull/376), [#377](https://github.com/arrufat/zignal/pull/377))
- **Matrix sums and in-place ops**: `sumRows`/`sumCols` on `Matrix`, `SMatrix` and `Chain`, in-place `*By` element-wise variants, and Python `+=`/`-=`/`*=`/`/=`. ([#361](https://github.com/arrufat/zignal/pull/361))
- **Recursive Gaussian blur**: `gaussianBlur` takes a `GaussianBlurOptions`; `.iir` runs the Young-van Vliet recursive filter at a cost independent of sigma (sigma 8 at 480x640: 3.0 to 0.74 ms) within a few 8-bit units of the FIR kernel, and `.auto` switches to it above sigma 4. ([#438](https://github.com/arrufat/zignal/pull/438), [#444](https://github.com/arrufat/zignal/pull/444))
- **Nonzero polygon fills**: `Canvas.fillPolygons` fills several contours as one shape under a `FillRule` (`.even_odd`/`.nonzero`).
- **Round joins**: `drawPolygon`, the Bezier curves and `drawSplinePolygon` stroke widths above 1 as one joined path with round joins and caps.
- **BMP codec**: native reader (CORE/INFO/V4/V5 headers, 1 to 32 bpp, bitfields, RLE4/RLE8, both row orders) and writer, wired into `Image.load`/`save`, the CLI and Python. ([#348](https://github.com/arrufat/zignal/pull/348))
- **GIF codec**: native reader (87a/89a, all disposal methods, interlacing, NETSCAPE loops) and writer (median-cut palettes, optional Floyd-Steinberg dithering, animation); `gif.loadAnimated` returns an `AnimatedImage(T)` of composed frames. ([#349](https://github.com/arrufat/zignal/pull/349))
- **Quantization and dithering modules**: `image/quantize.zig` (`medianCut`, `ColorLookupTable`, fixed palettes) and `image/dither.zig` (`floyd_steinberg`, `atkinson`, `ordered`), shared by sixel, braille and GIF.
- **Terminal output**: iTerm2 inline images (`terminal.iterm2`, `--protocol iterm2`, in the `.auto` chain after kitty) and color braille rendering with coalesced SGR escapes. ([#365](https://github.com/arrufat/zignal/pull/365), [#380](https://github.com/arrufat/zignal/pull/380))
- **Inferno colormap** in `Image.applyColormap` and Python `Colormap.inferno()`. ([#378](https://github.com/arrufat/zignal/pull/378))
- **CLI**: a `pipeline` command runs a `.zon` recipe of sequential operations, options accept short aliases (`-o`, `-d`), and batch failures set the exit code. ([#379](https://github.com/arrufat/zignal/pull/379))
- **Python releases the GIL** around every image filter binding. ([#446](https://github.com/arrufat/zignal/pull/446))
- **Examples**: image codec playground, QR encoder/decoder with camera scanning, gray-world white balance, live preview for the global optimizer. ([#384](https://github.com/arrufat/zignal/pull/384))

### Performance
- **JPEG decoding**: baseline frames stream one MCU row at a time through a vectorized render path, a check-free 10-bit Huffman lookup and a 16-bit two-block IDCT, and restart-interval segments decode in parallel: 4K 4:2:0 731 to 22 ms on one core, 4.9 ms on 8 cores, at or below libjpeg-turbo. ([#451](https://github.com/arrufat/zignal/pull/451)-[#456](https://github.com/arrufat/zignal/pull/456), [#465](https://github.com/arrufat/zignal/pull/465))
- **JPEG encoding**: rebuilt around MCU rows and vectors (exact integer DCT, reciprocal quantization, bitmask-driven coding, no wasted ZRL codes) and banded across restart intervals: 4K quality 90 92 to 20 ms serial, 5 ms on 8 cores; files are within a few bytes of libjpeg-turbo. ([#457](https://github.com/arrufat/zignal/pull/457), [#468](https://github.com/arrufat/zignal/pull/468))
- **PNG**: rows are filtered and deflated in parallel 256 KiB chunks (4K RGB 344 to 77 ms on 8 cores, 0.3 % larger files); defiltering uses a branchless Paeth predictor and SIMD rows. ([#383](https://github.com/arrufat/zignal/pull/383), [#469](https://github.com/arrufat/zignal/pull/469))
- **Filters on the pool**: convolution, Gaussian, box, sharpen, Sobel, Canny, motion and the order-statistic blurs run in row bands, 2.6-4.9x on 8 cores, byte-identical to serial. ([#437](https://github.com/arrufat/zignal/pull/437), [#440](https://github.com/arrufat/zignal/pull/440), [#441](https://github.com/arrufat/zignal/pull/441))
- **Convolution kernels**: i32 accumulators, renormalized quantized kernels, a fused separable ring path from 1 MiB, comptime-dense taps, symmetric tap folding and once-per-call border columns; median blur memoizes the two-level fine row (radius 63: 10.1 to 3.0 ms). ([#391](https://github.com/arrufat/zignal/pull/391)-[#395](https://github.com/arrufat/zignal/pull/395), [#429](https://github.com/arrufat/zignal/pull/429))
- **Interleaved struct pixels**: separable convolution, the recursive Gaussian and resize run over `Rgb`/`Rgba` bytes directly instead of split planes, bit-identical and up to 2x faster. ([#460](https://github.com/arrufat/zignal/pull/460), [#461](https://github.com/arrufat/zignal/pull/461), [#463](https://github.com/arrufat/zignal/pull/463))
- **Resize**: u8 and f32 resizers are separable two-pass filters with per-axis tap tables resampling through a per-band ring, views take the same path, and the work bands on the pool: 4K to 1080p bicubic 216 to 37 ms serial, Lanczos 687 to 50 ms, 4-5x more on 8 cores. ([#449](https://github.com/arrufat/zignal/pull/449), [#463](https://github.com/arrufat/zignal/pull/463), [#472](https://github.com/arrufat/zignal/pull/472), [#473](https://github.com/arrufat/zignal/pull/473))
- **Rotate, warp and extract** sample through a per-call `Sampler` with tabulated kernel weights and interior fast paths: 1080p bilinear rotate 88 to 39 ms serial, 4.8-6.7x more on the pool. ([#447](https://github.com/arrufat/zignal/pull/447), [#450](https://github.com/arrufat/zignal/pull/450))
- **`Matrix.gemm`** is a register-tiled blocked kernel that bands its rows on the pool and gathers transposed panels without a copy: 2048^2 f32 26 s to 0.22 s serial, 68 ms on 8 cores. ([#448](https://github.com/arrufat/zignal/pull/448), [#472](https://github.com/arrufat/zignal/pull/472))
- **Canvas**: a signed-area coverage rasterizer with an integer blend path renders text 2-2.5x and thick curves 2-5x faster; thick diagonal lines and ring/arc outlines visit only the band around the stroke (8-13x on long diagonals); rectangle outlines rasterize as an exact axis-aligned ring; polygon fills share one edge sweep; text blocks lay out once. ([#408](https://github.com/arrufat/zignal/pull/408), [#410](https://github.com/arrufat/zignal/pull/410), [#412](https://github.com/arrufat/zignal/pull/412), [#414](https://github.com/arrufat/zignal/pull/414), [#416](https://github.com/arrufat/zignal/pull/416))
- **CFF glyphs** are interpreted once per draw and GPOS pair lookups are indexed at load. ([#420](https://github.com/arrufat/zignal/pull/420))
- **Also**: vectorized color blending, FAST corner detection without `sqrt`, integral-image adaptive thresholding, direct blits for unscaled bitmap glyphs. ([#354](https://github.com/arrufat/zignal/pull/354), [#356](https://github.com/arrufat/zignal/pull/356))

### Improvements
- **Direction-independent polygon antialiasing**: `.soft` fills compute exact coverage in every direction instead of ramping only the span ends. ([#401](https://github.com/arrufat/zignal/pull/401))
- **2-D kernels larger than 7x7** compile (rows loop at runtime above 7), tested up to 31x31. ([#443](https://github.com/arrufat/zignal/pull/443))
- **JPEG robustness**: progressive decoding renders what it has at the scan limit or on truncated data, rejects duplicate SOF markers, validates SOS/SOF fields, honours JFIF/Adobe color models for RGB-coded files, and recognises SOF5-15. ([#382](https://github.com/arrufat/zignal/pull/382), [#431](https://github.com/arrufat/zignal/pull/431))
- **PNG truncation**: files cut mid-chunk, mid-stream or before IEND decode with zero-padded rows and a `truncated` flag. ([#383](https://github.com/arrufat/zignal/pull/383))
- **Input hardening**: canvas, codecs, fonts and the CLI reject or clip NaN, off-image and oversized inputs instead of panicking; `font.max_file_size` is 256 MB. ([#408](https://github.com/arrufat/zignal/pull/408), [#432](https://github.com/arrufat/zignal/pull/432))
- **Terminal detection**: single round-trip sixel probing, `aspectScale` upscales within `max_dim`, `EndOfStream` counts as a timeout. ([#351](https://github.com/arrufat/zignal/pull/351), [#397](https://github.com/arrufat/zignal/pull/397))
- **Single-threaded builds**: the sixel palette cache skips its spinlock under `single_threaded`.

### Fixes
- **Antialiased fills** no longer inherit coverage from a previous fill's untouched accumulator blocks. ([#428](https://github.com/arrufat/zignal/pull/428))
- **`extract`/`insert`** use the half-open rectangle like `crop`; a rotated extract was stretched by cols/(cols-1). ([#435](https://github.com/arrufat/zignal/pull/435))
- **JPEG restart intervals** were unusable because the bit reader ran past RSTn markers. ([#431](https://github.com/arrufat/zignal/pull/431))
- **Numerics**: `RunningStats` skewness/kurtosis scaling, Perlin amplitude normalization, relative pivot tolerances in `lu`/`inv`/`solve`/`det`, `eigh` returns `NotConverged` instead of partial results. ([#430](https://github.com/arrufat/zignal/pull/430))
- **Vector `@intCast` to `u8`** compiled to a saturating pack in release builds; `meta.narrowToBytes` replaces it and CI runs ReleaseSafe. ([#459](https://github.com/arrufat/zignal/pull/459))
- **GIF LZW** code size grows in lockstep in encoder and decoder. ([#350](https://github.com/arrufat/zignal/pull/350))
- **PNG grayscale with alpha** converts to RGBA. ([#352](https://github.com/arrufat/zignal/pull/352))
- **`Image.rotateBounds`** returns a named `RotateBounds` struct; the anonymous return type did not compile.
- **`isAliased`** detects partial buffer overlap between views. ([#356](https://github.com/arrufat/zignal/pull/356))
- **Wide IIR lanes** no longer exceed the comptime branch quota on AVX-512. ([#470](https://github.com/arrufat/zignal/pull/470))

### Tooling
- **Tests run as one binary** rooted at `src/root.zig`; the uncached suite drops from 3 min to 31 s. ([#458](https://github.com/arrufat/zignal/pull/458))
- **Codecs live in `src/codecs/`**, `parallel.zig` moved to `src/`. ([#352](https://github.com/arrufat/zignal/pull/352), [#448](https://github.com/arrufat/zignal/pull/448))
- **CI** publishes to TestPyPI only on releases and manual runs. ([#413](https://github.com/arrufat/zignal/pull/413))

## [0.10.0] - 2026-04-15

### Major Changes
- **Zig 0.16.0 Migration**: Full codebase update to support Zig 0.16.0.
  - Replaced all deprecated `@intFromFloat` calls with `@round`, `@floor`, `@ceil`, or `@trunc`.
  - Leveraged new result type coercion for rounding built-ins to simplify type casting.
  - Updated `std.Io` and `std.Build` API usage to match latest standard library changes.
  - Transitioned to unmanaged containers requiring explicit allocators.
- **Dimension Standardization**: Standardized image and matrix dimensions/indices to `u32` across the library. ([#292](https://github.com/arrufat/zignal/pull/292), [#295](https://github.com/arrufat/zignal/pull/295), [#321](https://github.com/arrufat/zignal/pull/321))

### Features
- **CLI Subcommands**: Added a robust CLI with `blur`, `edges`, `metrics`, `stats`, `resize`, `tile`, `fdm`, `info`, and `version` commands using declarative argument parsing. ([#291](https://github.com/arrufat/zignal/pull/291), [#294](https://github.com/arrufat/zignal/pull/294), [#308](https://github.com/arrufat/zignal/pull/308), [#312](https://github.com/arrufat/zignal/pull/312), [#314](https://github.com/arrufat/zignal/pull/314), [#317](https://github.com/arrufat/zignal/pull/317))
- **Hough Transform**: Implemented Hough transform for line detection with optimized integer arithmetic and 1D lookup tables. ([#326](https://github.com/arrufat/zignal/pull/326))
- **Edge Vectorization**: Added `Tracer` for converting edge maps into vectorized paths.
- **Advanced Interpolation**: Added Mitchell and Lanczos3 resizing methods with LUT optimizations. ([#299](https://github.com/arrufat/zignal/pull/299), [#300](https://github.com/arrufat/zignal/pull/300))
- **Cholesky Decomposition**: Added high-performance Cholesky decomposition for symmetric positive-definite matrices. ([#322](https://github.com/arrufat/zignal/pull/322))
- **Colormap Support**: Added built-in colormaps (Heat, Jet, etc.) for data visualization. ([#336](https://github.com/arrufat/zignal/pull/336))
- **PCF Font Writing**: Added support for writing fonts in PCF format. ([#337](https://github.com/arrufat/zignal/pull/337))
- **Sixel RLE**: Implemented run-length encoding in the Sixel encoder for smaller output sizes. ([#302](https://github.com/arrufat/zignal/pull/302))
- **Image Difference**: Added utility to compute visual and statistical differences between images. ([#309](https://github.com/arrufat/zignal/pull/309))
- **Generic Blending**: Expanded blending modes to support generic float pixel types. ([#335](https://github.com/arrufat/zignal/pull/335))

### Breaking Changes
- **Interpolation API**: Sampling methods now require an explicit `BorderMode`. ([#329](https://github.com/arrufat/zignal/pull/329))
- **Rectangle API**: Updated `Rectangle` methods to take `Point` types instead of individual coordinates. ([#333](https://github.com/arrufat/zignal/pull/333))
- **Random Matrices**: Matrix generation now requires an explicit `seed` for reproducibility.

### Performance
- **SIMD Optimizations**: Vectorized IDCT, color conversion, and convolution inner loops. ([#307](https://github.com/arrufat/zignal/pull/307), [#341](https://github.com/arrufat/zignal/pull/341))
- **Fast CRC**: Implemented slice-by-8 CRC calculation for PNG encoding/decoding. ([#304](https://github.com/arrufat/zignal/pull/304))
- **Memory Optimization**: Removed redundant allocator field from `HuffmanTable`, reducing memory footprint per table instance.

### Improvements
- **Rounding Accuracy**: Improved numerical precision by replacing manual truncation-based rounding with the `@round` built-in.
- **Infallible Operations**: Made `resize` and `letterbox` infallible by handling edge cases internally. ([#334](https://github.com/arrufat/zignal/pull/334))
- **Border Handling**: Improved rotation and interpolation to consistently respect border modes. ([#329](https://github.com/arrufat/zignal/pull/329), [#331](https://github.com/arrufat/zignal/pull/331))

### Fixes
- **PNG Alpha**: Correctly extract alpha channel for grayscale images. ([#330](https://github.com/arrufat/zignal/pull/330))
- **JPEG Robustness**: Improved restart marker handling and MCG decoding stability.
- **Negative Rounding**: Fixed incorrect rounding logic for negative values in fixed-point constants.

## [0.9.0] - 2025-12-15

### Features
- **Convex Hull Bounds**: `ConvexHull.getRectangle()` (and Python's `get_rectangle()`) returns the tightest axis-aligned rectangle for the cached hull, simplifying ROI extraction from arbitrary point clouds. ([#232](https://github.com/arrufat/zignal/pull/232))
- **Resource Limits in Image Loading**: Enforce resource limits during image loading to prevent excessive memory usage. ([#234](https://github.com/arrufat/zignal/pull/234))
- **Scalar Type Conversion for Transforms**: Added scalar type conversion methods to geometry transforms. ([#239](https://github.com/arrufat/zignal/pull/239))
- **Matrix Element Type Conversion**: Added method to convert matrix element types. ([#238](https://github.com/arrufat/zignal/pull/238))
- **Python Sequence Conversion**: Added sequence conversion and improved memory error handling in Python bindings. ([#244](https://github.com/arrufat/zignal/pull/244))

### Breaking Changes
- **Python Grayscale Dtype Rename**: Renamed `Grayscale` dtype to `Gray` in Python bindings. ([#246](https://github.com/arrufat/zignal/pull/246))
- **Color Scalar Handling**: Generalized scalar color handling to all floats, potentially changing behavior for non-f32 scalars. ([#245](https://github.com/arrufat/zignal/pull/245))
- **Python Color Validation**: Added validation for color component range (0-255), now raising errors for invalid values. ([#243](https://github.com/arrufat/zignal/pull/243))
- **Geometry Transform Allocators**: Removed allocator field from transform structs. ([#240](https://github.com/arrufat/zignal/pull/240))

### Fixes
- **Integral Images**: Prevent initialization of empty images in integral image operations.
- **Python Wheels**: Use explicit Zig targets instead of native for better cross-platform compatibility. ([#241](https://github.com/arrufat/zignal/pull/241))
- **PNG IEND Chunk**: Enforce requirement for mandatory IEND chunk in PNG decoding.
- **PNG Critical Chunk Ordering**: Validate critical chunk ordering in PNG files. ([#233](https://github.com/arrufat/zignal/pull/233))

### Tooling & Docs
- Updated Image I/O description in README.
- Updated CI to use Zig master version. ([#236](https://github.com/arrufat/zignal/pull/236))
- Updated macOS runners in CI matrix. ([#231](https://github.com/arrufat/zignal/pull/231))
- Bumped minimum required Zig version.

## [0.8.0] - 2025-11-08

### Breaking Changes
- **Matrix Norm APIs**: Replaced the single `Matrix.norm(kind)` entry point with explicit helpers (`frobenius_norm`, `l1_norm`, `max_norm`, `element_norm`, `schatten_norm`, `induced_norm`, `nuclear_norm`, `spectral_norm`) across the Zig core and Python bindings. Update callers to the specific method that matches the desired metric.
- **Mean Pixel Error Scaling**: `Image.meanPixelError` (and the Python `Image.mean_pixel_error`) now returns a normalized value in `[0, 1]` instead of a percentage. Multiply by 100 if you still need percent output.

### Features
- **Geometry Rectangles**: Added center/corner accessors, translation & clipping helpers, and coverage utilities to `Rectangle`, with parity in the Python bindings. Overlaps now treat threshold checks as inclusive so `1.0` truly means “fully covered”.
- **Matrix Norm Suite**: Introduced element-wise, Schatten, induced, nuclear, and spectral norm implementations backed by the improved SVD helpers, plus error reporting when invalid exponents are supplied.
- **Image Loading**: `Image.loadFromBytes` (and Python’s `load_from_bytes`) can decode PNG/JPEG images directly from any byte buffer or buffer-protocol object without hitting the filesystem, sharing the same validation as file-based loads.
- **Color & Canvas Enhancements**: All color structs gain a generic `invert()` method (exposed to Python) and the canvas line renderer now applies fractional endpoint fading for smoother anti-aliased strokes.
- **Image Metrics**: Added `meanPixelError` for structural comparisons alongside PSNR/SSIM, updated examples that visualize the metric suite, and exposed the API to Python.
- **Examples**: New “Contrast Enhancement” WASM demo showcases autocontrast and histogram equalization controls with cleaner web UI wiring.

### Performance
- **Planar Integral Images**: Box-blur and summed-area table routines now use a unified planar integral representation, reusing the optimized kernels per channel to speed up large RGB/RGBA blurs while simplifying the API surface.

### Fixes
- **Matrix Ops**: Binary operations (`add`, `sub`, `times`, `gemm`) now short-circuit when the second operand already carries an error, preventing misleading results.
- **Transforms**: Similarity, affine, and projective fits explicitly return `error.NotConverged`/`error.RankDeficient` when SVD solvers fail, with Python raising `ValueError` for degenerate point sets instead of silently emitting bad matrices.
- **ORB & Feature Matching**: Brute-force matchers only free successfully allocated slices and ORB scale handling no longer panics on `scale_factor <= 1.0`.
- **Canvas**: Thick transparent lines switch to per-pixel blending so alpha is preserved, and docs clarify how `drawLine` blends colors.
- **Fonts**: PCF format flags use the correct masks and bounds checks, while the BDF parser now handles glyph rows wider than 32 bits by decoding hex data byte-by-byte.

### Tooling & Docs
- Updated Python README structure/quickstart, added a download badge, and refreshed example instructions to reflect the new metrics/contrast demos.

## [0.7.1] - 2025-10-24

### Performance
- **Convolution Pipeline**: Added SIMD-accelerated inner loops and early-outs when all three color channels share identical data, cutting blur runtimes substantially on large uniform regions.
- **Terminal Rendering**: Reworked the sixel encoder with improved palette generation, chunking heuristics, and profiling hooks to lower output size and CPU time for high-resolution frames.

### Fixes
- **Matrix GEMM**: Correctly handles `Aᵀ * Bᵀ` paths when dispatching to SIMD kernels, eliminating shape-related crashes in advanced linear algebra workflows.
- **PNG Decoder**: Fixed 16-bit pixel extraction offsets to stop channel swapping in high bit-depth images.
- **JPEG Decoder**: Hardened restart-marker handling and memory management to avoid buffer overruns on truncated streams.
- **Feature Distribution Matching**: Ensures color-source matching respects grayscale targets, yielding stable feature histograms.
- **Rectangle Geometry**: Tightened overlap/containment logic for greater numerical stability in downstream layout calculations.
- **Canvas Drawing**: Floors floating-point coordinates before pixel writes, preventing occasional off-by-one artefacts.

### Internal & Tooling
- **Image Metrics Module**: Consolidated PSNR/SSIM helpers into `image/metrics.zig`, simplifying reuse from examples and keeping `image.zig` lean.
- **Examples**: Added an image-quality metrics showcase and refreshed web demos to highlight the new encoder improvements.

## [0.7.0] - 2025-10-08

### Major Features

#### Image Quality Metrics
- **Structural Similarity Index (SSIM)**: Added `Image.ssim` to compute perceptual similarity using the standard 11×11 Gaussian window and Rec. 709 luminance weighting, with support for grayscale and RGB/RGBA data.

#### Linear Algebra & Geometry
- **Moore–Penrose Pseudoinverse**: Added `Matrix.pseudoInverse` with tolerance controls and rank reporting, enabling stable solutions for rectangular systems.
- **Improved Affine Fitting**: `AffineTransform.init` now uses the pseudoinverse to support overdetermined point sets while preserving numerical stability.

### Breaking Changes
- **Image Processing Outputs**: All image filters and morphology routines now expect the caller to supply an initialized output image (`Image.initLike`/`dupe`). `Image.crop` and `Image.rotate` return freshly allocated images instead of writing through an output pointer.
- **Geometry Point API**: Replace `Point.point(...)` with the new `Point.init(...)` constructor; the legacy helper has been removed.
- **Meta Utilities**: `meta.clampU8`/`clampTo` have been consolidated into the generic `meta.clamp(T, value)` helper and must be updated accordingly.

### Architecture & API Improvements
- **Unified Border Handling**: Introduced `image/border.zig` to centralize zero, replicate, mirror, and wrap modes used across convolution and order-statistic filters.
- **Running Statistics**: `RunningStats` gains an explicit `.init()` constructor, clearer reset semantics, and broader edge-case coverage in tests.
- **Matrix Errors**: Added `MatrixError.NotConverged` so SVD-backed routines report convergence failures instead of silently returning invalid data.

### Performance Optimizations
- **PCA**: SIMD-accelerated `project`/`reconstruct` paths for f32 and f64 reduce latency on high-dimensional datasets.

### Bug Fixes
- **Compression**: Deflate encoder/decoder now clear internal state when reused, preventing cross-run contamination.
- **Canvas**: Row indexing honors image stride, fixing drawing artifacts on non-contiguous buffers.
- **Geometry**: `Rectangle.contains` rejects NaN inputs and `Rectangle.overlaps` correctly enforces the configured IoU threshold.
- **Edge Detection**: Corrected source/destination ordering during gradient copying, fixing regression in the edges module.

### Tooling & Documentation
- **Python Toolchain**: Minimum supported Python bumped to 3.10 with full CI coverage through Python 3.14.
- **Docs**: Expanded Python README with badges, feature overview, and clarified version matrix.

## [0.6.0] - 2025-09-30

### Major Features

#### Image Processing
- **Binary Image Operations**: Complete thresholding and morphology suite
  - Otsu and adaptive mean thresholding
  - Morphological operations: erosion, dilation, opening, closing
- **Order-Statistic Filters**: Median, minimum, maximum blur filters
  - Edge-preserving noise reduction with configurable kernel sizes
- **Image Enhancement**: Histogram equalization and autocontrast
  - Adaptive contrast enhancement for improved visibility
- **Edge Detection**: Advanced edge detection algorithms
  - **Canny Edge Detection**: Classic multi-stage edge detector with Gaussian smoothing, Sobel gradients, non-maximum suppression, and hysteresis thresholding
  - **Shen-Castan**: Edge detection with ISEF smoothing and adaptive gradient computation
- **Canvas Drawing**: Added `drawImage` method for image compositing
  - Support for blending modes during insertion

#### Format Support
- **JPEG Encoder**: Complete baseline JPEG encoding implementation
  - DCT-based compression with quality control
  - Support for grayscale and RGB images
  - Optimized encoding performance

#### Compression
- **Deflate/Zlib/Gzip**: Full compression implementation
  - Multiple compression levels and strategies
  - Dynamic Huffman encoding
  - LZ77 hash-based compression
  - Compatible with standard zlib format

#### Matrix Improvements
- **Chainable Operations API**: Simplified matrix operations
  - Direct method chaining: `matrix.transpose().inverse().eval()`
  - Deferred error checking at terminal operations
  - Added `dupe()` method for explicit copying

### Breaking Changes
- **Image Processing**: Removed `differenceOfGaussians`, easy to do manually
- **Matrix API**: Removed `OpsBuilder`, merged functionality into `Matrix`
  - Use `ArenaAllocator` for managing intermediate allocations in chains
  - All SIMD optimizations preserved
- **YCbCr Color Space**: Components now use `u8` type instead of other numeric types
- **Alpha Compositing**: Corrected blend mode compositing behavior

### Architecture Improvements
- **Image Module Reorganization**: Separated into focused sub-modules
  - `image/binary.zig` - Binary operations and morphology
  - `image/convolution.zig` - Convolution framework
  - `image/edges.zig` - Edge detection algorithms
  - `image/enhancement.zig` - Histogram and contrast operations
  - `image/histogram.zig` - Histogram computation
  - `image/integral.zig` - Integral image operations
  - `image/motion_blur.zig` - Motion blur effects
  - `image/order_statistic_blur.zig` - Order-statistic filters
- **Compression Modules**: Modular compression implementation
  - Separate modules for deflate, zlib, gzip, huffman, and LZ77
- **ORB Feature Detection**: Improved with learned BRIEF patterns

### Python Bindings
- Standardized argument parsing with `py_utils.kw()` helper
- Numeric validators for consistent error messages
- Unified enum registration system via `enum_utils.zig`
- Consolidated type registration with compile-time tables
- Reduced boilerplate with `moveImageToPython` helper

### Performance Optimizations
- SIMD-optimized f32 separable convolution
- Vectorized DoG and Gaussian blur calculations
- Optimized JPEG encoding with fast DCT
- Improved PNG compression configuration

### Bug Fixes
- Fixed alpha compositing for blend modes
- Corrected JPEG restart marker handling and partial MCU decoding
- Improved PNG filter selection alignment with spec
- Fixed DoG filter output with offset handling
- Better memory management for convolution operations

## [0.5.1] - 2025-09-03

No changes, just fixed a bug in Python

## [0.5.0] - 2025-09-02

### Major Features

#### Computer Vision & Feature Detection
- **ORB Feature Detection**: Complete ORB (Oriented FAST and Rotated BRIEF) implementation
  - FAST corner detection with non-maximal suppression
  - Binary descriptor extraction with rotation invariance
  - Feature matching with Hamming distance
  - KeyPoint structure with orientation and scale support
- **Hungarian Algorithm**: Optimal assignment problem solver for feature matching
- **Image Pyramid**: Multi-scale image representation for feature detection

#### Advanced Image Filtering
- **Convolution Framework**: Generic convolution with customizable kernels
  - Gaussian blur with configurable sigma
  - Difference of Gaussians (DoG) for edge detection
  - Sobel edge detection with gradient magnitude
- **Motion Blur Effects**: Linear and radial motion blur with SIMD optimization

#### Image Processing Enhancements
- **Advanced Blending**: 12 blend modes (normal, multiply, screen, overlay, soft light, etc.)
- **Image Transforms**: Extraction, insertion, warping, and perspective transforms with interpolation
- **Channel Operations**: Generic operations on individual color channels
- **PSNR Calculation**: Peak Signal-to-Noise Ratio for quality assessment
- **Border Handling**: Set borders, extract rectangles, and handle edge modes

### Architecture Improvements
- **Refactored Image Module**: Separated into logical sub-modules
  - Core image operations in `image.zig`
  - Filtering operations in `image/filtering.zig`
  - Transform operations in `image/transforms.zig`
  - Channel operations in `image/channel_ops.zig`
- **Dynamic SVD**: Separated static and dynamic SVD implementations
- **Enhanced PCA**: Runtime dimension support with batch operations
- **Font System Overhaul**: Dynamic Unicode support with full 8x8 character set

### Performance Optimizations
- SIMD-optimized motion blur and convolution operations
- Channel-separated processing for improved cache locality
- Optimized integral image computation
- Fast paths for axis-aligned image extraction
- Vectorized filtering with boundary handling

### API Changes
- **Breaking**: Renamed enums for consistency
  - `InterpolationMethod` → `Interpolation`
  - `BlendMode` → `Blending`
  - ANSI display modes renamed to SGR
- **Breaking**: Rectangle bounds are now exclusive (was inclusive)
- **Breaking**: Image constructors renamed for clarity
  - `initBlank` → `init`
  - `initFromSlice` → `fromSlice`
- **Breaking**: `isView` renamed to `isContiguous`
- Blur methods renamed: `boxBlur` → `blurBox`, added `blurGaussian`

### JPEG Enhancements
- Support for 4:4:4, 4:2:2, and 4:1:1 chroma subsampling
- Improved component detection and color space handling

### Bug Fixes
- Fixed filter operations on non-contiguous image views
- Corrected integral image boundary access
- Fixed Sobel gradient magnitude scaling
- Improved arc antialiasing in canvas drawing

## [0.4.1] - 2025-08-06

### Fixed
- **Canvas.fillRectangle** now properly uses alpha blending in .soft mode
- **drawLine** has some fixes in the drawLineXiaolinWu algorithm

### Added
- **examples** add an example to showcase more drawing stuff

## [0.4.0] - 2025-08-06

### Added

#### Terminal Graphics
- **Image Scaling Support**: Terminal graphics protocols now support image scaling
  - Sixel: Added optional `width` and `height` fields to `sixel.Options` for image scaling
  - Kitty: Added optional `width` and `height` fields to `kitty.Options` for image scaling
  - Allows images to be scaled (preserving aspect-ratio) before transmission to terminal

### Changed
- **Terminal Architecture**: Refactored terminal state management
  - Encapsulated state management in new `terminal.zig` module
  - Replaced `TerminalSupport.zig` with more modular design
- **Sixel Processing**: Refactored image processing pipeline
  - Color lookup table now implemented as value type
  - Optimized image preparation for dithering
  - Better separation of concerns in processing stages

### Performance
- Optimized Sixel color quantization and dithering preparation
- More efficient color lookup table implementation

## [0.3.0] - 2025-08-04

### Added

#### Font Support
- **PCF Font Loading**: Complete PCF (Portable Compiled Font) format support
  - All PCF table types including metrics, bitmaps, encodings
  - Compressed PCF support with automatic decompression
  - Efficient glyph lookup and rendering
- **BDF Font Support**: Comprehensive BDF (Bitmap Distribution Format) implementation
  - Loading and parsing of BDF font files
  - Saving fonts back to BDF format
  - Support for gzipped BDF files (.bdf.gz)
  - Unicode properties and glyph metadata preservation
- **Built-in Font**: Default 8x8 bitmap font for immediate text rendering
- **Text Rendering**: Canvas text drawing with bitmap fonts with optional antialiasing

#### Geometry Enhancements
- **Unified Point System**: New tuple literal syntax for point construction
  - Simplified API: `Point(2, f32)` instead of `Point2d(f32)`
  - Consistent interface across all dimensions

#### Canvas Improvements
- **Bounds Management**: Improved clipping and bounds checking
  - Better handling of drawing operations near image edges
  - Guards against empty fill regions
  - Optimized rectangle clamping to image bounds

#### Image Features
- **Image Scaling**: New scaling method for flexible image resizing
- **PixelIterator**: For sequential pixel traversal

#### Linear Algebra
- **Matrix Decomposition**: Enhanced decomposition methods
  - Improved numerical stability
  - Comprehensive test coverage
  - Better error handling

### Changed
- Point types now use unified syntax across the library
- Canvas drawing methods have improved parameter validation
- Font module reorganized for better modularity

## [0.2.0] - 2025-07-25

### Added

#### Image Processing
- **Image Interpolation**: Comprehensive interpolation methods for high-quality image resizing
  - Nearest neighbor, bilinear, bicubic algorithms
  - Catmull-Rom, Lanczos, and Mitchell filters
  - SIMD-optimized kernels for RGBA operations (2-5x performance improvement)
- **Display Formats**: Multiple terminal graphics protocols
  - ANSI full/half-block display for wide terminal compatibility
  - Sixel graphics protocol with adaptive palette generation
  - Kitty graphics protocol for native terminal rendering
  - Braille pattern display for monochrome graphics

#### Architecture
- **Module Refactoring**: Split monolithic `image.zig` into organized sub-modules
  - `image/image.zig` - Core image functionality
  - `image/interpolation.zig` - Interpolation algorithms
  - `image/display.zig` - Display format implementations
  - `image/format.zig` - Format detection and handling
  - Comprehensive test modules for each component

#### PNG Enhancements
- Color management with proper color space encoding support
- Optimized adaptive filter selection for better compression
- Fixed filter mode for specialized use cases
- Performance improvements in encoding pipeline

### Changed
- Image saving now uses object methods: `image.save(path)` instead of static functions
- Matrix GEMM parameters reordered for clarity
- Exposed `InterpolationMethod` type for public API use
- PNG comments updated to Zig doc comment style

### Fixed
- Sixel adaptive palette generation for better color accuracy
- Seam carving edge cases with memmove optimization

### Performance
- SIMD kernels for 4xu8 (RGBA) interpolation operations
- Optimized PNG filter selection with adaptive sampling
- Reduced allocations in feature distribution matching
- Memory-efficient seam carving implementation

## [0.1.0] - 2025-07-21

### Core Features

### Image Processing
- **Native Image Type**: Generic `Image(T)` supporting any pixel type (u8, RGB, RGBA, etc.)
- **Memory-Efficient Views**: Sub-images that share memory with parent images (zero-copy)
- **Image I/O**: Native codecs with no external dependencies
  - **PNG**: Full codec with comprehensive format support
    - All PNG color types: RGB, RGBA, Grayscale, Palette
    - 8-bit and 16-bit depths, interlaced images
    - Transparency and gamma correction support
  - **JPEG**: Decoder for most common variants
    - Baseline and progressive JPEG support
    - YCbCr and grayscale color spaces
    - High-quality decoding with proper color space handling
- **Image Transformations**: Resize, crop, rotate, flip operations
- **Pixel-Level Operations**: Direct pixel manipulation with type safety

### Color Science (12 Color Spaces)
Comprehensive color space ecosystem with seamless conversions:

- **sRGB Family**: `Rgb`, `Rgba` (packed struct for WASM efficiency)
- **Perceptual**: `Hsl`, `Hsv` for intuitive color manipulation
- **Lab Family**: `Lab`, `Lch` for perceptually uniform editing
- **Modern**: `Oklab`, `Oklch` for improved perceptual uniformity
- **Device**: `Xyz`, `Lms` for color science applications
- **Specialized**: `Xyb`, `Ycbcr` for advanced workflows

**Key Benefits**:
- Runtime compatibility checks for RGB operations
- Automatic conversion between any color spaces
- Consistent API across all color types
- Optimized packed structs for WASM interoperability

### Geometry & Transforms
- **Primitives**: `Point`, `Rectangle` with comprehensive operations
- **Transform System**: Projective, Affine, and Similarity transforms using homogeneous coordinates
- **Convex Hull**: Efficient convex hull computation for point sets

### Drawing & Canvas API
Advanced 2D rendering with antialiasing:
- **Primitives**: Lines, circles, polygons with smooth rendering
- **Curves**: Quadratic and cubic Bézier curve support
- **Filled Shapes**: Polygon filling with antialiasing
- **Coordinate Transforms**: Full transform pipeline support

### Linear Algebra
Comprehensive matrix operations:
- **Generic Matrix**: `Matrix(T)` for any numeric type
- **SVD Decomposition**: High-precision Singular Value Decomposition (ported from dlib)
- **GEMM Operations**: Optimized matrix multiplication
- **Chainable Matrix Operations**: Fluent API directly on Matrix type for complex operations
- **Static Matrices**: `SMatrix` for compile-time sized matrices

### Principal Component Analysis
- **PCA Implementation**: Full PCA with eigenvalue decomposition
- **Dimensionality Reduction**: Project data to lower dimensions
- **Visualization**: Built-in support for 2D/3D projections
- **Example Applications**: Face alignment, data visualization

### Image Processing
- **Feature distribution matching** for domain adaption

### Procedural Generation
- **Perlin Noise**: High-quality noise generation for textures and terrain
- **Configurable**: Adjustable frequency, amplitude, and octaves
- **2D/3D Support**: Generate noise in multiple dimensions
