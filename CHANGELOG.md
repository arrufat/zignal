# Changelog

## [Unreleased]

### Features
- **TrueType Fonts**: New `VectorFont` type parsing `.ttf` files in place from a borrowed buffer (`loadFromBytes`, no allocation) or from disk (`load`): table directory, `head`/`maxp`/`hhea`/`hmtx`/`post`/`OS/2` metrics, `cmap` formats 4 and 12, `loca`/`glyf` simple and composite glyphs, and kerning from GPOS pair adjustment (formats 1/2, extension lookups) with the legacy `kern` table as fallback. Glyph outlines come back as an `Outline` of quadratic contours with a `Transform` (scale, fractional origin, optional shear for synthetic italics) and a flatness-driven `flatten`. Every read is bounds-checked and the parser compiles for `wasm32-freestanding`.
  - `Font` is a new `union(enum) { bitmap: BitmapFont, vector: VectorFont }` with `Font.load` (format sniffing via `FontFormat`, which gained `.ttf`), `ascent`, `lineHeight`, `hasGlyph`, `getTextBounds` and `getTextBoundsTight`, so text APIs take either kind.
  - `Canvas.fillGlyph` fills an outline with the nonzero rule; `Canvas(u8).rasterizeGlyph` and `rasterizePolygons` accumulate antialiased coverage into an 8-bit mask (`dest = max(dest, 255·coverage)`) for glyph atlases.
  - Python: the `BitmapFont` class is replaced by `Font` (`Font.load` autodetects the format, metrics and text measurement methods) and `Canvas.draw_text` takes a pixel `size`.
- **CFF OpenType Fonts**: `VectorFont` also loads `.otf` files with PostScript outlines (`OTTO`): the `CFF ` INDEX/DICT containers, local and global subrs, CID-keyed fonts (FDArray/FDSelect) and a Type 2 charstring interpreter covering the path, hint, flex and subr operators. `Outline` gained cubic segments (`Point.kind` replaces `on_curve`) with a flatness-driven cubic flattener, and `FontFormat` gained `.otf`. Not supported: the deprecated Type 2 arithmetic operators.
  - Font collections (`.ttc`/`.otc`, `FontFormat.ttc`): `VectorFont.loadFace`/`loadFromBytesFace` and `Font.loadFace` pick a face; `load` takes the first. `VectorFont.num_faces` reports the count.
  - `seac` accent composition, resolved through the charset and Standard Encoding.
  - CFF2 (`OTTO` with a `CFF2` table) renders its default instance: `blend` keeps the default values, FDSelect format 4 and the wide INDEX counts are handled; variation axes are not exposed.
