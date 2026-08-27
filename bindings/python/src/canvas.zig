const std = @import("std");

const zignal = @import("zignal");
pub const Canvas = zignal.Canvas;
const DrawMode = zignal.DrawMode;
const DrawOptions = zignal.DrawOptions;
const Blending = zignal.Blending;
const Font = zignal.Font;
const Rectangle = zignal.Rectangle;

const color_utils = @import("color_utils.zig");
const enum_utils = @import("enum_utils.zig");
const PyImage = @import("PyImage.zig");
const python = @import("python.zig");
const allocator = python.ctx.allocator;
pub const registerType = python.register;
const c = python.c;
const stub_metadata = @import("stub_metadata.zig");

const Rgba = zignal.Rgba(u8);
const Rgb = zignal.Rgb(u8);
/// A variant canvas type that mirrors PyImage structure.
pub const PyCanvas = struct {
    pub const Variant = union(PyImage.DType) {
        gray: Canvas(u8),
        rgb: Canvas(Rgb),
        rgba: Canvas(Rgba),
    };

    data: Variant,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a PyCanvas from a PyImage.
    pub fn initFromPyImage(alloc: std.mem.Allocator, py_image: *PyImage) Self {
        return .{
            .data = switch (py_image.data) {
                .gray => |img| .{ .gray = Canvas(u8).init(alloc, img) },
                .rgb => |img| .{ .rgb = Canvas(Rgb).init(alloc, img) },
                .rgba => |img| .{ .rgba = Canvas(Rgba).init(alloc, img) },
            },
            .allocator = alloc,
        };
    }

    /// Get the dtype of this canvas.
    pub fn dtype(self: *const Self) PyImage.DType {
        return @as(PyImage.DType, self.data);
    }

    /// Get the number of rows.
    pub fn rows(self: *const Self) usize {
        return switch (self.data) {
            inline else => |canvas| canvas.image.rows,
        };
    }

    /// Get the number of columns.
    pub fn cols(self: *const Self) usize {
        return switch (self.data) {
            inline else => |canvas| canvas.image.cols,
        };
    }

    /// Fill the entire canvas with a color.
    pub fn fill(self: *Self, color: Rgba) void {
        switch (self.data) {
            inline else => |*canvas| canvas.fill(color),
        }
    }

    /// Draw a line.
    pub fn drawLine(self: *Self, p1: anytype, p2: anytype, color: Rgba, width: u32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawLine(p1, p2, color, width, opts),
        }
    }

    /// Draw a rectangle.
    pub fn drawRectangle(self: *Self, rect: anytype, color: Rgba, width: u32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawRectangle(rect, color, width, opts),
        }
    }

    /// Fill a rectangle.
    pub fn fillRectangle(self: *Self, rect: anytype, color: Rgba, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.fillRectangle(rect, color, opts),
        }
    }

    /// Draw a polygon.
    pub fn drawPolygon(self: *Self, points: anytype, color: Rgba, width: u32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawPolygon(points, color, width, opts),
        }
    }

    /// Fill a polygon.
    pub fn fillPolygon(self: *Self, points: anytype, color: Rgba, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.fillPolygon(points, color, opts),
        }
    }

    /// Draw a circle.
    pub fn drawCircle(self: *Self, center: anytype, radius: anytype, color: Rgba, width: u32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawCircle(center, radius, color, width, opts),
        }
    }

    /// Fill a circle.
    pub fn fillCircle(self: *Self, center: anytype, radius: anytype, color: Rgba, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.fillCircle(center, radius, color, opts),
        }
    }

    /// Draw a quadratic Bezier curve.
    pub fn drawQuadraticBezier(self: *Self, p0: anytype, p1: anytype, p2: anytype, color: Rgba, width: u32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawQuadraticBezier(p0, p1, p2, color, width, opts),
        }
    }

    /// Draw a cubic Bezier curve.
    pub fn drawCubicBezier(self: *Self, p0: anytype, p1: anytype, p2: anytype, p3: anytype, color: Rgba, width: u32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawCubicBezier(p0, p1, p2, p3, color, width, opts),
        }
    }

    /// Draw a spline polygon.
    pub fn drawSplinePolygon(self: *Self, points: anytype, color: Rgba, width: u32, tension: f32, opts: DrawOptions) void {
        switch (self.data) {
            inline else => |*canvas| canvas.drawSplinePolygon(points, color, width, tension, opts),
        }
    }

    /// Fill a spline polygon.
    pub fn fillSplinePolygon(self: *Self, points: anytype, color: Rgba, tension: f32, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.fillSplinePolygon(points, color, tension, opts),
        }
    }

    /// Draw an arc.
    pub fn drawArc(self: *Self, center: anytype, radius: f32, start_angle: f32, end_angle: f32, color: Rgba, width: u32, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.drawArc(center, radius, start_angle, end_angle, color, width, opts),
        }
    }

    /// Fill an arc.
    pub fn fillArc(self: *Self, center: anytype, radius: f32, start_angle: f32, end_angle: f32, color: Rgba, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.fillArc(center, radius, start_angle, end_angle, color, opts),
        }
    }

    /// Draw text at `size` pixels, or the font's default size.
    pub fn drawText(self: *Self, text: []const u8, position: anytype, color: Rgba, font: Font, size: ?f32, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.drawText(text, position, color, font, size, opts),
        }
    }

    pub fn drawTextBox(self: *Self, text: []const u8, box: zignal.Rectangle(f32), color: Rgba, font: Font, size: ?f32, layout: zignal.TextLayout, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.drawTextBox(text, box, color, font, size, layout, opts),
        }
    }

    pub fn drawTextOutline(self: *Self, text: []const u8, position: anytype, color: Rgba, font: Font, size: ?f32, width: f32, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.drawTextOutline(text, position, color, font, size, width, opts),
        }
    }

    pub fn drawTextBoxOutline(self: *Self, text: []const u8, box: zignal.Rectangle(f32), color: Rgba, font: Font, size: ?f32, width: f32, layout: zignal.TextLayout, opts: DrawOptions) !void {
        switch (self.data) {
            inline else => |*canvas| try canvas.drawTextBoxOutline(text, box, color, font, size, width, layout, opts),
        }
    }

    /// Draw another image.
    pub fn drawImage(self: *Self, source: *PyImage, position: anytype, source_rect: ?Rectangle(u32), blend_mode: Blending) void {
        switch (self.data) {
            inline else => |*canvas| switch (source.data) {
                inline else => |img| canvas.drawImage(img, position, source_rect, blend_mode),
            },
        }
    }

    /// Dispatch an operation to the underlying canvas variant.
    pub fn dispatch(self: *Self, ctx: anytype, comptime func: anytype) @TypeOf(@call(.auto, func, .{@as(*Canvas(u8), undefined)} ++ ctx)) {
        return switch (self.data) {
            .gray => |*cv| @call(.auto, func, .{cv} ++ ctx),
            .rgb => |*cv| @call(.auto, func, .{cv} ++ ctx),
            .rgba => |*cv| @call(.auto, func, .{cv} ++ ctx),
        };
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
    \\- Default mode is SOFT; pass FAST for hard edges and maximum performance
;

// Per-value documentation for stub generation
pub const draw_mode_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "FAST", .doc = "Fast rendering with hard edges" },
    .{ .name = "SOFT", .doc = "Antialiased rendering with smooth edges" },
};

