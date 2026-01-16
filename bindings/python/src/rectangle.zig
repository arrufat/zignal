const std = @import("std");

const zignal = @import("zignal");

const python = @import("python.zig");
const c = python.c;
const stub_metadata = @import("stub_metadata.zig");

const Rectangle = zignal.Rectangle(f64);

pub const RectangleObject = extern struct {
    ob_base: c.PyObject,
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
};

// Using genericNew helper for standard object creation
const rectangle_new = python.genericNew(RectangleObject);

fn rectangle_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const Params = struct {
        left: f64,
        top: f64,
        right: f64,
        bottom: f64,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    if (params.right < params.left) {
        python.setValueError("Right must be greater than or equal to left", .{});
        return -1;
    }
    if (params.bottom < params.top) {
        python.setValueError("Bottom must be greater than or equal to top", .{});
        return -1;
    }

    const self = python.safeCast(RectangleObject, self_obj);
    self.left = params.left;
    self.top = params.top;
    self.right = params.right;
    self.bottom = params.bottom;
    return 0;
}

// Using genericDealloc since there's no heap allocation to clean up
const rectangle_dealloc = python.genericDealloc(RectangleObject, null);

fn rectangle_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(RectangleObject, self_obj);

    var buffer: [128]u8 = undefined;
    const formatted = std.fmt.bufPrintZ(&buffer, "Rectangle({d:.2}, {d:.2}, {d:.2}, {d:.2})", .{ self.left, self.top, self.right, self.bottom }) catch return null;
    return c.PyUnicode_FromString(formatted.ptr);
}

// Class method: init_center
const rectangle_init_center_doc =
    \\Create a Rectangle from center coordinates.
    \\
    \\## Parameters
    \\- `x` (float): Center x coordinate
    \\- `y` (float): Center y coordinate
    \\- `width` (float): Rectangle width
    \\- `height` (float): Rectangle height
    \\
    \\## Examples
    \\```python
    \\# Create a 100x50 rectangle centered at (50, 50)
    \\rect = Rectangle.init_center(50, 50, 100, 50)
    \\# This creates Rectangle(0, 25, 100, 75)
    \\```
;

fn rectangle_init_center(_: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { x: f64, y: f64, width: f64, height: f64 };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    _ = python.validatePositive(f64, params.width, "Width") catch return null;
    _ = python.validatePositive(f64, params.height, "Height") catch return null;
    const rect: Rectangle = .initCenter(params.x, params.y, params.width, params.height);
    return python.create(rect);
}

// Instance methods
const rectangle_is_empty_doc =
    \\Check if the rectangle is ill-formed (empty).
    \\
    \\A rectangle is considered empty if its left >= right or top >= bottom.
    \\
    \\## Examples
    \\```python
    \\rect1 = Rectangle(0, 0, 100, 100)
    \\print(rect1.is_empty())  # False
    \\
    \\rect2 = Rectangle(100, 100, 100, 100)
    \\print(rect2.is_empty())  # True
    \\```
;

fn rectangle_is_empty(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.isEmpty());
}

const rectangle_area_doc =
    \\Calculate the area of the rectangle.
    \\
    \\## Examples
    \\```python
    \\rect = Rectangle(0, 0, 100, 50)
    \\print(rect.area())  # 5000.0
    \\```
;

fn rectangle_area(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.area());
}

const rectangle_contains_doc =
    \\Check if a point is inside the rectangle.
    \\
    \\Uses exclusive bounds for right and bottom edges.
    \\
    \\## Parameters
    \\- `point` (tuple[float, float]): (x, y) coordinates of the point to check.
    \\
    \\## Examples
    \\```python
    \\rect = Rectangle(0, 0, 100, 100)
    \\print(rect.contains((50, 50)))   # True - inside
    \\print(rect.contains((100, 50)))  # False - on right edge (exclusive)
    \\print(rect.contains((150, 50)))  # False - outside
    \\```
;

