# Changelog

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
  - Allows images to be scaled (perserving aspect-ratio) before transmission to terminal

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
- **OpsBuilder**: Fluent API for complex matrix operations
- **Static Matrices**: `SMatrix` for compile-time sized matrices

### Principal Component Analysis
- **PCA Implementation**: Full PCA with eigenvalue decomposition
- **Dimensionality Reduction**: Project data to lower dimensions
- **Visualization**: Built-in support for 2D/3D projections
- **Example Applications**: Face alignment, data visualization

### Image Processing
- **Feature distrubtion matching** for domain adaption

### Procedural Generation
- **Perlin Noise**: High-quality noise generation for textures and terrain
- **Configurable**: Adjustable frequency, amplitude, and octaves
- **2D/3D Support**: Generate noise in multiple dimensions

