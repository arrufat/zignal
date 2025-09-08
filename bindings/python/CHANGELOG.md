# Python Bindings Changelog

## [Unreleased]

### Added
- `py_utils.kw(&.{ ... })` helper for building CPython kwlists at comptime.
- `validatePositive`, `validateNonNegative`, `validateRange` numeric validators with consistent error messages.
- Binding conventions documented (see BINDINGS_GUIDE.md) for enums, arg parsing, image wrapping, and exceptions.

### Changed
- Consolidated type registration in `src/main.zig` using a compile‑time table.
- Adopted kw helper across the codebase (transforms, canvas, filtering, matrix, PCA, motion blur, pixel proxy, rectangle).
- Normalized tuple error messages to "size/shape must be a 2‑tuple of (rows, cols)".
- Moved new‑image return paths to `moveImageToPython` to reduce duplication.

### Fixed
- Improved consistency of Python exceptions (TypeError vs ValueError) and messages across APIs.

### Quality
- 77 tests passing with `uv run pytest`; stubs regenerated via `zig build python-stubs`.

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
