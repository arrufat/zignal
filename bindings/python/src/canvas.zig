const std = @import("std");

const zignal = @import("zignal");
pub const Canvas = zignal.Canvas;
const DrawMode = zignal.DrawMode;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;
const BitmapFont = zignal.BitmapFont;

const color_utils = @import("color_utils.zig");
const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const PyImage = @import("PyImage.zig").PyImage;
const stub_metadata = @import("stub_metadata.zig");

/// A variant canvas type that mirrors PyImage structure
pub const PyCanvas = struct {
    pub const Variant = union(PyImage.DType) {
        grayscale: Canvas(u8),
        rgb: Canvas(Rgb),
        rgba: Canvas(Rgba),
    };

    data: Variant,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a PyCanvas from a PyImage
    pub fn initFromPyImage(alloc: std.mem.Allocator, py_image: *PyImage) Self {
        return .{
            .data = switch (py_image.data) {
                .grayscale => |img| .{ .grayscale = Canvas(u8).init(alloc, img) },
                .rgb => |img| .{ .rgb = Canvas(Rgb).init(alloc, img) },
                .rgba => |img| .{ .rgba = Canvas(Rgba).init(alloc, img) },
            },
            .allocator = alloc,
        };
    }

    /// Get the dtype of this canvas
    pub fn dtype(self: *const Self) PyImage.DType {
        return @as(PyImage.DType, self.data);
    }

    /// Get the number of rows
    pub fn rows(self: *const Self) usize {
        return switch (self.data) {
            inline else => |canvas| canvas.image.rows,
        };
    }

    /// Get the number of columns
    pub fn cols(self: *const Self) usize {
        return switch (self.data) {
            inline else => |canvas| canvas.image.cols,
        };
    }

    /// Fill the entire canvas with a color
    pub fn fill(self: *Self, color: Rgba) void {
        switch (self.data) {
            inline else => |*canvas| canvas.fill(color),
        }
    }

    /// Draw a line
    pub fn drawLine(self: *Self, p1: anytype, p2: anytype, color: Rgba, width: u32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawLine(p1, p2, color, width, mode),
        }
    }

    /// Draw a rectangle
    pub fn drawRectangle(self: *Self, rect: anytype, color: Rgba, width: u32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawRectangle(rect, color, width, mode),
        }
    }

    /// Fill a rectangle
    pub fn fillRectangle(self: *Self, rect: anytype, color: Rgba, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.fillRectangle(rect, color, mode),
        }
    }

    /// Draw a polygon
    pub fn drawPolygon(self: *Self, points: anytype, color: Rgba, width: u32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawPolygon(points, color, width, mode),
        }
    }

    /// Fill a polygon
    pub fn fillPolygon(self: *Self, points: anytype, color: Rgba, mode: DrawMode) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.fillPolygon(points, color, mode),
        }
    }

    /// Draw a circle
    pub fn drawCircle(self: *Self, center: anytype, radius: anytype, color: Rgba, width: u32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawCircle(center, radius, color, width, mode),
        }
    }

    /// Fill a circle
    pub fn fillCircle(self: *Self, center: anytype, radius: anytype, color: Rgba, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.fillCircle(center, radius, color, mode),
        }
    }

    /// Draw a quadratic Bezier curve
    pub fn drawQuadraticBezier(self: *Self, p0: anytype, p1: anytype, p2: anytype, color: Rgba, width: u32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawQuadraticBezier(p0, p1, p2, color, width, mode),
        }
    }

    /// Draw a cubic Bezier curve
    pub fn drawCubicBezier(self: *Self, p0: anytype, p1: anytype, p2: anytype, p3: anytype, color: Rgba, width: u32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawCubicBezier(p0, p1, p2, p3, color, width, mode),
        }
    }

    /// Draw a spline polygon
    pub fn drawSplinePolygon(self: *Self, points: anytype, color: Rgba, width: u32, tension: f32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawSplinePolygon(points, color, width, tension, mode),
        }
    }

    /// Fill a spline polygon
    pub fn fillSplinePolygon(self: *Self, points: anytype, color: Rgba, tension: f32, mode: DrawMode) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.fillSplinePolygon(points, color, tension, mode),
        }
    }

    /// Draw an arc
    pub fn drawArc(self: *Self, center: anytype, radius: f32, start_angle: f32, end_angle: f32, color: Rgba, width: u32, mode: DrawMode) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.drawArc(center, radius, start_angle, end_angle, color, width, mode),
        }
    }

    /// Fill an arc
    pub fn fillArc(self: *Self, center: anytype, radius: f32, start_angle: f32, end_angle: f32, color: Rgba, mode: DrawMode) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.fillArc(center, radius, start_angle, end_angle, color, mode),
        }
    }

    /// Draw text
    pub fn drawText(self: *Self, text: []const u8, position: anytype, color: Rgba, font: BitmapFont, scale: f32, mode: DrawMode) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawText(text, position, color, font, scale, mode),
        }
    }
};