pub const text_align_doc =
    \\Horizontal alignment of each line inside a text box.
    \\
    \\## Attributes
    \\- `LEFT` (int): Lines start at the box's left edge (value: 0)
    \\- `CENTER` (int): Lines are centered in the box (value: 1)
    \\- `RIGHT` (int): Lines end at the box's right edge (value: 2)
;

pub const text_align_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "LEFT", .doc = "Lines start at the left edge" },
    .{ .name = "CENTER", .doc = "Lines are centered" },
    .{ .name = "RIGHT", .doc = "Lines end at the right edge" },
};

pub const vertical_align_doc =
    \\Vertical placement of the block of lines inside a text box.
    \\
    \\## Attributes
    \\- `TOP` (int): The block starts at the box's top edge (value: 0)
    \\- `MIDDLE` (int): The block is centered in the box (value: 1)
    \\- `BOTTOM` (int): The block ends at the box's bottom edge (value: 2)
;

pub const vertical_align_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "TOP", .doc = "The block starts at the top edge" },
    .{ .name = "MIDDLE", .doc = "The block is centered" },
    .{ .name = "BOTTOM", .doc = "The block ends at the bottom edge" },
};

/// What every draw method's `mode` kwarg defaults to: antialiased, like Zig's `DrawOptions.soft`.
const default_mode: c_long = @backingInt(DrawMode.soft);

