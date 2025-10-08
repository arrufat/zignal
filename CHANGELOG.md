# Changelog

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
