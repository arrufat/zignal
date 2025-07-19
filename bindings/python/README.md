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
print(f"Red color: {red}, {red.to_hsv()}")
```

## Features

- **Color Conversion**: Support for 12 color space conversions
- **Image support**: Load PNG/JPEG images and convert from and to NumPy arrays
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