/// Parses the shared `mode` + `blending` kwargs into a DrawOptions (`blending=None` disables blending).
/// A missing `blending` follows the mode's Zig preset: `.soft` composites, `.fast` overwrites.
fn parseDrawOptions(mode: c_long, blending: ?*c.PyObject) !DrawOptions {
    const draw_mode = try enum_utils.longToEnum(DrawMode, mode);
    const preset: DrawOptions = switch (draw_mode) {
        .fast => .fast,
        .soft => .soft,
    };
    return .{
        .mode = draw_mode,
        .blending = try enum_utils.pyToEnumOpt(Blending, blending, .{ .missing = preset.blending, .none = .none }),
    };
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

    const self: ?*CanvasObject = @ptrCast(c.PyType_GenericAlloc(type_obj, 0));
    if (self) |obj| {
        obj.image_ref = null;
        obj.py_canvas = null;
    }
    return @ptrCast(self);
}

fn canvas_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = python.safeCast(CanvasObject, self_obj);

    // Parse arguments - expect an Image object
    const Params = struct {
        image: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    // Import the image module to get the ImageType
    const image_module = @import("image.zig");

    // Check if it's an Image instance
    if (c.PyObject_IsInstance(params.image, @ptrCast(&image_module.ImageType)) <= 0) {
        python.setTypeError("Image instance", params.image);
        return -1;
    }

    const image: *image_module.ImageObject = @ptrCast(params.image.?);

    // Keep reference to parent Image to prevent garbage collection
    c.Py_IncRef(params.image.?);
    self.image_ref = params.image;

    // Initialize based on image format
    if (image.py_image) |pimg| {
        const py_canvas = allocator.create(PyCanvas) catch {
            c.Py_DecRef(params.image.?);
            python.setMemoryError("PyCanvas");
            return -1;
        };
        py_canvas.* = PyCanvas.initFromPyImage(allocator, pimg);
        self.py_canvas = py_canvas;
    } else {
        c.Py_DecRef(params.image.?);
        python.setValueError("Image not initialized", .{});
        return -1;
    }

    return 0;
}

fn canvas_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = python.safeCast(CanvasObject, self_obj);

    // Free the PyCanvas
    if (self.py_canvas) |ptr| {
        allocator.destroy(ptr);
    }

    // Release reference to parent Image
    if (self.image_ref) |ref| {
        c.Py_DecRef(ref);
    }

    python.typeOf(self_obj).*.tp_free.?(self_obj);
}

fn canvas_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(CanvasObject, self_obj);

    if (self.py_canvas) |canvas| {
        var buffer: [64]u8 = undefined;
        const dtype_str = switch (canvas.dtype()) {
            .gray => "Gray",
            .rgb => "Rgb",
            .rgba => "Rgba",
        };
        const formatted = std.fmt.bufPrintSentinel(&buffer, "Canvas({d}x{d}, dtype={s})", .{ canvas.rows(), canvas.cols(), dtype_str }, 0) catch return null;
        return python.create(formatted);
    } else {
        return python.create("Canvas(uninitialized)");
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
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    // Parse color argument
    const Params = struct {
        color: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    // Parse color and fill
    const rgba = color_utils.parseColor(Rgba, @ptrCast(params.color)) catch return null;
    canvas.fill(rgba);

    return python.none();
}

// Draw methods
fn canvas_draw_line(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        p1: ?*c.PyObject,
        p2: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const p1 = python.parse(zignal.Point(2, f32), params.p1) catch return null;
    const p2 = python.parse(zignal.Point(2, f32), params.p2) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawLine(p1, p2, rgba, width_val, opts);

    return python.none();
}

const canvas_draw_line_doc =
    \\Draw a line between two points.
    \\
    \\## Parameters
    \\- `p1` (tuple[float, float]): Starting point coordinates (x, y)
    \\- `p2` (tuple[float, float]): Ending point coordinates (x, y)
    \\- `color` (int, tuple or color object): Color of the line.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

fn canvas_draw_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        rect: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = python.parse(zignal.Rectangle(f32), params.rect) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawRectangle(rect, rgba, width_val, opts);

    return python.none();
}