fn rectangle_contains(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { point: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const p = python.parse(zignal.Point(2, f64), params.point) catch return null;
    return python.create(rect.contains(p));
}

const rectangle_center_doc =
    \\Get the center of the rectangle as (x, y).
    \\
    \\## Returns
    \\- `tuple[float, float]`: Center coordinates `(x, y)`
;

fn rectangle_center(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const p = rect.center();
    return c.Py_BuildValue("(dd)", p[0], p[1]);
}

const rectangle_corner_doc =
    \\Return a rectangle corner as (x, y).
;

fn rectangle_top_left(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const p = rect.topLeft();
    return c.Py_BuildValue("(dd)", p[0], p[1]);
}

fn rectangle_top_right(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const p = rect.topRight();
    return c.Py_BuildValue("(dd)", p[0], p[1]);
}

fn rectangle_bottom_left(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const p = rect.bottomLeft();
    return c.Py_BuildValue("(dd)", p[0], p[1]);
}

fn rectangle_bottom_right(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const p = rect.bottomRight();
    return c.Py_BuildValue("(dd)", p[0], p[1]);
}

const rectangle_grow_doc =
    \\Create a new rectangle expanded by the given amount.
    \\
    \\## Parameters
    \\- `amount` (float): Amount to expand each border by
    \\
    \\## Examples
    \\```python
    \\rect = Rectangle(50, 50, 100, 100)
    \\grown = rect.grow(10)
    \\# Creates Rectangle(40, 40, 110, 110)
    \\```
;

fn rectangle_grow(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { amount: f64 };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.grow(params.amount));
}

const rectangle_shrink_doc =
    \\Create a new rectangle shrunk by the given amount.
    \\
    \\## Parameters
    \\- `amount` (float): Amount to shrink each border by
    \\
    \\## Examples
    \\```python
    \\rect = Rectangle(40, 40, 110, 110)
    \\shrunk = rect.shrink(10)
    \\# Creates Rectangle(50, 50, 100, 100)
    \\```
;

fn rectangle_shrink(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { amount: f64 };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.shrink(params.amount));
}

const rectangle_translate_doc =
    \\Create a new rectangle translated by (dx, dy).
    \\
    \\## Parameters
    \\- `dx` (float): Horizontal translation
    \\- `dy` (float): Vertical translation
    \\
    \\## Returns
    \\- `Rectangle`: A new rectangle shifted by the offsets
;

fn rectangle_translate(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { dx: f64, dy: f64 };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.translate(params.dx, params.dy));
}

const rectangle_clip_doc =
    \\Return a new rectangle clipped to the given bounds.
    \\
    \\## Parameters
    \\- `bounds` (Rectangle | tuple[float, float, float, float]): Rectangle to clip against
    \\
    \\## Returns
    \\- `Rectangle`: The clipped rectangle (may be empty)
;

fn rectangle_clip(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { bounds: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const bounds = python.parse(Rectangle, params.bounds) catch return null;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.clip(bounds.reorder()));
}

const rectangle_intersect_doc =
    \\Calculate the intersection of this rectangle with another.
    \\
    \\## Parameters
    \\- `other` (Rectangle | tuple[float, float, float, float]): The other rectangle to intersect with
    \\
    \\## Examples
    \\```python
    \\rect1 = Rectangle(0, 0, 100, 100)
    \\rect2 = Rectangle(50, 50, 150, 150)
    \\intersection = rect1.intersect(rect2)
    \\# Returns Rectangle(50, 50, 100, 100)
    \\
    \\# Can also use a tuple
    \\intersection = rect1.intersect((50, 50, 150, 150))
    \\# Returns Rectangle(50, 50, 100, 100)
    \\
    \\rect3 = Rectangle(200, 200, 250, 250)
    \\result = rect1.intersect(rect3)  # Returns None (no overlap)
    \\```
;

fn rectangle_intersect(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    const other = python.parse(Rectangle, params.other) catch return null;
    return if (rect.intersect(other)) |intersection|
        return python.create(intersection)
    else
        return python.none();
}

const rectangle_iou_doc =
    \\Calculate the Intersection over Union (IoU) with another rectangle.
    \\
    \\## Parameters
    \\- `other` (Rectangle | tuple[float, float, float, float]): The other rectangle to calculate IoU with
    \\
    \\## Returns
    \\- `float`: IoU value between 0.0 (no overlap) and 1.0 (identical rectangles)
    \\
    \\## Examples
    \\```python
    \\rect1 = Rectangle(0, 0, 100, 100)
    \\rect2 = Rectangle(50, 50, 150, 150)
    \\iou = rect1.iou(rect2)  # Returns ~0.143
    \\
    \\# Can also use a tuple
    \\iou = rect1.iou((0, 0, 100, 100))  # Returns 1.0 (identical)
    \\
    \\# Non-overlapping rectangles
    \\rect3 = Rectangle(200, 200, 250, 250)
    \\iou = rect1.iou(rect3)  # Returns 0.0
    \\```
;

fn rectangle_iou(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        other: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const self = python.parse(Rectangle, self_obj) catch return null;
    const other = python.parse(Rectangle, params.other) catch return null;
    return python.create(self.iou(other));
}