// Documentation for the DrawMode enum (used at runtime and for stub generation)
pub const draw_mode_doc =
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
;

// Per-value documentation for stub generation
pub const draw_mode_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "FAST", .doc = "Fast rendering with hard edges" },
    .{ .name = "SOFT", .doc = "Antialiased rendering with smooth edges" },
};

// Static default font with all characters, initialized once
var font8x8: ?BitmapFont = null;

fn getFont8x8() !BitmapFont {
    if (font8x8 == null) {
        font8x8 = try zignal.font.font8x8.create(allocator, .all);
    }
    return font8x8.?;
}

pub const CanvasObject = extern struct {
    ob_base: c.PyObject,
    // Keep reference to parent Image to prevent garbage collection
    image_ref: ?*c.PyObject,
    // Single variant canvas pointer
    py_canvas: ?*PyCanvas,
};

fn canvas_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*CanvasObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.image_ref = null;
        obj.py_canvas = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn canvas_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    // Parse arguments - expect an Image object
    const Params = struct {
        image: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return -1;

    // Import the image module to get the ImageType
    const image_module = @import("image.zig");

    // Check if it's an Image instance
    if (c.PyObject_IsInstance(params.image, @ptrCast(&image_module.ImageType)) <= 0) {
        py_utils.setTypeError("Image instance", params.image);
        return -1;
    }

    const image = @as(*image_module.ImageObject, @ptrCast(params.image.?));

    // Keep reference to parent Image to prevent garbage collection
    c.Py_INCREF(params.image.?);
    self.image_ref = params.image;

    // Initialize based on image format
    if (image.py_image) |pimg| {
        const py_canvas = allocator.create(PyCanvas) catch {
            c.Py_DECREF(params.image.?);
            py_utils.setMemoryError("PyCanvas");
            return -1;
        };
        py_canvas.* = PyCanvas.initFromPyImage(allocator, pimg);
        self.py_canvas = py_canvas;
    } else {
        c.Py_DECREF(params.image.?);
        py_utils.setValueError("Image not initialized", .{});
        return -1;
    }

    return 0;
}

fn canvas_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    // Free the PyCanvas
    if (self.py_canvas) |ptr| {
        allocator.destroy(ptr);
    }

    // Release reference to parent Image
    if (self.image_ref) |ref| {
        c.Py_XDECREF(ref);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn canvas_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    if (self.py_canvas) |canvas| {
        var buffer: [64]u8 = undefined;
        const dtype_str = switch (canvas.dtype()) {
            .grayscale => "Grayscale",
            .rgb => "Rgb",
            .rgba => "Rgba",
        };
        const formatted = std.fmt.bufPrintZ(&buffer, "Canvas({d}x{d}, dtype={s})", .{ canvas.rows(), canvas.cols(), dtype_str }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("Canvas(uninitialized)");
    }
}

// Special case: fill method
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

fn canvas_fill(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    // Parse color argument
    var color_obj: ?*c.PyObject = undefined;
    const kw = comptime py_utils.kw(&.{"color"});
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(@constCast(&kw)), &color_obj) == 0) {
        return null;
    }

    // Parse color and fill
    const rgba = color_utils.parseColor(Rgba, @ptrCast(color_obj)) catch return null;
    if (self.py_canvas) |canvas| {
        canvas.fill(rgba);
    } else {
        py_utils.setValueError("Canvas not initialized", .{});
        return null;
    }

    return py_utils.getPyNone();
}