const canvas_draw_rectangle_doc =
    \\Draw a rectangle outline.
    \\
    \\## Parameters
    \\- `rect` (Rectangle | tuple[float, float, float, float]): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Color of the rectangle.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

fn canvas_draw_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const points = python.parse([]zignal.Point(2, f32), params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawPolygon(points, rgba, width_val, opts);

    return python.none();
}

const canvas_draw_polygon_doc =
    \\Draw a polygon outline.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Color of the polygon.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

fn canvas_draw_circle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const center = python.parse(zignal.Point(2, f32), params.center) catch return null;
    const radius = python.validateNonNegative(f32, params.radius, "Radius") catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawCircle(center, radius, rgba, width_val, opts);

    return python.none();
}

const canvas_draw_circle_doc =
    \\Draw a circle outline.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Color of the circle.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

// Fill methods
fn canvas_fill_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        rect: ?*c.PyObject,
        color: ?*c.PyObject,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = python.parse(zignal.Rectangle(f32), params.rect) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.fillRectangle(rect, rgba, opts);

    return python.none();
}

const canvas_fill_rectangle_doc =
    \\Fill a rectangle area.
    \\
    \\## Parameters
    \\- `rect` (Rectangle | tuple[float, float, float, float]): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

fn canvas_draw_image(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        image: ?*c.PyObject,
        position: ?*c.PyObject,
        source_rect: ?*c.PyObject = null,
        blend_mode: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const pos = python.parse(zignal.Point(2, f32), params.position) catch return null;

    const image_module = @import("image.zig");
    if (c.PyObject_IsInstance(params.image, @ptrCast(&image_module.ImageType)) <= 0) {
        python.setTypeError("Image instance", params.image);
        return null;
    }

    const image_obj = python.safeCast(image_module.ImageObject, params.image);
    const py_image_ptr = image_obj.py_image orelse {
        python.setValueError("Source image not initialized", .{});
        return null;
    };

    var rect_opt: ?Rectangle(u32) = null;
    if (params.source_rect) |rect_obj| {
        if (rect_obj != c.Py_None()) {
            rect_opt = python.parse(Rectangle(u32), rect_obj) catch return null;
        }
    }

    const blend_mode = enum_utils.pyToEnumOpt(Blending, params.blend_mode, .{ .missing = .normal, .none = .none }) catch return null;

    canvas.drawImage(py_image_ptr, pos, rect_opt, blend_mode);

    return python.none();
}

const canvas_draw_image_doc =
    \\Composite another image onto this
    \\
    \\## Parameters
    \\- `image` (Image): Source image to draw.
    \\- `position` (tuple[float, float]): Top-left destination position `(x, y)`.
    \\- `source_rect` (Rectangle | tuple[float, float, float, float] | None, optional): Optional source rectangle in
    \\  source image coordinates. When omitted or `None`, the entire image is used.
    \\- `blend_mode` (Blending | None, optional): Blending mode applied when drawing RGBA sources. Defaults to `Blending.NORMAL`; use `None` or `Blending.NONE` for direct copy.
    \\
    \\## Notes
    \\- Alpha blending is handled automatically based on the source image dtype; non-RGBA images always copy pixels directly.
    \\- Drawing is clipped to the canvas bounds.
;

fn canvas_fill_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const points = python.parse([]zignal.Point(2, f32), params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.fillPolygon(points, rgba, opts) catch {
        python.setRuntimeError("Failed to fill polygon", .{});
        return null;
    };

    return python.none();
}

const canvas_fill_polygon_doc =
    \\Fill a polygon area.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

fn canvas_fill_circle(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        color: ?*c.PyObject,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const center = python.parse(zignal.Point(2, f32), params.center) catch return null;
    const radius = python.validateNonNegative(f32, params.radius, "Radius") catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.fillCircle(center, radius, rgba, opts);

    return python.none();
}

const canvas_fill_circle_doc =
    \\Fill a circle area.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

// Special methods that need custom handling
fn canvas_draw_quadratic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        p0: ?*c.PyObject,
        p1: ?*c.PyObject,
        p2: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const p0 = python.parse(zignal.Point(2, f32), params.p0) catch return null;
    const p1 = python.parse(zignal.Point(2, f32), params.p1) catch return null;
    const p2 = python.parse(zignal.Point(2, f32), params.p2) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawQuadraticBezier(p0, p1, p2, rgba, width_val, opts);

    return python.none();
}

