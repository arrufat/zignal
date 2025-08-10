# Zignal Python Bindings

High-performance image processing library written in Zig with Python bindings.

## Installation

```console
pip install zignal-processing
```

## Documentation

Full API documentation: [https://bfactory-ai.github.io/zignal/python/zignal.html](https://bfactory-ai.github.io/zignal/python/zignal.html)

## Features

- **Image Processing**: Load, save, resize, crop, blur, rotate with multiple interpolation methods
- **Pixel Operations**: Direct pixel access and assignment with any color type
- **12 Color Spaces**: Automatic conversions between RGB, HSV, Lab, Oklab, and more
- **Canvas Drawing**: Lines, circles, polygons, text rendering with bitmap fonts
- **Terminal Graphics**: Display images using ANSI, Sixel, or Kitty protocols
- **Geometry**: Rectangle and ConvexHull operations
- **Advanced**: Feature distribution matching for color transfer
- **Zero Dependencies**: Pure Zig implementation with no external dependencies

## Quick Examples

### Image Creation and Manipulation

```python
import zignal
import numpy as np

# Create image from scratch
img = zignal.Image(480, 640, (255, 128, 0))  # Orange background

# Load from file
img = zignal.Image.load("photo.jpg")  # Supports PNG and JPEG

# From NumPy array
arr = np.random.randint(0, 255, (480, 640, 3), dtype=np.uint8)
img = zignal.Image.from_numpy(arr)

# Process the image
resized = img.resize((240, 320), zignal.InterpolationMethod.BILINEAR)
blurred = img.box_blur(radius=3)
sharpened = img.sharpen(radius=1)
cropped = img.crop(zignal.Rectangle(100, 100, 200, 200))  # l, t, r, b
```

### Pixel Access and Assignment

```python
# Get pixel value (returns Rgba object)
pixel = img[10, 20]
print(f"Pixel at (10,20): {pixel:ansi}")

# Set pixel with various color formats
img[10, 20] = 128                          # Grayscale
img[10, 21] = (255, 0, 0)                  # RGB tuple
img[10, 22] = (255, 0, 0, 128)             # RGBA tuple
img[10, 23] = zignal.Hsv(180, 100, 100)    # Any color object
```

### Color Spaces

```python
# All color types automatically convert to any other
red = zignal.Rgb(255, 0, 0)
hsv = red.to_hsv()           # Hue, Saturation, Value
lab = red.to_lab()           # CIELAB
oklab = red.to_oklab()       # Perceptually uniform

# Create colors in any space
hsl = zignal.Hsl(180.0, 50.0, 50.0)
rgb = hsl.to_rgb()
```

### Canvas Drawing

```python
# Get canvas for drawing
canvas = img.canvas()

# Draw shapes
canvas.draw_line((10, 10), (100, 100), zignal.Rgb(255, 0, 0))
canvas.draw_circle((200, 200), radius=50, color=(0, 255, 0))
canvas.fill_circle((300, 200), radius=30, color=(0, 0, 255))

# Draw polygon
points = [(100, 100), (200, 120), (180, 200), (80, 180)]
canvas.fill_polygon(points, zignal.Rgba(255, 128, 0, 200))

# Render text with bitmap fonts
font = zignal.BitmapFont.load("font.bdf")  # Load BDF/PCF font
canvas.draw_text("Hello World!", (50, 300), font, color=255)
```

### Terminal Graphics

```python
# Display in terminal using various protocols
print(f"{img:blocks}")         # ANSI color blocks
print(f"{img:sixel:400x200}")  # Sixel graphics (Foor, iTerm2, WezTerm)
print(f"{img:kitty:400x200}")  # Kitty graphics protocol (Kitty, Ghostty)
```
Note that the display size in `sixel` and `kitty` will not distort the image,
but scale it to fit in the `WIDTHxHEIGHT` constraints.
If either is omitted (`WIDTHx` or `xHEIGHT`) it means unconstrained.

### Geometry

```python
# Rectangle operations
rect1 = zignal.Rectangle(10, 10, 100, 100)
rect2 = zignal.Rectangle(50, 50, 100, 100)
intersection = rect1.intersect(rect2)

# Convex hull from points
points = [(0, 0), (100, 0), (100, 100), (0, 100), (50, 50)]
hull = zignal.ConvexHull().find(points)
```

### Feature Distribution Matching

```python
# Transfer color distribution from reference to target
source = zignal.Image.load("source.jpg")
target = zignal.Image.load("reference.jpg")

fdm = zignal.FeatureDistributionMatching()
result = fdm.match(source, target)
result.save("color_transferred.png")
```

## Supported Color Spaces

- **RGB/RGBA**: Standard RGB with optional alpha
- **HSV/HSL**: Hue, Saturation, Value/Lightness
- **Lab/LCH**: CIELAB and cylindrical representation
- **Oklab/Oklch**: Perceptually uniform color spaces
- **XYZ/XYB**: CIE 1931 and JPEG XL color spaces
- **LMS**: Cone response color space
- **YCbCr**: Luma and chroma components

## Building from Source

```bash
git clone https://github.com/bfactory-ai/zignal
cd zignal/bindings/python
pip install -e .
```

## License

MIT License