// Draw methods
fn canvas_draw_line(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        p1: ?*c.PyObject,
        p2: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const p1 = py_utils.parsePointTuple(f32, params.p1) catch return null;
    const p2 = py_utils.parsePointTuple(f32, params.p2) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawLine(p1, p2, rgba, width_val, draw_mode);

    return py_utils.getPyNone();
}

const canvas_draw_line_doc =
    \\Draw a line between two points.
    \\
    \\## Parameters
    \\- `p1` (tuple[float, float]): Starting point coordinates (x, y)
    \\- `p2` (tuple[float, float]): Ending point coordinates (x, y)
    \\- `color` (int, tuple or color object): Color of the line.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

fn canvas_draw_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        rect: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = py_utils.parseRectangle(f32, params.rect) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawRectangle(rect, rgba, width_val, draw_mode);

    return py_utils.getPyNone();
}

const canvas_draw_rectangle_doc =
    \\Draw a rectangle outline.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Color of the rectangle.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

fn canvas_draw_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const points = py_utils.parsePointList(f32, params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawPolygon(points, rgba, width_val, draw_mode);

    return py_utils.getPyNone();
}

const canvas_draw_polygon_doc =
    \\Draw a polygon outline.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Color of the polygon.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

fn canvas_draw_circle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const center = py_utils.parsePointTuple(f32, params.center) catch return null;
    const radius = py_utils.validateNonNegative(f32, params.radius, "Radius") catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawCircle(center, radius, rgba, width_val, draw_mode);

    return py_utils.getPyNone();
}

const canvas_draw_circle_doc =
    \\Draw a circle outline.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Color of the circle.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

// Fill methods
fn canvas_fill_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        rect: ?*c.PyObject,
        color: ?*c.PyObject,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = py_utils.parseRectangle(f32, params.rect) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.fillRectangle(rect, rgba, draw_mode);

    return py_utils.getPyNone();
}

const canvas_fill_rectangle_doc =
    \\Fill a rectangle area.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

fn canvas_fill_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const points = py_utils.parsePointList(f32, params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.fillPolygon(points, rgba, draw_mode) catch {
        py_utils.setRuntimeError("Failed to fill polygon", .{});
        return null;
    };

    return py_utils.getPyNone();
}

const canvas_fill_polygon_doc =
    \\Fill a polygon area.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

fn canvas_fill_circle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        color: ?*c.PyObject,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const center = py_utils.parsePointTuple(f32, params.center) catch return null;
    const radius = py_utils.validateNonNegative(f32, params.radius, "Radius") catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.fillCircle(center, radius, rgba, draw_mode);

    return py_utils.getPyNone();
}

const canvas_fill_circle_doc =
    \\Fill a circle area.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

// Special methods that need custom handling
fn canvas_draw_quadratic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        p0: ?*c.PyObject,
        p1: ?*c.PyObject,
        p2: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const p0 = py_utils.parsePointTuple(f32, params.p0) catch return null;
    const p1 = py_utils.parsePointTuple(f32, params.p1) catch return null;
    const p2 = py_utils.parsePointTuple(f32, params.p2) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawQuadraticBezier(p0, p1, p2, rgba, width_val, draw_mode);

    return py_utils.getPyNone();
}

