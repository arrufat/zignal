const std = @import("std");

const zignal = @import("zignal");
pub const Canvas = zignal.Canvas;
const DrawMode = zignal.DrawMode;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

pub const CanvasObject = extern struct {
    ob_base: c.PyObject,
    // Keep reference to parent Image to prevent garbage collection
    image_ref: ?*c.PyObject,
    // Store a pointer to the heap-allocated Canvas struct
    canvas_ptr: ?*Canvas(zignal.Rgba),
};

fn canvas_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*CanvasObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.image_ref = null;
        obj.canvas_ptr = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn canvas_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = kwds;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Parse arguments - expect an Image object
    var image_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &image_obj) == 0) {
        return -1;
    }

    // Import the image module to get the ImageType
    const image_module = @import("image.zig");

    // Check if it's an Image instance
    if (c.PyObject_IsInstance(image_obj, @ptrCast(&image_module.ImageType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Argument must be an Image instance");
        return -1;
    }

    const image = @as(*image_module.ImageObject, @ptrCast(image_obj.?));

    // Check if image is initialized
    if (image.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return -1;
    }

    // Keep reference to parent Image to prevent garbage collection
    c.Py_INCREF(image_obj.?);
    self.image_ref = image_obj;

    // Create and store the Canvas struct
    const canvas_ptr = allocator.create(Canvas(zignal.Rgba)) catch {
        c.Py_DECREF(image_obj.?);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Canvas");
        return -1;
    };

    // Initialize the Canvas
    if (image.image_ptr) |img_ptr| {
        canvas_ptr.* = Canvas(zignal.Rgba).init(allocator, img_ptr.*);
    } else {
        allocator.destroy(canvas_ptr);
        c.Py_DECREF(image_obj.?);
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return -1;
    }
    self.canvas_ptr = canvas_ptr;

    return 0;
}

fn canvas_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Free the Canvas struct
    if (self.canvas_ptr) |ptr| {
        allocator.destroy(ptr);
    }

    // Release reference to parent Image
    if (self.image_ref) |ref| {
        c.Py_XDECREF(ref);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn canvas_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.canvas_ptr) |canvas| {
        var buffer: [64]u8 = undefined;
        const formatted = std.fmt.bufPrintZ(&buffer, "Canvas({d}x{d})", .{ canvas.image.rows, canvas.image.cols }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("Canvas(uninitialized)");
    }
}

const canvas_fill_doc =
    \\Fill the entire canvas with a color.
    \\
    \\## Parameters
    \\- `color` (int, tuple or color object): Color to fill the canvas with. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\canvas.fill(128)  # Fill with gray
    \\canvas.fill((255, 0, 0))  # Fill with red
    \\canvas.fill(Rgb(0, 255, 0))  # Fill with green using Rgb object
    \\```
;

fn canvas_fill(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse color argument
    var color_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &color_obj) == 0) {
        return null;
    }

    // Convert color to Rgba
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;

    // Use the stored Canvas directly
    self.canvas_ptr.?.fill(color);

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

const canvas_draw_line_doc =
    \\Draw a line between two points.
    \\
    \\## Parameters
    \\- `p1` (tuple[float, float]): Starting point coordinates (x, y)
    \\- `p2` (tuple[float, float]): Ending point coordinates (x, y)
    \\- `color` (int, tuple or color object): Color of the line. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Draw a gray line
    \\canvas.draw_line((0, 0), (100, 100), 128)
    \\# Draw a red line from top-left to bottom-right
    \\canvas.draw_line((0, 0), (100, 100), (255, 0, 0))
    \\# Draw a thick blue line with antialiasing
    \\canvas.draw_line((50, 50), (150, 50), (0, 0, 255), width=5, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_line(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments - p1, p2, color are required; width and mode are optional
    var p1_obj: ?*c.PyObject = undefined;
    var p2_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "p1", "p2", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OOO|ll", .{});

    // TODO: remove @constCast once we only use Python >= 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &p1_obj, &p2_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert Python objects to Zig types
    const p1 = py_utils.parsePointTuple(@ptrCast(p1_obj)) catch return null;
    const p2 = py_utils.parsePointTuple(@ptrCast(p2_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;

    // Convert mode to DrawMode enum
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the line
    self.canvas_ptr.?.drawLine(p1, p2, color, @intCast(width), draw_mode);

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

const canvas_draw_rectangle_doc =
    \\Draw a rectangle outline.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Color of the rectangle. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\rect = Rectangle(10, 10, 100, 50)
    \\# Draw a red rectangle
    \\canvas.draw_rectangle(rect, (255, 0, 0))
    \\# Draw a thick blue rectangle with antialiasing
    \\canvas.draw_rectangle(rect, (0, 0, 255), width=3, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments - rect, color are required; width and mode are optional
    var rect_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "rect", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OO|ll", .{});

    // TODO: remove @constCast once we only use Python >= 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &rect_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert Python objects to Zig types
    const rect = py_utils.parseRectangle(@ptrCast(rect_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;

    // Convert mode to DrawMode enum
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the rectangle
    self.canvas_ptr.?.drawRectangle(rect, color, @intCast(width), draw_mode);

    // Return None
    return py_utils.returnNone();
}

const canvas_draw_polygon_doc =
    \\Draw a polygon outline.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Color of the polygon. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Draw a triangle
    \\points = [(50, 10), (10, 90), (90, 90)]
    \\canvas.draw_polygon(points, (255, 0, 0))
    \\# Draw a thick pentagon with antialiasing
    \\points = [(50, 10), (90, 35), (75, 80), (25, 80), (10, 35)]
    \\canvas.draw_polygon(points, (0, 255, 0), width=2, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var points_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "points", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OO|ll", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &points_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Parse points
    const points = py_utils.parsePointList(@ptrCast(points_obj)) catch return null;
    defer py_utils.freePointList(points);

    // Convert color and mode
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the polygon
    self.canvas_ptr.?.drawPolygon(points, color, @intCast(width), draw_mode);

    return py_utils.returnNone();
}

const canvas_draw_circle_doc =
    \\Draw a circle outline.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Color of the circle. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Draw a red circle
    \\canvas.draw_circle((50, 50), 30, (255, 0, 0))
    \\# Draw a thick blue circle with antialiasing
    \\canvas.draw_circle((100, 100), 50, (0, 0, 255), width=3, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_circle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var center_obj: ?*c.PyObject = undefined;
    var radius: f64 = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "center", "radius", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OdO|ll", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &center_obj, &radius, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate radius
    if (radius < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Radius must be non-negative");
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert arguments
    const center = py_utils.parsePointTuple(@ptrCast(center_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the circle
    self.canvas_ptr.?.drawCircle(center, @as(f32, @floatCast(radius)), color, @intCast(width), draw_mode);

    return py_utils.returnNone();
}

const canvas_fill_rectangle_doc =
    \\Fill a rectangle area.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Fill color. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\rect = Rectangle(10, 10, 100, 50)
    \\# Fill a red rectangle
    \\canvas.fill_rectangle(rect, (255, 0, 0))
    \\# Fill a blue rectangle with antialiasing
    \\canvas.fill_rectangle(rect, (0, 0, 255), mode=DrawMode.SOFT)
    \\```
;

fn canvas_fill_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var rect_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "rect", "color", "mode", null };
    const format = std.fmt.comptimePrint("OO|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &rect_obj, &color_obj, &mode) == 0) {
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert arguments
    const rect = py_utils.parseRectangle(@ptrCast(rect_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Fill the rectangle
    self.canvas_ptr.?.fillRectangle(rect, color, draw_mode);

    return py_utils.returnNone();
}

const canvas_fill_polygon_doc =
    \\Fill a polygon area.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Fill color. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Fill a triangle
    \\points = [(50, 10), (10, 90), (90, 90)]
    \\canvas.fill_polygon(points, (255, 0, 0))
    \\# Fill a pentagon with antialiasing
    \\points = [(50, 10), (90, 35), (75, 80), (25, 80), (10, 35)]
    \\canvas.fill_polygon(points, (0, 255, 0), mode=DrawMode.SOFT)
    \\```
;

fn canvas_fill_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var points_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "points", "color", "mode", null };
    const format = std.fmt.comptimePrint("OO|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &points_obj, &color_obj, &mode) == 0) {
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Parse points
    const points = py_utils.parsePointList(@ptrCast(points_obj)) catch return null;
    defer py_utils.freePointList(points);

    // Convert arguments
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Fill the polygon
    self.canvas_ptr.?.fillPolygon(points, color, draw_mode) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to fill polygon");
        return null;
    };

    return py_utils.returnNone();
}

const canvas_fill_circle_doc =
    \\Fill a circle area.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Fill color. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Fill a red circle
    \\canvas.fill_circle((50, 50), 30, (255, 0, 0))
    \\# Fill a blue circle with antialiasing
    \\canvas.fill_circle((100, 100), 50, (0, 0, 255), mode=DrawMode.SOFT)
    \\```
;

fn canvas_fill_circle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var center_obj: ?*c.PyObject = undefined;
    var radius: f64 = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "center", "radius", "color", "mode", null };
    const format = std.fmt.comptimePrint("OdO|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &center_obj, &radius, &color_obj, &mode) == 0) {
        return null;
    }

    // Validate radius
    if (radius < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Radius must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert arguments
    const center = py_utils.parsePointTuple(@ptrCast(center_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Fill the circle
    self.canvas_ptr.?.fillCircle(center, @as(f32, @floatCast(radius)), color, draw_mode);

    return py_utils.returnNone();
}

const canvas_draw_quadratic_bezier_doc =
    \\Draw a quadratic Bézier curve.
    \\
    \\## Parameters
    \\- `p0` (tuple[float, float]): Start point (x, y)
    \\- `p1` (tuple[float, float]): Control point (x, y)
    \\- `p2` (tuple[float, float]): End point (x, y)
    \\- `color` (int, tuple or color object): Color of the curve. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Draw a quadratic Bézier curve
    \\canvas.draw_quadratic_bezier((10, 50), (50, 10), (90, 50), (255, 0, 0))
    \\# Draw a thick blue curve with antialiasing
    \\canvas.draw_quadratic_bezier((20, 80), (50, 20), (80, 80), (0, 0, 255), width=3, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_quadratic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var p0_obj: ?*c.PyObject = undefined;
    var p1_obj: ?*c.PyObject = undefined;
    var p2_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "p0", "p1", "p2", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OOOO|ll", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &p0_obj, &p1_obj, &p2_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert arguments
    const p0 = py_utils.parsePointTuple(@ptrCast(p0_obj)) catch return null;
    const p1 = py_utils.parsePointTuple(@ptrCast(p1_obj)) catch return null;
    const p2 = py_utils.parsePointTuple(@ptrCast(p2_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the curve
    self.canvas_ptr.?.drawQuadraticBezier(p0, p1, p2, color, @intCast(width), draw_mode);

    return py_utils.returnNone();
}

const canvas_draw_cubic_bezier_doc =
    \\Draw a cubic Bézier curve.
    \\
    \\## Parameters
    \\- `p0` (tuple[float, float]): Start point (x, y)
    \\- `p1` (tuple[float, float]): First control point (x, y)
    \\- `p2` (tuple[float, float]): Second control point (x, y)
    \\- `p3` (tuple[float, float]): End point (x, y)
    \\- `color` (int, tuple or color object): Color of the curve. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Draw a cubic Bézier curve
    \\canvas.draw_cubic_bezier((10, 50), (30, 10), (70, 90), (90, 50), (255, 0, 0))
    \\# Draw a thick blue curve with antialiasing
    \\canvas.draw_cubic_bezier((10, 80), (30, 20), (70, 20), (90, 80), (0, 0, 255), width=3, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_cubic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var p0_obj: ?*c.PyObject = undefined;
    var p1_obj: ?*c.PyObject = undefined;
    var p2_obj: ?*c.PyObject = undefined;
    var p3_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "p0", "p1", "p2", "p3", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OOOOO|ll", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &p0_obj, &p1_obj, &p2_obj, &p3_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert arguments
    const p0 = py_utils.parsePointTuple(@ptrCast(p0_obj)) catch return null;
    const p1 = py_utils.parsePointTuple(@ptrCast(p1_obj)) catch return null;
    const p2 = py_utils.parsePointTuple(@ptrCast(p2_obj)) catch return null;
    const p3 = py_utils.parsePointTuple(@ptrCast(p3_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the curve
    self.canvas_ptr.?.drawCubicBezier(p0, p1, p2, p3, color, @intCast(width), draw_mode);

    return py_utils.returnNone();
}

const canvas_draw_spline_polygon_doc =
    \\Draw a smooth spline through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Color of the spline. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Draw a smooth spline through points
    \\points = [(10, 50), (30, 10), (50, 90), (70, 10), (90, 50)]
    \\canvas.draw_spline_polygon(points, (255, 0, 0))
    \\# Draw with custom tension and antialiasing
    \\canvas.draw_spline_polygon(points, (0, 255, 0), width=2, tension=0.7, mode=DrawMode.SOFT)
    \\```
;

fn canvas_draw_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var points_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var tension: f64 = 0.5;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "points", "color", "width", "tension", "mode", null };
    const format = std.fmt.comptimePrint("OO|ldl", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &points_obj, &color_obj, &width, &tension, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate tension
    if (tension < 0.0 or tension > 1.0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Tension must be between 0.0 and 1.0");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Parse points
    const points = py_utils.parsePointList(@ptrCast(points_obj)) catch return null;
    defer py_utils.freePointList(points);

    // Convert arguments
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the spline
    self.canvas_ptr.?.drawSplinePolygon(points, color, @intCast(width), @as(f32, @floatCast(tension)), draw_mode);

    return py_utils.returnNone();
}

const canvas_fill_spline_polygon_doc =
    \\Fill a smooth spline area through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Fill color. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Fill a smooth spline area
    \\points = [(50, 10), (90, 30), (90, 70), (50, 90), (10, 70), (10, 30)]
    \\canvas.fill_spline_polygon(points, (255, 0, 0))
    \\# Fill with custom tension and antialiasing
    \\canvas.fill_spline_polygon(points, (0, 255, 0), tension=0.7, mode=DrawMode.SOFT)
    \\```
;

fn canvas_fill_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var points_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var tension: f64 = 0.5;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "points", "color", "tension", "mode", null };
    const format = std.fmt.comptimePrint("OO|dl", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &points_obj, &color_obj, &tension, &mode) == 0) {
        return null;
    }

    // Validate tension
    if (tension < 0.0 or tension > 1.0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Tension must be between 0.0 and 1.0");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Parse points
    const points = py_utils.parsePointList(@ptrCast(points_obj)) catch return null;
    defer py_utils.freePointList(points);

    // Convert arguments
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Fill the spline
    self.canvas_ptr.?.fillSplinePolygon(points, color, @as(f32, @floatCast(tension)), draw_mode) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to fill spline polygon");
        return null;
    };

    return py_utils.returnNone();
}

const canvas_draw_text_doc =
    \\Draw text on the canvas.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw
    \\- `position` (tuple[float, float]): Position coordinates (x, y)
    \\- `font` (BitmapFont): Font object to use for rendering
    \\- `color` (int, tuple or color object): Text color. Can be:
    \\  - Integer: grayscale value 0-255 (0=black, 255=white)
    \\  - RGB tuple: `(r, g, b)` with values 0-255
    \\  - RGBA tuple: `(r, g, b, a)` with values 0-255
    \\  - Any color object: `Rgb`, `Rgba`, `Hsl`, `Hsv`, `Lab`, `Lch`, `Lms`, `Oklab`, `Oklch`, `Xyb`, `Xyz`, `Ycbcr`
    \\- `scale` (float, optional): Text scale factor (default: 1.0)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\# Use default font
    \\font = BitmapFont.get_default_font()
    \\canvas.draw_text("Hello World!", (50, 50), font, (255, 255, 255))
    \\# Draw scaled text
    \\canvas.draw_text("Big Text", (50, 100), font, (255, 0, 0), scale=2.0)
    \\# Load custom font
    \\custom_font = BitmapFont.load("myfont.bdf")
    \\canvas.draw_text("Custom Font", (50, 150), custom_font, (0, 255, 0))
    \\```
;

fn canvas_draw_text(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments
    var text_obj: ?*c.PyObject = undefined;
    var position_obj: ?*c.PyObject = undefined;
    var font_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var scale: f64 = 1.0;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "text", "position", "font", "color", "scale", "mode", null };
    const format = std.fmt.comptimePrint("OOOO|dl:draw_text", .{});
    // TODO: remove @constCast once we only use Python >= 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, @constCast(kwds), format.ptr, @constCast(@ptrCast(&kwlist)), &text_obj, &position_obj, &font_obj, &color_obj, &scale, &mode) == 0) {
        return null;
    }

    // Convert text to string
    const text_cstr = c.PyUnicode_AsUTF8(text_obj) orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "text must be a string");
        return null;
    };
    const text = std.mem.span(text_cstr);

    // Parse position
    const position = py_utils.parsePointTuple(position_obj) catch return null;

    // Check if font is a BitmapFont
    const bitmap_font_module = @import("bitmap_font.zig");
    if (c.PyObject_IsInstance(font_obj, @ptrCast(&bitmap_font_module.BitmapFontType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "font must be a BitmapFont instance");
        return null;
    }
    const font_wrapper = @as(*bitmap_font_module.BitmapFontObject, @ptrCast(font_obj.?));

    // Parse color
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the text
    if (font_wrapper.font) |font| {
        self.canvas_ptr.?.drawText(text, position, font.*, color, @as(f32, @floatCast(scale)), draw_mode);
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "BitmapFont not initialized");
        return null;
    }

    return py_utils.returnNone();
}

fn canvas_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.canvas_ptr) |canvas| {
        return c.PyLong_FromLong(@intCast(canvas.image.rows));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }
}

fn canvas_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.canvas_ptr) |canvas| {
        return c.PyLong_FromLong(@intCast(canvas.image.cols));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }
}

fn canvas_get_image(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.image_ref) |img_ref| {
        c.Py_INCREF(img_ref);
        return img_ref;
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }
}

const colors = "'Rgb', 'Rgba', 'Hsl', 'Hsv', 'Lab', 'Lch', 'Lms', 'Oklab', 'Oklch', 'Xyb', 'Xyz', 'Ycbcr'";

pub const canvas_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "fill",
        .meth = @ptrCast(&canvas_fill),
        .flags = c.METH_VARARGS,
        .doc = canvas_fill_doc,
        .params = "self, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "]",
        .returns = "None",
    },
    .{
        .name = "draw_line",
        .meth = @ptrCast(&canvas_draw_line),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_line_doc,
        .params = "self, p1: Tuple[float, float], p2: Tuple[float, float], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_rectangle",
        .meth = @ptrCast(&canvas_draw_rectangle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_rectangle_doc,
        .params = "self, rect: Rectangle, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_rectangle",
        .meth = @ptrCast(&canvas_fill_rectangle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_rectangle_doc,
        .params = "self, rect: Rectangle, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_polygon",
        .meth = @ptrCast(&canvas_draw_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_polygon_doc,
        .params = "self, points: List[Tuple[float, float]], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_polygon",
        .meth = @ptrCast(&canvas_fill_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_polygon_doc,
        .params = "self, points: List[Tuple[float, float]], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_circle",
        .meth = @ptrCast(&canvas_draw_circle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_circle_doc,
        .params = "self, center: Tuple[float, float], radius: float, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_circle",
        .meth = @ptrCast(&canvas_fill_circle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_circle_doc,
        .params = "self, center: Tuple[float, float], radius: float, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_quadratic_bezier",
        .meth = @ptrCast(&canvas_draw_quadratic_bezier),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_quadratic_bezier_doc,
        .params = "self, p0: Tuple[float, float], p1: Tuple[float, float], p2: Tuple[float, float], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_cubic_bezier",
        .meth = @ptrCast(&canvas_draw_cubic_bezier),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_cubic_bezier_doc,
        .params = "self, p0: Tuple[float, float], p1: Tuple[float, float], p2: Tuple[float, float], p3: Tuple[float, float], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_spline_polygon",
        .meth = @ptrCast(&canvas_draw_spline_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_spline_polygon_doc,
        .params = "self, points: List[Tuple[float, float]], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, tension: float = 0.5, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_spline_polygon",
        .meth = @ptrCast(&canvas_fill_spline_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_spline_polygon_doc,
        .params = "self, points: List[Tuple[float, float]], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], tension: float = 0.5, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_text",
        .meth = @ptrCast(&canvas_draw_text),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_text_doc,
        .params = "self, text: str, position: Tuple[float, float], font: BitmapFont, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], scale: float = 1.0, mode: DrawMode = ...",
        .returns = "None",
    },
};

var canvas_methods = stub_metadata.toPyMethodDefArray(&canvas_methods_metadata);

pub const canvas_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "rows",
        .get = @ptrCast(&canvas_get_rows),
        .set = null,
        .doc = "Number of rows in the canvas",
        .type = "int",
    },
    .{
        .name = "cols",
        .get = @ptrCast(&canvas_get_cols),
        .set = null,
        .doc = "Number of columns in the canvas",
        .type = "int",
    },
    .{
        .name = "image",
        .get = @ptrCast(&canvas_get_image),
        .set = null,
        .doc = "Parent Image object",
        .type = "Image",
    },
};

var canvas_getset = stub_metadata.toPyGetSetDefArray(&canvas_properties_metadata);

pub var CanvasType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.Canvas",
    .tp_basicsize = @sizeOf(CanvasObject),
    .tp_dealloc = canvas_dealloc,
    .tp_repr = canvas_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Canvas for drawing operations on images",
    .tp_methods = @ptrCast(&canvas_methods),
    .tp_getset = @ptrCast(&canvas_getset),
    .tp_init = canvas_init,
    .tp_new = canvas_new,
};

pub fn registerDrawMode(module: *c.PyObject) !void {
    // Create the enum type
    const enum_dict = c.PyDict_New() orelse return error.OutOfMemory;
    defer c.Py_DECREF(enum_dict);

    // Add enum values
    const fast_value = c.PyLong_FromLong(0) orelse return error.OutOfMemory;
    defer c.Py_DECREF(fast_value);
    if (c.PyDict_SetItemString(enum_dict, "FAST", fast_value) < 0) return error.Failed;

    const soft_value = c.PyLong_FromLong(1) orelse return error.OutOfMemory;
    defer c.Py_DECREF(soft_value);
    if (c.PyDict_SetItemString(enum_dict, "SOFT", soft_value) < 0) return error.Failed;

    // Create enum class
    const enum_module = c.PyImport_ImportModule("enum") orelse return error.ImportError;
    defer c.Py_DECREF(enum_module);

    const int_enum = c.PyObject_GetAttrString(enum_module, "IntEnum") orelse return error.AttributeError;
    defer c.Py_DECREF(int_enum);

    const args = c.Py_BuildValue("(sO)", "DrawMode", enum_dict) orelse return error.OutOfMemory;
    defer c.Py_DECREF(args);

    const draw_mode_type = c.PyObject_CallObject(int_enum, args) orelse return error.CallError;

    // Set docstring
    const doc_str = c.PyUnicode_FromString(
        \\Rendering quality mode for drawing operations.
        \\
        \\## Attributes
        \\- `FAST` (int): Fast rendering without antialiasing (value: 0)
        \\- `SOFT` (int): High-quality rendering with antialiasing (value: 1)
        \\
        \\## Notes
        \\- FAST mode provides pixel-perfect rendering with sharp edges
        \\- SOFT mode provides smooth, antialiased edges for better visual quality
        \\- Default mode is FAST for performance
    ) orelse return error.OutOfMemory;
    defer c.Py_DECREF(doc_str);

    if (c.PyObject_SetAttrString(draw_mode_type, "__doc__", doc_str) < 0) {
        c.Py_DECREF(draw_mode_type);
        return error.Failed;
    }

    // Set __module__ attribute to help pdoc recognize it as a top-level class
    const module_name = c.PyUnicode_FromString("zignal") orelse return error.OutOfMemory;
    defer c.Py_DECREF(module_name);

    if (c.PyObject_SetAttrString(draw_mode_type, "__module__", module_name) < 0) {
        c.Py_DECREF(draw_mode_type);
        return error.Failed;
    }

    // Add to module
    if (c.PyModule_AddObject(module, "DrawMode", draw_mode_type) < 0) {
        c.Py_DECREF(draw_mode_type);
        return error.Failed;
    }
}