fn canvas_draw_cubic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        p0: ?*c.PyObject,
        p1: ?*c.PyObject,
        p2: ?*c.PyObject,
        p3: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const p0 = python.parse(zignal.Point(2, f32), params.p0) catch return null;
    const p1 = python.parse(zignal.Point(2, f32), params.p1) catch return null;
    const p2 = python.parse(zignal.Point(2, f32), params.p2) catch return null;
    const p3 = python.parse(zignal.Point(2, f32), params.p3) catch return null;
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawCubicBezier(p0, p1, p2, p3, rgba, width_val, opts);

    return python.none();
}

fn canvas_draw_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        width: c_long = 1,
        tension: f64 = 0.5,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const points = python.parse([]zignal.Point(2, f32), params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const tension_val = python.validateRange(f32, params.tension, 0.0, 1.0, "Tension") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawSplinePolygon(points, rgba, width_val, tension_val, opts);

    return python.none();
}

fn canvas_fill_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        points: ?*c.PyObject,
        color: ?*c.PyObject,
        tension: f64 = 0.5,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const points = python.parse([]zignal.Point(2, f32), params.points) catch return null;
    defer allocator.free(points);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const tension_val = python.validateRange(f32, params.tension, 0.0, 1.0, "Tension") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.fillSplinePolygon(points, rgba, tension_val, opts) catch {
        python.setRuntimeError("Failed to fill spline polygon", .{});
        return null;
    };

    return python.none();
}

fn canvas_draw_arc(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        color: ?*c.PyObject,
        width: c_long = 1,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const center = python.parse(zignal.Point(2, f32), params.center) catch return null;
    const radius_val: f32 = @floatCast(params.radius);
    const start_angle_val: f32 = @floatCast(params.start_angle);
    const end_angle_val: f32 = @floatCast(params.end_angle);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const width_val = python.validateNonNegative(u32, params.width, "Width") catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.drawArc(center, radius_val, start_angle_val, end_angle_val, rgba, width_val, opts) catch {
        python.setRuntimeError("Failed to draw arc", .{});
        return null;
    };

    return python.none();
}

fn canvas_fill_arc(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        center: ?*c.PyObject,
        radius: f64,
        start_angle: f64,
        end_angle: f64,
        color: ?*c.PyObject,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const center = python.parse(zignal.Point(2, f32), params.center) catch return null;
    // Allow negative radius - the Zig library will handle it gracefully (no-op)
    const radius_val: f32 = @floatCast(params.radius);
    const start_angle_val: f32 = @floatCast(params.start_angle);
    const end_angle_val: f32 = @floatCast(params.end_angle);
    const rgba = color_utils.parseColor(Rgba, params.color) catch return null;
    const opts = parseDrawOptions(params.mode, params.blending) catch return null;

    canvas.fillArc(center, radius_val, start_angle_val, end_angle_val, rgba, opts) catch {
        python.setRuntimeError("Failed to fill arc", .{});
        return null;
    };

    return python.none();
}

/// The arguments every text method shares, parsed from their Python objects.
const TextArgs = struct {
    text: []const u8,
    rgba: Rgba,
    font: *zignal.Font,
    size: ?f32,
    opts: DrawOptions,

    /// `params` is the method's parsed `Params` struct; only the shared fields are read.
    fn parse(params: anytype) ?TextArgs {
        const rgba = color_utils.parseColor(Rgba, @ptrCast(params.color)) catch return null;
        const opts = parseDrawOptions(params.mode, params.blending) catch return null;

        const font_module = @import("font.zig");
        const font_obj = if (params.font == null or params.font == c.Py_None()) font_module.font8x8Object() orelse return null else params.font;
        if (c.PyObject_IsInstance(font_obj, @ptrCast(&font_module.FontType)) <= 0) {
            python.setTypeError("Font instance or None", font_obj);
            return null;
        }
        const font = python.unwrap(font_module.FontObject, "font", font_obj, "Font") orelse return null;
        const size: ?f32 = if (params.size == null or params.size == c.Py_None()) null else python.parse(f32, params.size) catch return null;
        return .{ .text = std.mem.span(params.text), .rgba = rgba, .font = font, .size = size, .opts = opts };
    }
};