fn canvas_draw_cubic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        p0: ?*c.PyObject,
        p1: ?*c.PyObject,
        p2: ?*c.PyObject,
        p3: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const p0 = py_utils.parsePointTuple(f32, params.p0) catch return null;
    const p1 = py_utils.parsePointTuple(f32, params.p1) catch return null;
    const p2 = py_utils.parsePointTuple(f32, params.p2) catch return null;
    const p3 = py_utils.parsePointTuple(f32, params.p3) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawCubicBezier(p0, p1, p2, p3, rgba, width_val, draw_mode);

    return py_utils.getPyNone();
}

fn canvas_draw_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        tension: f64 = 0.5,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const points = py_utils.parsePointList(f32, params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const tension_val = py_utils.validateRange(f32, params.tension, 0.0, 1.0, "Tension") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawSplinePolygon(points, rgba, width_val, tension_val, draw_mode);

    return py_utils.getPyNone();
}

fn canvas_fill_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        tension: f64 = 0.5,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const points = py_utils.parsePointList(f32, params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const tension_val = py_utils.validateRange(f32, params.tension, 0.0, 1.0, "Tension") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.fillSplinePolygon(points, rgba, tension_val, draw_mode) catch {
        py_utils.setRuntimeError("Failed to fill spline polygon", .{});
        return null;
    };

    return py_utils.getPyNone();
}

fn canvas_draw_arc(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const center = py_utils.parsePointTuple(f32, params.center) catch return null;
    const radius_val: f32 = @floatCast(params.radius);
    const start_angle_val: f32 = @floatCast(params.start_angle);
    const end_angle_val: f32 = @floatCast(params.end_angle);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = py_utils.validateNonNegative(u32, params.width, "Width") catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.drawArc(center, radius_val, start_angle_val, end_angle_val, rgba, width_val, draw_mode) catch {
        py_utils.setRuntimeError("Failed to draw arc", .{});
        return null;
    };

    return py_utils.getPyNone();
}

fn canvas_fill_arc(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        color: ?*c.PyObject,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const center = py_utils.parsePointTuple(f32, params.center) catch return null;
    // Allow negative radius - the Zig library will handle it gracefully (no-op)
    const radius_val: f32 = @floatCast(params.radius);
    const start_angle_val: f32 = @floatCast(params.start_angle);
    const end_angle_val: f32 = @floatCast(params.end_angle);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;
    canvas.fillArc(center, radius_val, start_angle_val, end_angle_val, rgba, draw_mode) catch {
        py_utils.setRuntimeError("Failed to fill arc", .{});
        return null;
    };

    return py_utils.getPyNone();
}

