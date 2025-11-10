# Python Bindings Changelog

## [0.8.0] - 2025-11-08

### Added
- **Rectangle Conveniences**: New `center`, `top_left`, `bottom_right`, `translate`, `clip`, `diagonal`, and `covers` helpers mirror the Zig rectangle utilities for downstream geometry tooling and unit tests.
- **ConvexHull.get_rectangle()**: Fetch the tightest axis-aligned bounds of the most recent hull as a `Rectangle`, or `None` for degenerate inputs—ideal for cropping or ROI extraction workflows.
- **Image.load_from_bytes**: Load PNG/JPEG data from any bytes-like object or `memoryview` without touching the filesystem while reusing the same validation paths as `load()`.
- **Color.invert()**: All color classes (Rgb, Rgba, Lab, Oklab, Xyz, etc.) gain an `invert()` method that mirrors the Zig implementation and preserves alpha channels.
- **Image.mean_pixel_error()**: Adds a third metric alongside SSIM/PSNR for quick structural comparisons; returns a normalized score in `[0, 1]`.
- **Matrix Norm Helpers**: Dedicated methods (`frobenius_norm`, `l1_norm`, `max_norm`, `element_norm`, `schatten_norm`, `induced_norm`, `nuclear_norm`, `spectral_norm`) expose the richer core norm suite.

### Changed
- **Matrix.norm Removal**: The legacy `Matrix.norm(kind)` entry point is removed in favor of the specific helpers above; adjust callers accordingly. Invalid `p` values now raise `ValueError` instead of panicking.
- **Metric Scaling**: `Image.mean_pixel_error()` now reports a normalized score (0–1) rather than a percentage. Multiply by 100 if you need the old presentation.
- **Transform Errors**: Similarity, affine, and projective fit helpers now raise `ValueError` when the underlying solver fails to converge or the input point set is rank-deficient.

### Fixed
- **Rectangle Tests**: Coverage and overlap checks now treat thresholds as inclusive (`>=`), matching the Zig semantics and preventing false negatives for perfect coverage.
- **Matrix Utilities**: Binary arithmetic helpers propagate existing matrix errors before performing new operations, so chained Python calls no longer hide upstream failures.

## [0.7.1] - 2025-10-24

### Added
- **RunningStats**: New streaming statistics class mirroring the Zig API, with methods for `add()`, `extend()`, `scale()`, `combine()`, and read-only properties (`count`, `mean`, `variance`, `skewness`, etc.).
- **Perlin Noise**: Exposed `zignal.perlin(...)` for procedural noise generation with amplitude, frequency, octave, persistence, and lacunarity controls.

### Changed
- **Argument Validation**: Tightened range checks and error messaging for Perlin noise parameters, providing descriptive `ValueError`s when inputs fall outside supported bounds.

### Fixed
- **Pixel Iterator & Proxy Lifetime**: Corrected reference management when returning pixel proxies from iterators, eliminating GC crashes during long-running image traversals.

## [0.7.0] - 2025-10-08

### Added
- **Matrix Numeric Protocol**: `Matrix` objects now participate fully in Python arithmetic (`+`, `-`, `*`, `/`, unary `-`, scalar combos, and `@` for matrix multiplication) while preserving float64 semantics.
- **Linear Algebra Suite**: Added `.transpose()`, the `.T` property, `.inverse()`, `.det()`, `.norm()`, `.dot()`, `.gram()`, `.cov()`, and element-wise helpers like `.pow()`, along with new convenience constructors `.zeros()`, `.ones()`, `.identity()`, and `.random(seed=...)`.
- **Decomposition APIs**: New `.lu()`, `.qr()`, `.svd()`, `.rank()`, and `.pinv()` methods expose the underlying Zig implementations and return rich dictionaries (e.g., `{q, r, rank, perm}` for QR).
- **Image Quality Metric**: Added `Image.ssim()` for perceptual comparisons that mirrors the Zig SSIM implementation (requires images ≥11×11).

### Changed
- **Python Support Matrix**: Package now requires Python 3.10 or newer and advertises support through Python 3.14; metadata and documentation were updated accordingly.
- **Integer Handling**: Argument parsing uses CPython’s `LongLong` conversions to accept full 64-bit integers in matrix APIs.

### Fixed
- **Image Ownership**: Resolved stale view pointers when Python takes ownership of image buffers, preventing latent crashes when re-wrapping Zig images.
- **Image Views**: Corrected dereferencing while creating Python image views so stride/addressing stay aligned with Zig-side expectations.

## [0.6.0] - 2025-09-30

### Added
- **Binary Image Operations**: Thresholding and morphology functions
  - `threshold_otsu()`, `threshold_adaptive_mean()`
  - `erode()`, `dilate()`, `opening()`, `closing()`