- **Text layout**: `Canvas.drawTextBox` lays text out inside a rectangle under a `TextLayout` (`halign`/`valign`, word `wrap`, `line_spacing`, `letter_spacing`), and `Font.measureText` reports the block it fills; the line breaking lives in `font/layout.zig` and works for bitmap and vector fonts alike, walking each paragraph once through a `Pen` cursor. `Canvas.drawTextOutline`/`drawTextBoxOutline` stroke glyph outlines with round joins in one antialiased pass (bitmap fonts get a halo from a dilated coverage mask). `drawText` is unchanged.
- **Round joins for thick strokes**: `drawPolygon`, the Bézier curves and `drawSplinePolygon` render widths above 1 as one joined stroke with round joins and caps, so corners are no longer notched and translucent strokes no longer double-blend at the segment caps.
- **Faster antialiased fills**: nonzero soft fills (glyphs, strokes, `fillPolygons(.nonzero)`) use a signed-area coverage rasterizer with exact per-pixel coverage instead of 8 sub-scanlines, opaque normal blending takes an integer fast path, and the fast fill sweeps only the edges spanning each row. Text renders 2–2.5× faster, thick curves 2–5×.
- **Font file size cap raised to 256 MB** (`font.max_file_size`), enough for the pan-CJK super collections.
- **Thick diagonal lines**: `drawLine` in `.soft` mode visits only the band around the segment and its caps instead of the whole bounding box — 8–13× faster on long diagonals, identical output.
- **`drawRectangle` outlines** with widths above 1 are rasterized directly as the ring between two axis-aligned rectangles — exact antialiasing, square corners, no seams — instead of stroking a polygon: 2–2.5× faster than before in `.soft`, 4–8× in `.fast`.
- **Nonzero polygon fills**: `Canvas.fillPolygons` fills several closed contours as one shape under a `FillRule` (`.even_odd` or `.nonzero`), in both `.fast` and `.soft` modes. `fillPolygon` is unchanged and renders identically.
- **Inferno Colormap**: Added the perceptually-uniform `inferno` colormap (black→purple→orange→yellow) to `image/colormaps.zig`, wired into `Image.applyColormap`, the Python `Colormap.inferno()` factory, and the `colormaps_demo` / global-optimization web examples.
- **Global Optimization**: Added a derivative-free, bound-constrained global optimizer (MaxLIPO + Trust Region) — `GlobalOptimizer` and `findGlobalOptimum` in `src/optimization/`, supporting mixed integer/continuous search spaces and optional parallel objective evaluation through `Io`.
- **Symmetric Eigendecomposition**: Added `Matrix.eigh`, a cyclic-Jacobi eigendecomposition of symmetric matrices that recovers *signed* eigenvalues (handles indefinite matrices, unlike SVD), plus a `Matrix.diagonal` constructor that builds a diagonal matrix from a vector (dlib's `diagm`).
- **BMP Codec** (#348): Native Zig BMP reader and writer with no third-party dependencies.
  - Decoder covers BITMAPCOREHEADER (OS/2 v1) / BITMAPINFOHEADER / V4 / V5 (with v2/v3 tolerated as INFOHEADER variants), 1/4/8/16/24/32 bpp, BI_RGB / BI_BITFIELDS / BI_ALPHABITFIELDS / BI_RLE4 / BI_RLE8 compressions, and both bottom-up and top-down row order.
  - Encoder writes 24bpp BI_RGB for `Image(Rgb)`, 32bpp BI_BITFIELDS with canonical RGBA masks for `Image(Rgba)`, and optional 8bpp linear-gray indexed for `Image(u8)` (via `EncodeOptions.use_palette_for_grayscale`).
  - Wired into `Image(T).load`/`save` for `.bmp` extension, the CLI `info` command, and the Python bindings (`Image.load("foo.bmp")` / `Image.save("foo.bmp")`).
- **GIF Codec**: Native Zig GIF reader and writer with no third-party dependencies.
  - Decoder covers GIF87a/89a, 1/4/8-bit indexed, all four disposal methods (`unspecified`, `do_not_dispose`, `restore_to_background`, `restore_to_previous`), interlaced images, and the NETSCAPE2.0 application extension for loop counts.
  - Multi-frame access via `gif.loadAnimated` / `gif.loadAnimatedFromBytes` returns an `AnimatedImage(T)` of fully-composed frames — disposal, transparency, and de-interlace are absorbed inside the codec.
  - Encoder writes single-frame GIFs (`gif.encode` / `gif.save`) with built-in median-cut quantization and optional Floyd–Steinberg dithering, plus animated GIFs (`gif.encodeAnimated` / `gif.saveAnimated`) with per-frame LCT or a caller-supplied global palette and transparent-index handling for `Image(Rgba)` inputs.
  - Wired into `Image(T).load`/`save` for `.gif` extension and into the CLI `info` command (prints version, dimensions, frame count, loop count, palette size).
  - Python bindings: `Image.load("foo.gif")` and `Image.save("foo.gif")` work for single-frame GIFs.
- **`AnimatedImage(T)` Container**: New generic container in `src/image/animated.zig` for animated raster formats (GIF today, designed for future APNG/WebP). Holds composed frames, per-frame delays in centiseconds, and loop count.
- **Reusable Quantization & Dithering**: Extracted color quantization and dithering from `sixel.zig` into shared, public modules `image/quantize.zig` and `image/dither.zig`. Both sixel and the new GIF encoder consume them.
  - `quantize.medianCut` for adaptive palette generation, `quantize.ColorLookupTable` for fast nearest-color lookup, plus fixed palettes (`linear_gray_256`, `vga16_palette`, `fixed6x7x6Palette`, `web216Palette`).
  - `dither.Mode` (`none`, `floyd_steinberg`, `atkinson`, `ordered`, `auto`) with `dither.apply`, `dither.applyFloydSteinberg`, `dither.applyAtkinson`, `dither.applyOrdered`.
- **iTerm2 Inline Image Protocol**: Added `terminal.iterm2` — PNG-encodes and base64-wraps an image into the iTerm2 `OSC 1337` inline-image sequence, with the same aspect-preserving scaling as the kitty/sixel encoders. Wired into `DisplayFormat` (new `.iterm2` variant) and the `.auto` degradation chain (now kitty → iterm2 → sixel → sgr → braille), the CLI `--protocol iterm2`, and terminal detection (`terminal.isIterm2Supported`, via an XTVERSION probe matching iTerm2/WezTerm).

### Improvements
- **Direction-independent polygon antialiasing**: `Canvas.fillPolygon` in `.soft` mode previously only ramped alpha at the left/right ends of each scanline span, so near-horizontal edges rendered with hard stair-steps. It now samples each pixel row at 8 sub-scanlines with exact horizontal coverage, giving smooth edges in every direction. Affects `fillPolygon`, `fillSplinePolygon`, and thick `drawArc` in `.soft` mode; `.fast` output is unchanged.
- **Single-Threaded Build Robustness**: Sixel's palette LUT cache skips its atomic spinlock under `builtin.single_threaded` (avoids a latent panic on `wasm32-freestanding`).

### Changed
- **`Canvas.drawText` takes a `Font` and a pixel size** (breaking): the `font: BitmapFont, scale: f32` parameters became `font: Font, size: ?f32`, where `size` is the em height for vector fonts and the character height for bitmap fonts; `null` draws at `font.defaultSize()` (a bitmap font's native size, `Font.default_vector_size` = 16 px for vector fonts), so the old `scale` is `scale * font.defaultSize()`. It now returns `!void` since vector glyphs allocate. Wrap bitmap fonts as `.{ .bitmap = font }`.
- **Canvas primitives take a `DrawOptions` struct**: the trailing `mode: DrawMode` parameter of every `draw*`/`fill*` primitive (and `drawText`) is replaced by `opts: DrawOptions { mode: DrawMode, blending: Blending }`. The `.soft` and `.fast` decl-literal presets reproduce the old `DrawMode` behavior exactly (`.soft` = antialiased + `.normal` compositing, `.fast` = aliased + `.none` overwrite), so existing call sites compile and render unchanged. `mode` controls antialiasing only and `blending` selects the compositing mode independently, so all 12 blend modes from `Blending` are now reachable from every primitive via an explicit literal such as `.{ .mode = .soft, .blending = .multiply }` — previously only `drawImage` could blend. Plain overwrites (`.none`, or `.normal` with an opaque color) keep the `@memset`/direct-write fast paths. Breaking: `Canvas.setPixel`/`setPoint` gain an explicit trailing `blending: Blending` parameter. Fix: drawing translucent colors (soft-AA edge coverage, unscaled glyphs) onto non-Rgba canvases now blends through an Rgba round-trip instead of silently overwriting.
- **Matrix methods renamed to conventional short names** (breaking): `inverse` → `inv`, `determinant` → `det`, `pseudoInverse` → `pinv`, `cholesky` → `chol`, and the element-wise (Hadamard) product `times` → `hadamard` (in-place `timesBy` → `hadamardBy`). `ProjectiveTransform.inverse` → `inv`. Applies across `Matrix`, `SMatrix`, `Chain`, and the Python bindings.
- **`RunningStats` now takes a config argument** (breaking): `RunningStats(T)` → `RunningStats(T, config)`, where `RunningStatsConfig` (`.all` / `.variance` / `.summary`) selects which quantities are tracked. Use `.all` for the previous behavior.
- **Terminal graphics encoders grouped under `terminal`** (breaking): the sixel, kitty, and iterm2 encoders moved out of the top-level namespace into `terminal.*` (`zignal.sixel` → `zignal.terminal.sixel`, `zignal.kitty` → `zignal.terminal.kitty`, `zignal.iterm2` → `zignal.terminal.iterm2`). The source files now live in `src/terminal/`. Detection helpers (`terminal.isSixelSupported`, `terminal.aspectScale`, …) and the `DisplayFormat` tags are unchanged.

## [0.10.0] - 2026-04-15

### Major Changes
- **Zig 0.16.0 Migration**: Full codebase update to support Zig 0.16.0.
  - Replaced all deprecated `@intFromFloat` calls with `@round`, `@floor`, `@ceil`, or `@trunc`.
  - Leveraged new result type coercion for rounding built-ins to simplify type casting.
  - Updated `std.Io` and `std.Build` API usage to match latest standard library changes.
  - Transitioned to unmanaged containers requiring explicit allocators.
- **Dimension Standardization**: Standardized image and matrix dimensions/indices to `u32` across the library. (#292, #295, #321)

### Features
- **CLI Subcommands**: Added a robust CLI with `blur`, `edges`, `metrics`, `stats`, `resize`, `tile`, `fdm`, `info`, and `version` commands using declarative argument parsing. (#291, #294, #308, #312, #314, #317)
- **Hough Transform**: Implemented Hough transform for line detection with optimized integer arithmetic and 1D lookup tables. (#326)
- **Edge Vectorization**: Added `Tracer` for converting edge maps into vectorized paths.
- **Advanced Interpolation**: Added Mitchell and Lanczos3 resizing methods with LUT optimizations. (#299, #300)
- **Cholesky Decomposition**: Added high-performance Cholesky decomposition for symmetric positive-definite matrices. (#322)
- **Colormap Support**: Added built-in colormaps (Heat, Jet, etc.) for data visualization. (#336)
- **PCF Font Writing**: Added support for writing fonts in PCF format. (#337)
- **Sixel RLE**: Implemented run-length encoding in the Sixel encoder for smaller output sizes. (#302)
- **Image Difference**: Added utility to compute visual and statistical differences between images. (#309)
- **Generic Blending**: Expanded blending modes to support generic float pixel types. (#335)

### Breaking Changes
- **Interpolation API**: Sampling methods now require an explicit `BorderMode`. (#329)
- **Rectangle API**: Updated `Rectangle` methods to take `Point` types instead of individual coordinates. (#333)
- **Random Matrices**: Matrix generation now requires an explicit `seed` for reproducibility.

### Performance
- **SIMD Optimizations**: Vectorized IDCT, color conversion, and convolution inner loops. (#307, #341)
- **Fast CRC**: Implemented slice-by-8 CRC calculation for PNG encoding/decoding. (#304)
- **Memory Optimization**: Removed redundant allocator field from `HuffmanTable`, reducing memory footprint per table instance.

### Improvements
- **Rounding Accuracy**: Improved numerical precision by replacing manual truncation-based rounding with the `@round` built-in.
- **Infallible Operations**: Made `resize` and `letterbox` infallible by handling edge cases internally. (#334)
- **Border Handling**: Improved rotation and interpolation to consistently respect border modes. (#329, #331)

### Fixes
- **PNG Alpha**: Correctly extract alpha channel for grayscale images. (#330)
- **JPEG Robustness**: Improved restart marker handling and MCG decoding stability.
- **Negative Rounding**: Fixed incorrect rounding logic for negative values in fixed-point constants.

## [0.9.0] - 2025-12-15

### Features
- **Convex Hull Bounds**: `ConvexHull.getRectangle()` (and Python's `get_rectangle()`) returns the tightest axis-aligned rectangle for the cached hull, simplifying ROI extraction from arbitrary point clouds. (#232)
- **Resource Limits in Image Loading**: Enforce resource limits during image loading to prevent excessive memory usage. (#234)
- **Scalar Type Conversion for Transforms**: Added scalar type conversion methods to geometry transforms. (#239)
- **Matrix Element Type Conversion**: Added method to convert matrix element types. (#238)
- **Python Sequence Conversion**: Added sequence conversion and improved memory error handling in Python bindings. (#244)

### Breaking Changes
- **Python Grayscale Dtype Rename**: Renamed `Grayscale` dtype to `Gray` in Python bindings. (#246)
- **Color Scalar Handling**: Generalized scalar color handling to all floats, potentially changing behavior for non-f32 scalars. (#245)
- **Python Color Validation**: Added validation for color component range (0-255), now raising errors for invalid values. (#243)
- **Geometry Transform Allocators**: Removed allocator field from transform structs. (#240)

### Fixes
- **Integral Images**: Prevent initialization of empty images in integral image operations.
- **Python Wheels**: Use explicit Zig targets instead of native for better cross-platform compatibility. (#241)
- **PNG IEND Chunk**: Enforce requirement for mandatory IEND chunk in PNG decoding.
- **PNG Critical Chunk Ordering**: Validate critical chunk ordering in PNG files. (#233)

### Tooling & Docs
- Updated Image I/O description in README.
- Updated CI to use Zig master version. (#236)
- Updated macOS runners in CI matrix. (#231)
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