/// A `TextLayout` from the keyword arguments of the box methods.
fn parseTextLayout(params: anytype) !zignal.TextLayout {
    return .{
        .halign = try enum_utils.longToEnum(zignal.TextAlign, params.halign),
        .valign = try enum_utils.longToEnum(zignal.VerticalAlign, params.valign),
        .wrap = params.wrap != 0,
        .line_spacing = @floatCast(params.line_spacing),
        .letter_spacing = @floatCast(params.letter_spacing),
    };
}

fn canvas_draw_text(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        text: [*c]const u8,
        position: ?*c.PyObject,
        color: ?*c.PyObject,
        font: ?*c.PyObject = null,
        size: ?*c.PyObject = null,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const position = python.parse(zignal.Point(2, f32), params.position) catch return null;
    const t = TextArgs.parse(params) orelse return null;

    canvas.drawText(t.text, position, t.rgba, t.font.*, t.size, t.opts) catch {
        python.setRuntimeError("Failed to draw text", .{});
        return null;
    };

    return python.none();
}

fn canvas_draw_text_box(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        text: [*c]const u8,
        rect: ?*c.PyObject,
        color: ?*c.PyObject,
        font: ?*c.PyObject = null,
        size: ?*c.PyObject = null,
        halign: c_long = 0,
        valign: c_long = 0,
        wrap: c_int = 0,
        line_spacing: f64 = 1,
        letter_spacing: f64 = 0,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = python.parse(zignal.Rectangle(f32), params.rect) catch return null;
    const t = TextArgs.parse(params) orelse return null;
    const layout = parseTextLayout(params) catch return null;

    canvas.drawTextBox(t.text, rect, t.rgba, t.font.*, t.size, layout, t.opts) catch {
        python.setRuntimeError("Failed to draw text", .{});
        return null;
    };

    return python.none();
}

fn canvas_draw_text_outline(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        text: [*c]const u8,
        position: ?*c.PyObject,
        color: ?*c.PyObject,
        width: f64,
        font: ?*c.PyObject = null,
        size: ?*c.PyObject = null,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const position = python.parse(zignal.Point(2, f32), params.position) catch return null;
    const width = python.validateNonNegative(f32, params.width, "Width") catch return null;
    const t = TextArgs.parse(params) orelse return null;

    canvas.drawTextOutline(t.text, position, t.rgba, t.font.*, t.size, width, t.opts) catch {
        python.setRuntimeError("Failed to draw text", .{});
        return null;
    };

    return python.none();
}

fn canvas_draw_text_box_outline(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;

    const Params = struct {
        text: [*c]const u8,
        rect: ?*c.PyObject,
        color: ?*c.PyObject,
        width: f64,
        font: ?*c.PyObject = null,
        size: ?*c.PyObject = null,
        halign: c_long = 0,
        valign: c_long = 0,
        wrap: c_int = 0,
        line_spacing: f64 = 1,
        letter_spacing: f64 = 0,
        mode: c_long = default_mode,
        blending: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = python.parse(zignal.Rectangle(f32), params.rect) catch return null;
    const width = python.validateNonNegative(f32, params.width, "Width") catch return null;
    const t = TextArgs.parse(params) orelse return null;
    const layout = parseTextLayout(params) catch return null;

    canvas.drawTextBoxOutline(t.text, rect, t.rgba, t.font.*, t.size, width, layout, t.opts) catch {
        python.setRuntimeError("Failed to draw text", .{});
        return null;
    };

    return python.none();
}

// Property getters
fn canvas_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;
    return python.create(canvas.rows());
}

fn canvas_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const canvas = python.unwrap(CanvasObject, "py_canvas", self_obj, "Canvas") orelse return null;
    return python.create(canvas.cols());
}

