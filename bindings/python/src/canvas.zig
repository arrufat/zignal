const std = @import("std");

const zignal = @import("zignal");
pub const Canvas = zignal.Canvas;
const DrawMode = zignal.DrawMode;
const Rgba = zignal.Rgba;
const BitmapFont = zignal.BitmapFont;

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
    const canvas_ptr = allocator.create(Canvas(Rgba)) catch {
        c.Py_DECREF(image_obj.?);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Canvas");
        return -1;
    };

    // Initialize the Canvas
    if (image.image_ptr) |img_ptr| {
        canvas_ptr.* = Canvas(Rgba).init(allocator, img_ptr.*);
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

// Common parsing structure for draw methods
const DrawArgs = struct {
    canvas: *Canvas(Rgba),
    color: Rgba,
    width: u32,
    mode: DrawMode,
};

// Common parsing structure for fill methods
const FillArgs = struct {
    canvas: *Canvas(Rgba),
    color: Rgba,
    mode: DrawMode,
};

// Helper to parse common draw arguments
fn parseDrawArgs(self: *CanvasObject, color_obj: ?*c.PyObject, width: c_long, mode: c_long) !DrawArgs {
    return DrawArgs{
        .canvas = try py_utils.validateNonNull(*Canvas(Rgba), self.canvas_ptr, "Canvas"),
        .color = try py_utils.parseColorToRgba(@ptrCast(color_obj)),
        .width = try py_utils.validateNonNegative(u32, width, "Width"),
        .mode = if (try py_utils.validateRange(u32, mode, 0, 1, "Mode") == 0) .fast else .soft,
    };
}

// Helper to parse common fill arguments
fn parseFillArgs(self: *CanvasObject, color_obj: ?*c.PyObject, mode: c_long) !FillArgs {
    return FillArgs{
        .canvas = try py_utils.validateNonNull(*Canvas(Rgba), self.canvas_ptr, "Canvas"),
        .color = try py_utils.parseColorToRgba(@ptrCast(color_obj)),
        .mode = if (try py_utils.validateRange(u32, mode, 0, 1, "Mode") == 0) .fast else .soft,
    };
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

fn canvas_fill(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    const canvas = py_utils.validateNonNull(*Canvas(Rgba), self.canvas_ptr, "Canvas") catch return null;

    // Parse color argument
    var color_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &color_obj) == 0) {
        return null;
    }

    // Convert color to Rgba
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;

    // Use the stored Canvas directly
    canvas.fill(color);

    return py_utils.returnNone();
}

// Macro-like function to generate draw methods with width parameter
fn makeDrawMethodWithWidth(
    comptime name: []const u8,
    comptime canvas_method: []const u8,
    comptime param_count: usize,
    comptime param_names: [param_count][]const u8,
    comptime param_types: [param_count][]const u8,
    comptime parse_format: []const u8,
    comptime doc: []const u8,
) type {
    _ = canvas_method;
    _ = param_types;
    return struct {
        fn method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const self = @as(*CanvasObject, @ptrCast(self_obj.?));

            // Build kwlist at comptime
            const kwlist = comptime blk: {
                var list: [param_count + 4][*c]const u8 = undefined;
                for (param_names, 0..) |pname, i| {
                    list[i] = pname.ptr;
                }
                list[param_count] = "color";
                list[param_count + 1] = "width";
                list[param_count + 2] = "mode";
                list[param_count + 3] = null;
                break :blk list;
            };

            // Parse arguments - use generic vars array
            var param_objs: [param_count]?*c.PyObject = undefined;
            var color_obj: ?*c.PyObject = undefined;
            var width: c_long = 1;
            var mode: c_long = 0;

            const format = std.fmt.comptimePrint(parse_format ++ "O|ll", .{});

            // Build argument list for parsing
            var parse_args: [param_count + 3]?*anyopaque = undefined;
            inline for (0..param_count) |i| {
                parse_args[i] = @ptrCast(&param_objs[i]);
            }
            parse_args[param_count] = @ptrCast(&color_obj);
            parse_args[param_count + 1] = @ptrCast(&width);
            parse_args[param_count + 2] = @ptrCast(&mode);

            // Call PyArg_ParseTupleAndKeywords with variable arguments
            switch (param_count) {
                1 => {
                    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), parse_args[0], parse_args[1], parse_args[2], parse_args[3]) == 0) {
                        return null;
                    }
                },
                2 => {
                    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), parse_args[0], parse_args[1], parse_args[2], parse_args[3], parse_args[4]) == 0) {
                        return null;
                    }
                },
                3 => {
                    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), parse_args[0], parse_args[1], parse_args[2], parse_args[3], parse_args[4], parse_args[5]) == 0) {
                        return null;
                    }
                },
                else => @compileError("Unsupported param count"),
            }

            // Parse common arguments
            const common = parseDrawArgs(self, color_obj, width, mode) catch return null;

            // Call the appropriate method based on parameter types
            if (comptime std.mem.eql(u8, name, "draw_line")) {
                const p1 = py_utils.parsePointTuple(@ptrCast(param_objs[0])) catch return null;
                const p2 = py_utils.parsePointTuple(@ptrCast(param_objs[1])) catch return null;
                common.canvas.drawLine(p1, p2, common.color, common.width, common.mode);
            } else if (comptime std.mem.eql(u8, name, "draw_rectangle")) {
                const rect = py_utils.parseRectangle(@ptrCast(param_objs[0])) catch return null;
                common.canvas.drawRectangle(rect, common.color, common.width, common.mode);
            } else if (comptime std.mem.eql(u8, name, "draw_polygon")) {
                const points = py_utils.parsePointList(@ptrCast(param_objs[0])) catch return null;
                defer py_utils.freePointList(points);
                common.canvas.drawPolygon(points, common.color, common.width, common.mode);
            } else if (comptime std.mem.eql(u8, name, "draw_circle")) {
                const center = py_utils.parsePointTuple(@ptrCast(param_objs[0])) catch return null;
                const radius = py_utils.validateNonNegative(f32, @as(*f64, @ptrCast(@alignCast(parse_args[1]))).*, "Radius") catch return null;
                common.canvas.drawCircle(center, radius, common.color, common.width, common.mode);
            }

            return py_utils.returnNone();
        }

        const doc_string = doc;
    };
}