const rectangle_overlaps_doc =
    \\Check if this rectangle overlaps with another based on IoU and coverage thresholds.
    \\
    \\## Parameters
    \\- `other` (Rectangle | tuple[float, float, float, float]): The other rectangle to check overlap with
    \\- `iou_thresh` (float, optional): IoU threshold for considering overlap. Default: 0.5
    \\- `coverage_thresh` (float, optional): Coverage threshold for considering overlap. Default: 1.0
    \\
    \\## Returns
    \\- `bool`: True if rectangles overlap enough based on the thresholds
    \\
    \\## Description
    \\Returns True if any of these conditions are met:
    \\- IoU > iou_thresh
    \\- intersection.area / self.area > coverage_thresh
    \\- intersection.area / other.area > coverage_thresh
    \\
    \\## Examples
    \\```python
    \\rect1 = Rectangle(0, 0, 100, 100)
    \\rect2 = Rectangle(50, 50, 150, 150)
    \\
    \\# Default thresholds
    \\overlaps = rect1.overlaps(rect2)  # Uses IoU > 0.5
    \\
    \\# Custom IoU threshold
    \\overlaps = rect1.overlaps(rect2, iou_thresh=0.1)  # True
    \\
    \\# Coverage threshold (useful for small rectangle inside large)
    \\small = Rectangle(25, 25, 75, 75)
    \\overlaps = rect1.overlaps(small, coverage_thresh=0.9)  # True (small is 100% covered)
    \\
    \\# Simple intersection (any positive overlap)
    \\rect1.overlaps(rect2, iou_thresh=0.0, coverage_thresh=0.0)
    \\
    \\# Full containment test
    \\rect1.overlaps(small, iou_thresh=0.0, coverage_thresh=1.0)
    \\
    \\# Can use tuple
    \\overlaps = rect1.overlaps((50, 50, 150, 150), iou_thresh=0.1)
    \\```
;

fn rectangle_overlaps(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwargs: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        other: ?*c.PyObject,
        iou_thresh: f64 = 0.5,
        coverage_thresh: f64 = 1.0,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwargs, &params) catch return null;
    _ = python.validateRange(f64, params.iou_thresh, 0.0, 1.0, "iou_thresh") catch return null;
    _ = python.validateRange(f64, params.coverage_thresh, 0.0, 1.0, "coverage_thresh") catch return null;
    const self = python.parse(Rectangle, self_obj) catch return null;
    const other = python.parse(Rectangle, params.other) catch return null;
    return python.create(self.overlaps(other, params.iou_thresh, params.coverage_thresh));
}

const rectangle_diagonal_doc =
    \\Compute the diagonal length of the rectangle.
    \\
    \\## Returns
    \\- `float`: Length of the diagonal (0.0 for empty rectangles)
;

fn rectangle_diagonal(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const rect = python.parse(Rectangle, self_obj) catch return null;
    return python.create(rect.diagonal());
}

const rectangle_covers_doc =
    \\Check if this rectangle fully contains another rectangle.
    \\
    \\## Parameters
    \\- `other` (Rectangle | tuple[float, float, float, float]): Rectangle to test
    \\
    \\## Returns
    \\- `bool`: True if `other` lies completely inside this rectangle
;

fn rectangle_covers(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const self = python.parse(Rectangle, self_obj) catch return null;
    const other = python.parse(Rectangle, params.other) catch return null;
    return python.create(self.covers(other));
}

const rectangle_merge_doc =
    \\Return the bounding box containing both rectangles.
    \\
    \\## Parameters
    \\- `other` (Rectangle | tuple[float, float, float, float]): The other rectangle to merge with.
    \\
    \\## Returns
    \\- `Rectangle`: The merged bounding box.
;

fn rectangle_merge(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const self = python.parse(Rectangle, self_obj) catch return null;
    const other = python.parse(Rectangle, params.other) catch return null;
    return python.create(self.merge(other));
}

const rectangle_reorder_doc =
    \\Return a new rectangle with coordinates re-ordered such that `left` <= `right` and `top` <= `bottom`.
    \\
    \\## Returns
    \\- `Rectangle`: A new rectangle with ordered coordinates.
;

fn rectangle_reorder(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = python.parse(Rectangle, self_obj) catch return null;
    return python.create(self.reorder());
}

const rectangle_aspect_ratio_doc =
    \\Return the aspect ratio (width / height).
    \\
    \\Returns `inf` if height is 0 and width is non-zero.
    \\Returns `NaN` if both width and height are 0.
;

fn rectangle_aspect_ratio(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = python.parse(Rectangle, self_obj) catch return null;
    return python.create(self.aspectRatio());
}

const rectangle_perimeter_doc =
    \\Return the perimeter of the rectangle.
;