fn canvas_get_image(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(CanvasObject, self_obj);
    python.ensureInitialized(self, "image_ref", "Canvas not initialized") catch return null;

    const img_ref = self.image_ref.?;
    c.Py_IncRef(img_ref);
    return img_ref;
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
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
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
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

const canvas_draw_spline_polygon_doc =
    \\Draw a smooth spline through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Color of the spline.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

const canvas_fill_spline_polygon_doc =
    \\Fill a smooth spline area through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Fill color.
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
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
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
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
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
    \\
    \\## Notes
    \\- Creates a filled pie slice from the center to the arc edge
    \\- Angles are measured in radians, with 0 pointing right and increasing clockwise
    \\- For a full circle, use start_angle=0 and end_angle=2π
;

const canvas_draw_text_doc =
    \\Draw text with its top-left corner at `position`.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw; `\n` starts a new line
    \\- `position` (tuple[float, float]): Position coordinates (x, y)
    \\- `color` (int, tuple or color object): Text color.
    \\- `font` (Font, optional): Font to render with. If `None`, uses `Font.font8x8()`
    \\- `size` (float, optional): Font size in pixels: the em height for TrueType fonts, the character
    \\  height for bitmap fonts. Defaults to the bitmap font's native size, or 16 for TrueType fonts
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

const canvas_draw_text_box_doc =
    \\Draw text laid out inside `rect`: wrapped to its width when `wrap` is set, each line
    \\aligned horizontally with `halign` and the block vertically with `valign`. Text that
    \\does not fit is clipped by the image only, not the rectangle.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw; `\n` always starts a new line
    \\- `rect` (Rectangle | tuple[float, float, float, float]): The box, as (left, top, right, bottom)
    \\- `color` (int, tuple or color object): Text color.
    \\- `font` (Font, optional): Font to render with. If `None`, uses `Font.font8x8()`
    \\- `size` (float, optional): Font size in pixels, as in `draw_text`
    \\- `halign` (`TextAlign`, optional): Horizontal alignment of each line (default: `TextAlign.LEFT`)
    \\- `valign` (`VerticalAlign`, optional): Vertical placement of the block (default: `VerticalAlign.TOP`)
    \\- `wrap` (bool, optional): Break lines at spaces to fit the width; words wider than the box break
    \\  between characters (default: False)
    \\- `line_spacing` (float, optional): Multiplier on the font's line height (default: 1.0)
    \\- `letter_spacing` (float, optional): Extra pixels between glyphs; negative tightens (default: 0.0)
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
    \\
    \\## Examples
    \\```python
    \\canvas.draw_text_box(caption, (10, 10, 310, 90), (255, 255, 255), font, size=18,
    \\                     halign=TextAlign.CENTER, valign=VerticalAlign.MIDDLE, wrap=True)
    \\```
;

const canvas_draw_text_outline_doc =
    \\Draw text as outlines: each glyph's contour stroked `width` pixels wide with round joins,
    \\instead of filled. Bitmap fonts have no outlines and get a halo of that diameter; draw
    \\the text over it with `draw_text` for a readable label.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw; `\n` starts a new line
    \\- `position` (tuple[float, float]): Position coordinates (x, y) of the top-left corner
    \\- `color` (int, tuple or color object): Stroke color.
    \\- `width` (float): Stroke width in pixels
    \\- `font` (Font, optional): Font to render with. If `None`, uses `Font.font8x8()`
    \\- `size` (float, optional): Font size in pixels, as in `draw_text`
    \\- `mode` (`DrawMode`, optional): Drawing mode (default: `DrawMode.SOFT`, antialiased)
    \\- `blending` (`Blending` | None, optional): Blend mode for compositing (default: `Blending.NORMAL` for `DrawMode.SOFT`, `Blending.NONE` for `DrawMode.FAST`; `None` disables blending)
;

const canvas_draw_text_box_outline_doc =
    \\`draw_text_box` stroking the glyphs as `draw_text_outline` does.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw
    \\- `rect` (Rectangle | tuple[float, float, float, float]): The box, as (left, top, right, bottom)
    \\- `color` (int, tuple or color object): Stroke color.
    \\- `width` (float): Stroke width in pixels
    \\- `font`, `size`, `halign`, `valign`, `wrap`, `line_spacing`, `letter_spacing`, `mode`, `blending`: as in `draw_text_box`
;

pub const canvas_methods_metadata = [_]python.MethodWithMetadata{
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
        .params = "self, p1: tuple[float, float], p2: tuple[float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_rectangle",
        .meth = @ptrCast(&canvas_draw_rectangle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_rectangle_doc,
        .params = "self, rect: Rectangle | tuple[float, float, float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "fill_rectangle",
        .meth = @ptrCast(&canvas_fill_rectangle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_rectangle_doc,
        .params = "self, rect: Rectangle | tuple[float, float, float, float], color: Color, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_polygon",
        .meth = @ptrCast(&canvas_draw_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "fill_polygon",
        .meth = @ptrCast(&canvas_fill_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_image",
        .meth = @ptrCast(&canvas_draw_image),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_image_doc,
        .params = "self, image: Image, position: tuple[float, float], source_rect: Rectangle | tuple[float, float, float, float] | None = None, blend_mode: Blending | None = Blending.NORMAL",
        .returns = "None",
    },
    .{
        .name = "draw_circle",
        .meth = @ptrCast(&canvas_draw_circle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_circle_doc,
        .params = "self, center: tuple[float, float], radius: float, color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "fill_circle",
        .meth = @ptrCast(&canvas_fill_circle),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_circle_doc,
        .params = "self, center: tuple[float, float], radius: float, color: Color, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_arc",
        .meth = @ptrCast(&canvas_draw_arc),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_arc_doc,
        .params = "self, center: tuple[float, float], radius: float, start_angle: float, end_angle: float, color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "fill_arc",
        .meth = @ptrCast(&canvas_fill_arc),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_arc_doc,
        .params = "self, center: tuple[float, float], radius: float, start_angle: float, end_angle: float, color: Color, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_quadratic_bezier",
        .meth = @ptrCast(&canvas_draw_quadratic_bezier),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_quadratic_bezier_doc,
        .params = "self, p0: tuple[float, float], p1: tuple[float, float], p2: tuple[float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_cubic_bezier",
        .meth = @ptrCast(&canvas_draw_cubic_bezier),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_cubic_bezier_doc,
        .params = "self, p0: tuple[float, float], p1: tuple[float, float], p2: tuple[float, float], p3: tuple[float, float], color: Color, width: int = 1, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_spline_polygon",
        .meth = @ptrCast(&canvas_draw_spline_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_spline_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, width: int = 1, tension: float = 0.5, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "fill_spline_polygon",
        .meth = @ptrCast(&canvas_fill_spline_polygon),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_fill_spline_polygon_doc,
        .params = "self, points: list[tuple[float, float]], color: Color, tension: float = 0.5, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_text",
        .meth = @ptrCast(&canvas_draw_text),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_text_doc,
        .params = "self, text: str, position: tuple[float, float], color: Color, font: Font | None = None, size: float | None = None, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_text_box",
        .meth = @ptrCast(&canvas_draw_text_box),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_text_box_doc,
        .params = "self, text: str, rect: Rectangle | tuple[float, float, float, float], color: Color, font: Font | None = None, size: float | None = None, halign: TextAlign = TextAlign.LEFT, valign: VerticalAlign = VerticalAlign.TOP, wrap: bool = False, line_spacing: float = 1.0, letter_spacing: float = 0.0, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_text_outline",
        .meth = @ptrCast(&canvas_draw_text_outline),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_text_outline_doc,
        .params = "self, text: str, position: tuple[float, float], color: Color, width: float, font: Font | None = None, size: float | None = None, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
    .{
        .name = "draw_text_box_outline",
        .meth = @ptrCast(&canvas_draw_text_box_outline),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_text_box_outline_doc,
        .params = "self, text: str, rect: Rectangle | tuple[float, float, float, float], color: Color, width: float, font: Font | None = None, size: float | None = None, halign: TextAlign = TextAlign.LEFT, valign: VerticalAlign = VerticalAlign.TOP, wrap: bool = False, line_spacing: float = 1.0, letter_spacing: float = 0.0, mode: DrawMode = DrawMode.SOFT, blending: Blending | None = ...",
        .returns = "None",
    },
};

var canvas_methods = python.toPyMethodDefArray(&canvas_methods_metadata);

pub const canvas_properties_metadata = [_]python.PropertyWithMetadata{
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

var canvas_getset = python.toPyGetSetDefArray(&canvas_properties_metadata);

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
    \\fill(Rgb(0, 0, 0))
    \\draw_circle((50, 50), 20, Rgb(255, 0, 0))
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

pub var CanvasType = python.buildTypeObject(.{
    .name = "zignal.Canvas",
    .basicsize = @sizeOf(CanvasObject),
    .doc = canvas_class_doc,
    .methods = @ptrCast(&canvas_methods),
    .getset = @ptrCast(&canvas_getset),
    .new = canvas_new,
    .init = canvas_init,
    .dealloc = canvas_dealloc,
    .repr = canvas_repr,
});