fn canvas_draw_text(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(CanvasObject, self_obj);

    // Parse arguments using struct-based parseArgs
    const Params = struct {
        text: ?*c.PyObject,
        position: ?*c.PyObject,
        color: ?*c.PyObject,
        font: ?*c.PyObject = null,
        scale: f64 = 1.0,
        mode: c_long = 0,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const text_cstr = c.PyUnicode_AsUTF8(params.text) orelse {
        py_utils.setTypeError("string", params.text);
        return null;
    };
    const text = std.mem.span(text_cstr);

    const position = py_utils.parsePointTuple(f32, params.position) catch return null;
    const rgba = color_utils.parseColor(Rgba, @ptrCast(params.color)) catch return null;

    const mode_val = py_utils.validateRange(u32, params.mode, 0, 1, "Mode") catch return null;
    const draw_mode: DrawMode = @enumFromInt(mode_val);

    const py_canvas = py_utils.validateNonNull(*PyCanvas, self.py_canvas, "Canvas") catch return null;

    if (params.font) |font| {
        const bitmap_font_module = @import("bitmap_font.zig");
        if (c.PyObject_IsInstance(font, @ptrCast(&bitmap_font_module.BitmapFontType)) <= 0) {
            if (c.PyErr_Occurred() == null) {
                py_utils.setTypeError("BitmapFont instance or None", font);
            }
            return null;
        }

        const font_wrapper = @as(*bitmap_font_module.BitmapFontObject, @ptrCast(font));
        const font_ptr = py_utils.validateNonNull(*BitmapFont, font_wrapper.font, "BitmapFont") catch return null;
        py_canvas.drawText(text, position, rgba, font_ptr.*, @floatCast(params.scale), draw_mode);
    } else {
        const font = getFont8x8() catch {
            py_utils.setRuntimeError("Failed to initialize default font", .{});
            return null;
        };
        py_canvas.drawText(text, position, rgba, font, @floatCast(params.scale), draw_mode);
    }

    return py_utils.getPyNone();
}

// Property getters
fn canvas_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(CanvasObject, self_obj);

    if (self.py_canvas) |canvas| {
        return c.PyLong_FromLong(@intCast(canvas.rows()));
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
    return null;
}

fn canvas_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(CanvasObject, self_obj);

    if (self.py_canvas) |canvas| {
        return c.PyLong_FromLong(@intCast(canvas.cols()));
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
    return null;
}

fn canvas_get_image(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(CanvasObject, self_obj);

    if (self.image_ref) |img_ref| {
        c.Py_INCREF(img_ref);
        return img_ref;
    } else {
        py_utils.setValueError("Canvas not initialized", .{});
        return null;
    }
}

// Documentation strings
const canvas_draw_quadratic_bezier_doc =
    \\Draw a quadratic Bézier curve.
    \\
    \\## Parameters
    \\- `p0` (tuple[float, float]): Start point (x, y)
    \\- `p1` (tuple[float, float]): Control point (x, y)
    \\- `p2` (tuple[float, float]): End point (x, y)
    \\- `color` (int, tuple or color object): Color of the curve.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

const canvas_draw_cubic_bezier_doc =
    \\Draw a cubic Bézier curve.
    \\
    \\## Parameters
    \\- `p0` (tuple[float, float]): Start point (x, y)
    \\- `p1` (tuple[float, float]): First control point (x, y)
    \\- `p2` (tuple[float, float]): Second control point (x, y)
    \\- `p3` (tuple[float, float]): End point (x, y)
    \\- `color` (int, tuple or color object): Color of the curve.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

const canvas_draw_spline_polygon_doc =
    \\Draw a smooth spline through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Color of the spline.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

const canvas_fill_spline_polygon_doc =
    \\Fill a smooth spline area through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Fill color.
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

const canvas_draw_arc_doc =
    \\Draw an arc outline.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Arc radius in pixels
    \\- `start_angle` (float): Starting angle in radians (0 = right, π/2 = down, π = left, 3π/2 = up)
    \\- `end_angle` (float): Ending angle in radians
    \\- `color` (int, tuple or color object): Color of the arc.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
    \\
    \\## Notes
    \\- Angles are measured in radians, with 0 pointing right and increasing clockwise
    \\- For a full circle, use start_angle=0 and end_angle=2π
    \\- The arc is drawn from start_angle to end_angle in the positive angular direction
;

const canvas_fill_arc_doc =
    \\Fill an arc (pie slice) area.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Arc radius in pixels
    \\- `start_angle` (float): Starting angle in radians (0 = right, π/2 = down, π = left, 3π/2 = up)
    \\- `end_angle` (float): Ending angle in radians
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
    \\
    \\## Notes
    \\- Creates a filled pie slice from the center to the arc edge
    \\- Angles are measured in radians, with 0 pointing right and increasing clockwise
    \\- For a full circle, use start_angle=0 and end_angle=2π
;

const canvas_draw_text_doc =
    \\Draw text on the canvas.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw
    \\- `position` (tuple[float, float]): Position coordinates (x, y)
    \\- `color` (int, tuple or color object): Text color.
    \\- `font` (BitmapFont, optional): Font object to use for rendering. If `None`, uses BitmapFont.font8x8()
    \\- `scale` (float, optional): Text scale factor (default: 1.0)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.FAST`)
;

pub const canvas_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "fill",
        .meth = @ptrCast(&canvas_fill),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_doc,
        .params = "self, color: Color",
        .returns = "None",
    },
    .{
        .name = "draw_line",
        .meth = @ptrCast(&canvas_draw_line),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_line_doc,
        .params = "self, p1: tuple[float, float], p2: tuple[float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_rectangle",
        .meth = @ptrCast(&canvas_draw_rectangle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_rectangle_doc,
        .params = "self, rect: Rectangle, color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "fill_rectangle",
        .meth = @ptrCast(&canvas_fill_rectangle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_rectangle_doc,
        .params = "self, rect: Rectangle, color: Color, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_polygon",
        .meth = @ptrCast(&canvas_draw_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "fill_polygon",
        .meth = @ptrCast(&canvas_fill_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_circle",
        .meth = @ptrCast(&canvas_draw_circle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_circle_doc,
        .params = "self, center: tuple[float, float], radius: float, color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "fill_circle",
        .meth = @ptrCast(&canvas_fill_circle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_circle_doc,
        .params = "self, center: tuple[float, float], radius: float, color: Color, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_arc",
        .meth = @ptrCast(&canvas_draw_arc),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_arc_doc,
        .params = "self, center: tuple[float, float], radius: float, start_angle: float, end_angle: float, color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "fill_arc",
        .meth = @ptrCast(&canvas_fill_arc),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_arc_doc,
        .params = "self, center: tuple[float, float], radius: float, start_angle: float, end_angle: float, color: Color, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_quadratic_bezier",
        .meth = @ptrCast(&canvas_draw_quadratic_bezier),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_quadratic_bezier_doc,
        .params = "self, p0: tuple[float, float], p1: tuple[float, float], p2: tuple[float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_cubic_bezier",
        .meth = @ptrCast(&canvas_draw_cubic_bezier),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_cubic_bezier_doc,
        .params = "self, p0: tuple[float, float], p1: tuple[float, float], p2: tuple[float, float], p3: tuple[float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_spline_polygon",
        .meth = @ptrCast(&canvas_draw_spline_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_spline_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, width: int = 1, tension: float = 0.5, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "fill_spline_polygon",
        .meth = @ptrCast(&canvas_fill_spline_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_spline_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, tension: float = 0.5, mode: DrawMode = DrawMode.FAST",
        .returns = "None",
    },
    .{
        .name = "draw_text",
        .meth = @ptrCast(&canvas_draw_text),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_text_doc,
        .params = "self, text: str, position: tuple[float, float], color: Color, font: BitmapFont = BitmapFont.font8x8(), scale: float = 1.0, mode: DrawMode = DrawMode.FAST",
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

// Canvas class documentation - keep it simple
const canvas_class_doc = "Canvas for drawing operations on images.";

// Canvas init documentation - detailed explanation
pub const canvas_init_doc =
    \\Create a Canvas for drawing operations on an Image.
    \\
    \\A Canvas provides drawing methods to modify the pixels of an Image. The Canvas
    \\maintains a reference to the parent Image to prevent it from being garbage collected
    \\while drawing operations are in progress.
    \\
    \\## Parameters
    \\- `image` (Image): The Image object to draw on. Must be initialized with dimensions.
    \\
    \\## Examples
    \\```python
    \\# Create an image and get its canvas
    \\img = Image(100, 100, Rgb(255, 255, 255))
    \\canvas = Canvas(img)
    \\
    \\# Draw on the canvas
    \\canvas.fill(Rgb(0, 0, 0))
    \\canvas.draw_circle((50, 50), 20, Rgb(255, 0, 0))
    \\```
    \\
    \\## Notes
    \\- The Canvas holds a reference to the parent Image
    \\- All drawing operations modify the original Image pixels
    \\- Use Image.canvas() method as a convenient way to create a Canvas
;

// Special methods metadata for stub generation
pub const canvas_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, image: Image",
        .returns = "None",
        .doc = canvas_init_doc,
    },
};

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
    .tp_doc = canvas_class_doc,
    .tp_methods = @ptrCast(&canvas_methods),
    .tp_getset = @ptrCast(&canvas_getset),
    .tp_init = canvas_init,
    .tp_new = canvas_new,
};