// Macro-like function to generate fill methods
fn makeFillMethod(
    comptime name: []const u8,
    comptime canvas_method: []const u8,
    comptime param_count: usize,
    comptime param_names: [param_count][]const u8,
    comptime param_types: [param_count][]const u8,
    comptime parse_format: []const u8,
    comptime doc: []const u8,
    comptime has_error_handling: bool,
) type {
    _ = canvas_method;
    _ = param_types;
    return struct {
        fn method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const self = @as(*CanvasObject, @ptrCast(self_obj.?));

            // Build kwlist at comptime
            const kwlist = comptime blk: {
                var list: [param_count + 3][*c]const u8 = undefined;
                for (param_names, 0..) |pname, i| {
                    list[i] = pname.ptr;
                }
                list[param_count] = "color";
                list[param_count + 1] = "mode";
                list[param_count + 2] = null;
                break :blk list;
            };

            // Parse arguments
            var param_objs: [param_count]?*c.PyObject = undefined;
            var color_obj: ?*c.PyObject = undefined;
            var mode: c_long = 0;

            const format = std.fmt.comptimePrint(parse_format ++ "O|l", .{});

            // Build argument list for parsing
            var parse_args: [param_count + 2]?*anyopaque = undefined;
            inline for (0..param_count) |i| {
                parse_args[i] = @ptrCast(&param_objs[i]);
            }
            parse_args[param_count] = @ptrCast(&color_obj);
            parse_args[param_count + 1] = @ptrCast(&mode);

            // Call PyArg_ParseTupleAndKeywords with variable arguments
            switch (param_count) {
                1 => {
                    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), parse_args[0], parse_args[1], parse_args[2]) == 0) {
                        return null;
                    }
                },
                2 => {
                    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), parse_args[0], parse_args[1], parse_args[2], parse_args[3]) == 0) {
                        return null;
                    }
                },
                else => @compileError("Unsupported param count"),
            }

            // Parse common arguments
            const common = parseFillArgs(self, color_obj, mode) catch return null;

            // Call the appropriate method based on parameter types
            if (comptime std.mem.eql(u8, name, "fill_rectangle")) {
                const rect = py_utils.parseRectangle(@ptrCast(param_objs[0])) catch return null;
                common.canvas.fillRectangle(rect, common.color, common.mode);
            } else if (comptime std.mem.eql(u8, name, "fill_polygon")) {
                const points = py_utils.parsePointList(@ptrCast(param_objs[0])) catch return null;
                defer py_utils.freePointList(points);
                if (has_error_handling) {
                    common.canvas.fillPolygon(points, common.color, common.mode) catch {
                        c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to fill polygon");
                        return null;
                    };
                } else {
                    common.canvas.fillPolygon(points, common.color, common.mode) catch unreachable;
                }
            } else if (comptime std.mem.eql(u8, name, "fill_circle")) {
                const center = py_utils.parsePointTuple(@ptrCast(param_objs[0])) catch return null;
                const radius = py_utils.validateNonNegative(f32, @as(*f64, @ptrCast(@alignCast(parse_args[1]))).*, "Radius") catch return null;
                common.canvas.fillCircle(center, radius, common.color, common.mode);
            }

            return py_utils.returnNone();
        }

        const doc_string = doc;
    };
}