fn rectangle_perimeter(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = python.parse(Rectangle, self_obj) catch return null;
    return python.create(self.perimeter());
}

// Property getters

fn rectangle_get_width(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.parse(Rectangle, self_obj) catch return null;
    return python.create(self.width());
}

fn rectangle_get_height(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.parse(Rectangle, self_obj) catch return null;
    return python.create(self.height());
}

pub const rectangle_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "init_center",
        .meth = @ptrCast(&rectangle_init_center),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = rectangle_init_center_doc,
        .params = "cls, x: float, y: float, width: float, height: float",
        .returns = "Rectangle",
    },
    .{
        .name = "is_empty",
        .meth = @ptrCast(&rectangle_is_empty),
        .flags = c.METH_NOARGS,
        .doc = rectangle_is_empty_doc,
        .params = "self",
        .returns = "bool",
    },
    .{
        .name = "area",
        .meth = @ptrCast(&rectangle_area),
        .flags = c.METH_NOARGS,
        .doc = rectangle_area_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "contains",
        .meth = @ptrCast(&rectangle_contains),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_contains_doc,
        .params = "self, point: tuple[float, float]",
        .returns = "bool",
    },
    .{
        .name = "center",
        .meth = @ptrCast(&rectangle_center),
        .flags = c.METH_NOARGS,
        .doc = rectangle_center_doc,
        .params = "self",
        .returns = "tuple[float, float]",
    },
    .{
        .name = "top_left",
        .meth = @ptrCast(&rectangle_top_left),
        .flags = c.METH_NOARGS,
        .doc = rectangle_corner_doc,
        .params = "self",
        .returns = "tuple[float, float]",
    },
    .{
        .name = "top_right",
        .meth = @ptrCast(&rectangle_top_right),
        .flags = c.METH_NOARGS,
        .doc = rectangle_corner_doc,
        .params = "self",
        .returns = "tuple[float, float]",
    },
    .{
        .name = "bottom_left",
        .meth = @ptrCast(&rectangle_bottom_left),
        .flags = c.METH_NOARGS,
        .doc = rectangle_corner_doc,
        .params = "self",
        .returns = "tuple[float, float]",
    },
    .{
        .name = "bottom_right",
        .meth = @ptrCast(&rectangle_bottom_right),
        .flags = c.METH_NOARGS,
        .doc = rectangle_corner_doc,
        .params = "self",
        .returns = "tuple[float, float]",
    },
    .{
        .name = "grow",
        .meth = @ptrCast(&rectangle_grow),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_grow_doc,
        .params = "self, amount: float",
        .returns = "Rectangle",
    },
    .{
        .name = "shrink",
        .meth = @ptrCast(&rectangle_shrink),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_shrink_doc,
        .params = "self, amount: float",
        .returns = "Rectangle",
    },
    .{
        .name = "translate",
        .meth = @ptrCast(&rectangle_translate),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_translate_doc,
        .params = "self, dx: float, dy: float",
        .returns = "Rectangle",
    },
    .{
        .name = "clip",
        .meth = @ptrCast(&rectangle_clip),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_clip_doc,
        .params = "self, bounds: Rectangle | tuple[float, float, float, float]",
        .returns = "Rectangle",
    },
    .{
        .name = "intersect",
        .meth = @ptrCast(&rectangle_intersect),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_intersect_doc,
        .params = "self, other: Rectangle | tuple[float, float, float, float]",
        .returns = "Rectangle | None",
    },
    .{
        .name = "iou",
        .meth = @ptrCast(&rectangle_iou),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_iou_doc,
        .params = "self, other: Rectangle | tuple[float, float, float, float]",
        .returns = "float",
    },
    .{
        .name = "overlaps",
        .meth = @ptrCast(&rectangle_overlaps),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_overlaps_doc,
        .params = "self, other: Rectangle | tuple[float, float, float, float], iou_thresh: float = 0.5, coverage_thresh: float = 1.0",
        .returns = "bool",
    },
    .{
        .name = "covers",
        .meth = @ptrCast(&rectangle_covers),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_covers_doc,
        .params = "self, other: Rectangle | tuple[float, float, float, float]",
        .returns = "bool",
    },
    .{
        .name = "merge",
        .meth = @ptrCast(&rectangle_merge),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = rectangle_merge_doc,
        .params = "self, other: Rectangle | tuple[float, float, float, float]",
        .returns = "Rectangle",
    },
    .{
        .name = "reorder",
        .meth = @ptrCast(&rectangle_reorder),
        .flags = c.METH_NOARGS,
        .doc = rectangle_reorder_doc,
        .params = "self",
        .returns = "Rectangle",
    },
    .{
        .name = "aspect_ratio",
        .meth = @ptrCast(&rectangle_aspect_ratio),
        .flags = c.METH_NOARGS,
        .doc = rectangle_aspect_ratio_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "perimeter",
        .meth = @ptrCast(&rectangle_perimeter),
        .flags = c.METH_NOARGS,
        .doc = rectangle_perimeter_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "diagonal",
        .meth = @ptrCast(&rectangle_diagonal),
        .flags = c.METH_NOARGS,
        .doc = rectangle_diagonal_doc,
        .params = "self",
        .returns = "float",
    },
};

