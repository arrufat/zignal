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
print(f"Hex: 0x{red.to_hex():06x}")
print(f"Luma: {red.luma():.4f}")

# Create from hex
purple = zignal.Rgb.from_hex(0x800080)
print(f"Purple: {purple}")

# Create grayscale
gray = zignal.Rgb.from_gray(128)
print(f"Gray: {gray}")
```

## Features

- **RGB Color Type**: Create and manipulate RGB colors with validation
- **Color Conversion**: Convert to/from hex, grayscale, and other formats
- **Zero Dependencies**: No external dependencies, everything built-in
- **High Performance**: Native Zig implementation for speed
- **Cross Platform**: Works on Linux, macOS, and Windows

## Building from Source

Requires Zig compiler:

```bash
git clone https://github.com/bfactory-ai/zignal
cd zignal/bindings/python
pip install -e .
```

## License

MIT License