// Generate method instances
const DrawLine = makeDrawMethodWithWidth(
    "draw_line",
    "drawLine",
    2,
    [_][]const u8{ "p1", "p2" },
    [_][]const u8{ "tuple", "tuple" },
    "OO",
    \\Draw a line between two points.
    \\
    \\## Parameters
    \\- `p1` (tuple[float, float]): Starting point coordinates (x, y)
    \\- `p2` (tuple[float, float]): Ending point coordinates (x, y)
    \\- `color` (int, tuple or color object): Color of the line.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    ,
);

const DrawRectangle = makeDrawMethodWithWidth(
    "draw_rectangle",
    "drawRectangle",
    1,
    [_][]const u8{"rect"},
    [_][]const u8{"Rectangle"},
    "O",
    \\Draw a rectangle outline.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Color of the rectangle.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    ,
);

const DrawPolygon = makeDrawMethodWithWidth(
    "draw_polygon",
    "drawPolygon",
    1,
    [_][]const u8{"points"},
    [_][]const u8{"list"},
    "O",
    \\Draw a polygon outline.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Color of the polygon.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    ,
);

const DrawCircle = makeDrawMethodWithWidth(
    "draw_circle",
    "drawCircle",
    2,
    [_][]const u8{ "center", "radius" },
    [_][]const u8{ "tuple", "float" },
    "Od",
    \\Draw a circle outline.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Color of the circle.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
    ,
);

const FillRectangle = makeFillMethod(
    "fill_rectangle",
    "fillRectangle",
    1,
    [_][]const u8{"rect"},
    [_][]const u8{"Rectangle"},
    "O",
    \\Fill a rectangle area.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): Rectangle object defining the bounds
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
,
    false,
);

const FillPolygon = makeFillMethod(
    "fill_polygon",
    "fillPolygon",
    1,
    [_][]const u8{"points"},
    [_][]const u8{"list"},
    "O",
    \\Fill a polygon area.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates forming the polygon
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
,
    true,
);

const FillCircle = makeFillMethod(
    "fill_circle",
    "fillCircle",
    2,
    [_][]const u8{ "center", "radius" },
    [_][]const u8{ "tuple", "float" },
    "Od",
    \\Fill a circle area.
    \\
    \\## Parameters
    \\- `center` (tuple[float, float]): Center coordinates (x, y)
    \\- `radius` (float): Circle radius
    \\- `color` (int, tuple or color object): Fill color.
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
,
    false,
);

// Special methods that need custom handling
fn canvas_draw_quadratic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Parse arguments
    var p0_obj: ?*c.PyObject = undefined;
    var p1_obj: ?*c.PyObject = undefined;
    var p2_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0;

    const kwlist = [_][*c]const u8{ "p0", "p1", "p2", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OOOO|ll", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &p0_obj, &p1_obj, &p2_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    const common = parseDrawArgs(self, color_obj, width, mode) catch return null;

    // Convert arguments
    const p0 = py_utils.parsePointTuple(@ptrCast(p0_obj)) catch return null;
    const p1 = py_utils.parsePointTuple(@ptrCast(p1_obj)) catch return null;
    const p2 = py_utils.parsePointTuple(@ptrCast(p2_obj)) catch return null;

    common.canvas.drawQuadraticBezier(p0, p1, p2, common.color, common.width, common.mode);

    return py_utils.returnNone();
}

fn canvas_draw_cubic_bezier(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Parse arguments
    var p0_obj: ?*c.PyObject = undefined;
    var p1_obj: ?*c.PyObject = undefined;
    var p2_obj: ?*c.PyObject = undefined;
    var p3_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0;

    const kwlist = [_][*c]const u8{ "p0", "p1", "p2", "p3", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OOOOO|ll", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &p0_obj, &p1_obj, &p2_obj, &p3_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    const common = parseDrawArgs(self, color_obj, width, mode) catch return null;

    // Convert arguments
    const p0 = py_utils.parsePointTuple(@ptrCast(p0_obj)) catch return null;
    const p1 = py_utils.parsePointTuple(@ptrCast(p1_obj)) catch return null;
    const p2 = py_utils.parsePointTuple(@ptrCast(p2_obj)) catch return null;
    const p3 = py_utils.parsePointTuple(@ptrCast(p3_obj)) catch return null;

    common.canvas.drawCubicBezier(p0, p1, p2, p3, common.color, common.width, common.mode);

    return py_utils.returnNone();
}

fn canvas_draw_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Parse arguments
    var points_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var tension: f64 = 0.5;
    var mode: c_long = 0;

    const kwlist = [_][*c]const u8{ "points", "color", "width", "tension", "mode", null };
    const format = std.fmt.comptimePrint("OO|ldl", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &points_obj, &color_obj, &width, &tension, &mode) == 0) {
        return null;
    }

    const common = parseDrawArgs(self, color_obj, width, mode) catch return null;
    const tension_val = py_utils.validateRange(f32, tension, 0.0, 1.0, "Tension") catch return null;

    // Parse points
    const points = py_utils.parsePointList(@ptrCast(points_obj)) catch return null;
    defer py_utils.freePointList(points);

    common.canvas.drawSplinePolygon(points, common.color, common.width, tension_val, common.mode);

    return py_utils.returnNone();
}