var rectangle_methods = stub_metadata.toPyMethodDefArray(&rectangle_methods_metadata);

pub const rectangle_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "left",
        .get = python.getterForField(RectangleObject, "left"),
        .set = null,
        .doc = "Left coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "top",
        .get = python.getterForField(RectangleObject, "top"),
        .set = null,
        .doc = "Top coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "right",
        .get = python.getterForField(RectangleObject, "right"),
        .set = null,
        .doc = "Right coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "bottom",
        .get = python.getterForField(RectangleObject, "bottom"),
        .set = null,
        .doc = "Bottom coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "width",
        .get = @ptrCast(&rectangle_get_width),
        .set = null,
        .doc = "Width of the rectangle (`right` - `left`)",
        .type = "float",
    },
    .{
        .name = "height",
        .get = @ptrCast(&rectangle_get_height),
        .set = null,
        .doc = "Height of the rectangle (`bottom` - `top`)",
        .type = "float",
    },
};

// Auto-generate field getters with custom width/height getters
var rectangle_getset = python.autoGetSetCustom(
    RectangleObject,
    &.{ "left", "top", "right", "bottom" },
    &[_]c.PyGetSetDef{
        .{
            .name = "width".ptr,
            .get = @ptrCast(@alignCast(&rectangle_get_width)),
            .set = null,
            .doc = "Width of the rectangle (`right` - `left`)".ptr,
            .closure = null,
        },
        .{
            .name = "height".ptr,
            .get = @ptrCast(@alignCast(&rectangle_get_height)),
            .set = null,
            .doc = "Height of the rectangle (`bottom` - `top`)".ptr,
            .closure = null,
        },
    },
);

// Class documentation - keep it simple
const rectangle_class_doc = "A rectangle defined by its `left`, `top`, `right`, and `bottom` coordinates.";

// Init documentation - detailed explanation
pub const rectangle_init_doc =
    \\Initialize a Rectangle with specified coordinates.
    \\
    \\Creates a rectangle from its bounding coordinates. The rectangle is defined
    \\by four values: `left` (x-min), `top` (y-min), `right` (x-max), and `bottom` (y-max).
    \\The `right` and `bottom` bounds are exclusive.
    \\
    \\## Parameters
    \\- `left` (float): Left edge x-coordinate (inclusive)
    \\- `top` (float): Top edge y-coordinate (inclusive)
    \\- `right` (float): Right edge x-coordinate (exclusive)
    \\- `bottom` (float): Bottom edge y-coordinate (exclusive)
    \\
    \\## Examples
    \\```python
    \\# Create a rectangle from (10, 20) to (110, 70)
    \\rect = Rectangle(10, 20, 110, 70)
    \\print(rect.width)  # 100.0 (110 - 10)
    \\print(rect.height)  # 50.0 (70 - 20)
    \\print(rect.contains((109.9, 69.9)))  # True
    \\print(rect.contains((110, 70)))  # False
    \\
    \\# Create a square
    \\square = Rectangle(0, 0, 50, 50)
    \\print(square.width)  # 50.0
    \\```
    \\
    \\## Notes
    \\- The constructor validates that `right` >= `left` and `bottom` >= `top`
    \\- Use Rectangle.init_center() for center-based construction
    \\- Coordinates follow image convention: origin at top-left, y increases downward
    \\- The `right` and `bottom` bounds are exclusive
;

// Special methods metadata for stub generation
pub const rectangle_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, left: float, top: float, right: float, bottom: float",
        .returns = "None",
        .doc = rectangle_init_doc,
    },
};

// Using buildTypeObject helper for cleaner initialization
pub var RectangleType = python.buildTypeObject(.{
    .name = "zignal.Rectangle",
    .basicsize = @sizeOf(RectangleObject),
    .doc = rectangle_class_doc,
    .methods = @ptrCast(&rectangle_methods),
    .getset = @ptrCast(&rectangle_getset),
    .new = rectangle_new,
    .init = rectangle_init,
    .dealloc = rectangle_dealloc,
    .repr = rectangle_repr,
});
