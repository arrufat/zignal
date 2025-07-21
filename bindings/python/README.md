# Zignal Python Bindings

Zero-dependency image processing library written in Zig with Python bindings.

## Installation

```bash
pip install zignal-processing
```

## Quick Start

```python
import zignal

# Create RGB color
red = zignal.Rgb(255, 0, 0)
print(f"Red color: {red}")

# Convert to HSV
hsv = red.to_hsv()
print(f"HSV: {hsv}")

# Convert to other color spaces
lab = red.to_lab()
oklab = red.to_oklab()
xyz = red.to_xyz()
```

## Features

- **12 Color Spaces**: RGB, RGBA, HSV, HSL, Lab, XYZ, Oklab, Oklch, LCH, LMS, XYB, YCbCr
- **Seamless Conversions**: Convert between any supported color spaces
- **Type Safety**: Strong typing with validation for color components
- **Zero Dependencies**: No external dependencies, pure Zig implementation
- **High Performance**: Native performance with minimal overhead
- **Cross Platform**: Works on Linux, macOS, and Windows (x86_64 and ARM64)

## Supported Color Spaces

- **RGB/RGBA**: Standard RGB with optional alpha channel (0-255)
- **HSV**: Hue, Saturation, Value (0-360°, 0-100%, 0-100%)
- **HSL**: Hue, Saturation, Lightness (0-360°, 0-100%, 0-100%)
- **Lab**: CIELAB perceptual color space
- **XYZ**: CIE 1931 XYZ color space
- **Oklab**: Perceptually uniform color space by Björn Ottosson
- **Oklch**: Cylindrical representation of Oklab
- **LCH**: Cylindrical representation of Lab
- **LMS**: Long, Medium, Short cone response
- **XYB**: Color space used in JPEG XL
- **YCbCr**: Luma and chroma components

## Examples

### Color Space Conversions

```python
# Create a color in any space
hsl = zignal.Hsl(180.0, 50.0, 50.0)  # Cyan-ish color

# Convert to any other space
rgb = hsl.to_rgb()
lab = hsl.to_lab()
oklab = hsl.to_oklab()

# Chain conversions
original = zignal.Rgb(128, 64, 192)
hsv = original.to_hsv()
back_to_rgb = hsv.to_rgb()
```

### Working with Alpha Channel

```python
# Create RGBA color
rgba = zignal.Rgba(255, 128, 0, 200)  # Orange with transparency

# Convert RGB to RGBA (default alpha=255)
rgb = zignal.Rgb(255, 128, 0)
rgba = rgb.to_rgba()
```

### Modern Color Spaces

```python
# Oklab - perceptually uniform color space
oklab = zignal.Oklab(0.5, 0.1, -0.05)
oklch = oklab.to_oklch()  # Convert to cylindrical form

# Work with perceptual properties
print(f"Lightness: {oklch.l}")
print(f"Chroma: {oklch.c}")
print(f"Hue: {oklch.h}")
```

## Building from Source

Requires Zig compiler:

```bash
git clone https://github.com/bfactory-ai/zignal
cd zignal/bindings/python
pip install -e .
```

## License

MIT License