- **Order-Statistic Filters**: Edge-preserving blur methods
  - `blur_median()`, `blur_min()`, `blur_max()`
- **Image Enhancement**: Histogram and contrast operations
  - `equalize()` - Histogram equalization
  - `autocontrast()` - Automatic contrast adjustment
- **Edge Detection**: Advanced edge detection algorithms
  - `canny()` - Classic Canny edge detector with configurable sigma and thresholds (defaults: sigma=1.4, low=50, high=150)
  - `shen_castan()` - Edge detection with ISEF smoothing and adaptive gradient computation
- **Canvas**: `draw_image()` method for compositing images with blending
- **Image I/O**: `save()` method now supports JPEG format
- Binding conventions documented in `BINDINGS_GUIDE.md`

### Changed
- **API Improvements**: Standardized argument parsing across all modules
  - `py_utils.kw()` helper for CPython keyword argument lists
  - Numeric validators (`validatePositive`, `validateNonNegative`, `validateRange`)
  - Consistent error messages for invalid inputs
- **Type Registration**: Consolidated in `src/main.zig` using compile-time tables
- **Enum Handling**: Unified registration and parsing via `enum_utils.zig`
- **Image Creation**: Simplified with `moveImageToPython` helper
- Normalized tuple error messages to "size/shape must be a 2-tuple of (rows, cols)"

### Fixed
- Improved consistency of Python exceptions (TypeError vs ValueError)
- Better error messages across all APIs

## [0.5.1] - 2025-09-03

### Bug Fixes

Fix `image.__format__`: it was broken due to a bad refactor

## [0.5.0] - 2025-09-02

### Major Features

#### Scientific Computing
- **Matrix Class**: Full-featured matrix operations with NumPy interoperability
  - Zero-copy NumPy conversion
  - Runtime dimension support
  - More matrix methods to come
- **PCA (Principal Component Analysis)**: Complete PCA implementation
  - Fit, transform, and inverse transform
  - Batch operations support
  - Configurable components and centering
- **Optimization Module**: Hungarian algorithm for assignment problems

#### Advanced Image Processing
- **Motion Blur**: Linear and spin blur effects
  - Configurable angle, distance, and strength
  - SIMD-optimized performance
- **Convolution & Filtering**:
  - Gaussian blur with sigma control
  - Sobel edge detection
  - Sharpen filter
- **Image Transforms**: Warp, rotate, and perspective transforms
  - With multiple interpolation methods

#### Enhanced Image API
- **Image**: Generic storage (Rgba, Rgb, Grayscale)
- **Pixel-Level Access**: Direct pixel component assignment
  - `image[y, x].r = 255` syntax support
  - Color conversion on pixel proxies
  - Blend operations at pixel level
- **NumPy Integration**: Improved strided image support
  - Handles non-contiguous arrays
  - Preserves memory layout
- **Image Operations**:
  - `copy()`, `dupe()`, `fill()` methods
  - `view()`, `is_view` property
  - `crop()`, `extract()`, `insert()` methods
  - `flip_horizontal()`, `flip_vertical()`, `rotate()`
  - `set_border()`, `get_rectangle()`
  - PSNR calculation

#### Drawing Enhancements
- **Arc Drawing**: Circle arcs with fill support
  - Start/end angles in degrees
  - Antialiased rendering
- **Advanced Blending**: 12 blend modes for compositing
  - Per-pixel and whole-image blending
  - Mode selection via Blending enum

### API Improvements
- **Type Annotations**: Modern Python type hints
  - Uses `T | None` syntax
  - Comprehensive stub files (.pyi)
  - Better IDE autocomplete
- **Iteration Support**: Images are now iterable
  - Row-by-row iteration
  - Pixel iterator access
- **Comparison Operators**: Color types support equality comparison
- **Rectangle Enhancements**:
  - IoU (Intersection over Union) calculation
  - Overlap detection
  - Tuple support for intersection

### Breaking Changes
- **Canvas.draw_text**: Parameter order changed
  - Old: `draw_text(x, y, text, font, color)`
  - New: `draw_text(x, y, text, color, font)`

### Bug Fixes
- Fixed RGBA object detection in Image color initialization
- Corrected alpha blending in Canvas.fill_rectangle SOFT mode
- Improved error messages with file paths
- Fixed None handling in Image.set_border

### Performance
- SIMD-optimized filtering operations
- Efficient memory management for views
- Zero-copy operations where possible

## [0.4.1] - 2025-08-06

### Fixed
- **Canvas.fill_rectangle** now properly uses alpha blending in SOFT mode
- **Canvas.draw_line** has some improvements with 1-width SOFT lines

## [0.4.0] - 2025-08-06

### Added
- **Image Instantiation**: Create images directly from Python
  - `Image(rows, cols)` - Create image with specified dimensions
  - `Image(rows, cols, color="white")` - Create with initial color