fn canvas_fill_spline_polygon(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Parse arguments
    var points_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var tension: f64 = 0.5;
    var mode: c_long = 0;

    const kwlist = [_][*c]const u8{ "points", "color", "tension", "mode", null };
    const format = std.fmt.comptimePrint("OO|dl", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &points_obj, &color_obj, &tension, &mode) == 0) {
        return null;
    }

    const common = parseFillArgs(self, color_obj, mode) catch return null;
    const tension_val = py_utils.validateRange(f32, tension, 0.0, 1.0, "Tension") catch return null;

    // Parse points
    const points = py_utils.parsePointList(@ptrCast(points_obj)) catch return null;
    defer py_utils.freePointList(points);

    common.canvas.fillSplinePolygon(points, common.color, tension_val, common.mode) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to fill spline polygon");
        return null;
    };

    return py_utils.returnNone();
}

fn canvas_draw_text(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    const canvas = py_utils.validateNonNull(*Canvas(Rgba), self.canvas_ptr, "Canvas") catch return null;

    // Parse arguments
    var text_obj: ?*c.PyObject = undefined;
    var position_obj: ?*c.PyObject = undefined;
    var font_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var scale: f64 = 1.0;
    var mode: c_long = 0;

    const kwlist = [_][*c]const u8{ "text", "position", "font", "color", "scale", "mode", null };
    const format = std.fmt.comptimePrint("OOOO|dl:draw_text", .{});

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
    const mode_val = py_utils.validateRange(u32, mode, 0, 1, "Mode") catch return null;
    const draw_mode = if (mode_val == 0) DrawMode.fast else DrawMode.soft;

    // Draw the text
    const font = py_utils.validateNonNull(*BitmapFont, font_wrapper.font, "BitmapFont") catch return null;
    canvas.drawText(text, position, font.*, color, @as(f32, @floatCast(scale)), draw_mode);

    return py_utils.returnNone();
}

// Property getters
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
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
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
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
;

const canvas_draw_spline_polygon_doc =
    \\Draw a smooth spline through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Color of the spline.
    \\- `width` (int, optional): Line width in pixels (default: 1)
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
;

const canvas_fill_spline_polygon_doc =
    \\Fill a smooth spline area through polygon points.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinates to interpolate through
    \\- `color` (int, tuple or color object): Fill color.
    \\- `tension` (float, optional): Spline tension (0.0 = angular, 0.5 = smooth, default: 0.5)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
;

const canvas_draw_text_doc =
    \\Draw text on the canvas.
    \\
    \\## Parameters
    \\- `text` (str): Text to draw
    \\- `position` (tuple[float, float]): Position coordinates (x, y)
    \\- `font` (BitmapFont): Font object to use for rendering
    \\- `color` (int, tuple or color object): Text color.
    \\- `scale` (float, optional): Text scale factor (default: 1.0)
    \\- `mode` (`DrawMode`, optional): Drawing mode: `DrawMode.FAST` or `DrawMode.SOFT` (default: `DrawMode.FAST`)
;

const colors = stub_metadata.COLOR_TYPE_LIST;

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
        .meth = @ptrCast(&DrawLine.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = DrawLine.doc_string,
        .params = "self, p1: Tuple[float, float], p2: Tuple[float, float], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_rectangle",
        .meth = @ptrCast(&DrawRectangle.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = DrawRectangle.doc_string,
        .params = "self, rect: Rectangle, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_rectangle",
        .meth = @ptrCast(&FillRectangle.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = FillRectangle.doc_string,
        .params = "self, rect: Rectangle, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_polygon",
        .meth = @ptrCast(&DrawPolygon.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = DrawPolygon.doc_string,
        .params = "self, points: List[Tuple[float, float]], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_polygon",
        .meth = @ptrCast(&FillPolygon.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = FillPolygon.doc_string,
        .params = "self, points: List[Tuple[float, float]], color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "draw_circle",
        .meth = @ptrCast(&DrawCircle.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = DrawCircle.doc_string,
        .params = "self, center: Tuple[float, float], radius: float, color: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
    .{
        .name = "fill_circle",
        .meth = @ptrCast(&FillCircle.method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = FillCircle.doc_string,
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