- **Terminal Image Scaling**: Scale images for terminal display
  - Sixel format: `format(image, "sixel:800x600")` scales to fit before display
  - Kitty format: `format(image, "kitty:800x600")` scales to fit before display
  - Supports partial specifications: `"sixel:800x"` (width only), `"sixel:x600"` (height only)

### Changed
- **Breaking**: Canvas `drawText` method parameter order changed
  - Old: `drawText(x, y, text, font, color)`
  - New: `drawText(x, y, text, color, font)`
- **Documentation**: Enhanced docstrings and type hints
  - Added comprehensive `__init__` docstrings for all classes
  - Modernized type hints using pipe operator (`|`) syntax
  - Improved IDE autocomplete support

### Internal
- Simplified font handling in Canvas text drawing
- Extracted RGBA attribute parsing to shared utilities
- Better error messages for invalid color types
- Improved Python stub generation

## [0.3.0] - 2025-08-04

### Added

#### Canvas API
- **Complete Drawing API**: Full-featured Canvas class for 2D graphics
  - Drawing methods: lines, circles, polygons, rectangles, text
  - Bézier curves: quadratic and cubic with adaptive subdivision
  - Spline polygons with tension control
  - Variable line widths and antialiasing options
  - Fast and soft drawing modes
- **Fill Operations**: Comprehensive shape filling
  - Fill rectangles, circles, and arbitrary polygons
  - Antialiased edges for smooth rendering
  - Efficient scanline algorithms

#### Geometry Support
- **Rectangle Class**: Complete rectangle operations
- **ConvexHull**: Compute convex hulls from point sets

#### Text Rendering
- **BitmapFont Class**: Text rendering with bitmap fonts
  - Load BDF and PCF font files, with automatic decompression
  - Unicode character support

#### Enhanced Image Class
- **Expanded API**: Significantly more functionality
  - New methods for image manipulation
  - Better integration with Canvas
  - More efficient memory management
- **Improved Property Access**: Additional image properties exposed

#### Feature Distribution Matching
- **Enhanced FDM Module**: Improved API and functionality
  - More intuitive interface
  - Better performance
  - Additional options for color transfer

### Changed
- Type stubs significantly improved for better IDE support
- Internal refactoring using comptime to reduce code duplication
- More comprehensive error messages and validation

### Fixed
- Various edge cases in color conversions
- Memory management improvements
- Better error handling throughout

## [0.2.0] - 2025-07-25

### Breaking Changes
- **Image Internal Storage**: The `Image` class (formerly `ImageRgb`) now uses RGBA internal storage
  - Enables SIMD optimizations for 2-5x performance improvements
  - Increases memory usage by ~33% (4 bytes per pixel instead of 3)
  - External API remains unchanged - RGB images are automatically converted

### Added
- **Feature Distribution Matching (FDM)**: New module for advanced color transfer algorithms
  - Transfer color distributions between images
  - Domain adaptation capabilities
- **Zero-Copy NumPy Integration**: Efficient conversion without data copying
  - `to_numpy()` method for Image objects
  - `from_numpy()` coming in future release
- **Image Interpolation**: Access to all Zignal interpolation methods
  - Methods: nearest, bilinear, bicubic, catmull_rom, lanczos, mitchell
- **Rich Display Support**: `__format__` method for terminal and notebook display
  - ANSI full/half-block, Sixel, Kitty, Braille, and formats
- **Type Stubs**: Comprehensive `.pyi` files for IDE support
  - Full type hints for all classes and methods
  - Improved autocomplete and static analysis

### Changed
- Image class can now save to PNG format (`.png` extension required)
- Smart versioning system using `build.zig.zon` as source of truth
- Optimized wheel builds with stripped debug symbols (50% size reduction)

### Distribution
- Automated wheel building for Python 3.8-3.13
- Support for Linux, macOS (Intel & ARM), and Windows
- CI/CD pipeline for automated PyPI releases

## [0.1.0] - 2024-07-21

### Initial Release

### Core Features
- **Complete Color Space Support**: All 12 Zignal color spaces
  - RGB types: `Rgb`, `Rgba`
  - Perceptual: `Hsl`, `Hsv`
  - Lab family: `Lab`, `Lch`
  - Modern: `Oklab`, `Oklch`
  - Device: `Xyz`, `Lms`
  - Specialized: `Xyb`, `Ycbcr`
- **Image Class**: Basic image I/O and manipulation
  - Load PNG and JPEG images
  - Save to PNG format
  - Access image dimensions via `rows` and `cols` properties
- **Type Safety**: Proper validation and error handling
- **Pythonic API**: Natural property access and method calls
- **High Performance**: Zero-copy operations where possible

### Architecture
- Pure Zig implementation using Python C API
- No Python runtime dependencies
- Efficient memory management
- Cross-platform support
