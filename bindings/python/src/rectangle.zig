const std = @import("std");

const zignal = @import("zignal");
const Rectangle = zignal.Rectangle;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

pub const RectangleObject = extern struct {
    ob_base: c.PyObject,
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

fn rectangle_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*RectangleObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.left = 0;
        obj.top = 0;
        obj.right = 0;
        obj.bottom = 0;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn rectangle_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = kwds;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    // Parse arguments - expect left, top, right, bottom
    var left: f64 = undefined;
    var top: f64 = undefined;
    var right: f64 = undefined;
    var bottom: f64 = undefined;
    const format = std.fmt.comptimePrint("dddd", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &left, &top, &right, &bottom) == 0) {
        return -1;
    }

    // Validate rectangle
    if (right < left) {
        c.PyErr_SetString(c.PyExc_ValueError, "Right must be greater than or equal to left");
        return -1;
    }
    if (bottom < top) {
        c.PyErr_SetString(c.PyExc_ValueError, "Bottom must be greater than or equal to top");
        return -1;
    }

    // Store as f32
    self.left = @as(f32, @floatCast(left));
    self.top = @as(f32, @floatCast(top));
    self.right = @as(f32, @floatCast(right));
    self.bottom = @as(f32, @floatCast(bottom));

    return 0;
}

fn rectangle_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn rectangle_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

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

fn rectangle_init_center(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var x: f64 = undefined;
    var y: f64 = undefined;
    var width: f64 = undefined;
    var height: f64 = undefined;

    const format = std.fmt.comptimePrint("dddd", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &x, &y, &width, &height) == 0) {
        return null;
    }

    // Validate dimensions
    if (width <= 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be positive");
        return null;
    }
    if (height <= 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Height must be positive");
        return null;
    }

    // Calculate bounds
    const left = x - width / 2;
    const top = y - height / 2;
    const right = left + width;
    const bottom = top + height;

    // Create new Rectangle instance
    const rect_args = c.Py_BuildValue("(dddd)", left, top, right, bottom) orelse return null;
    defer c.Py_DECREF(rect_args);

    const instance = c.PyObject_CallObject(@ptrCast(type_obj), rect_args);
    return instance;
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
    \\rect2 = Rectangle(100, 100, 0, 0)  # Invalid: right < left
    \\print(rect2.is_empty())  # True
    \\```
;

fn rectangle_is_empty(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    // For floats, use >= comparison (matches Rectangle.zig logic)
    const is_empty = self.top >= self.bottom or self.left >= self.right;
    return @ptrCast(py_utils.getPyBool(is_empty));
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
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    const width = self.right - self.left;
    const height = self.bottom - self.top;
    const area = if (width < 0 or height < 0) 0 else width * height;

    return c.PyFloat_FromDouble(@as(f64, area));
}

const rectangle_contains_doc =
    \\Check if a point is inside the rectangle.
    \\
    \\## Parameters
    \\- `x` (float): X coordinate to check
    \\- `y` (float): Y coordinate to check
    \\
    \\## Examples
    \\```python
    \\rect = Rectangle(0, 0, 100, 100)
    \\print(rect.contains(50, 50))   # True
    \\print(rect.contains(150, 50))  # False
    \\```
;

fn rectangle_contains(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    var x: f64 = undefined;
    var y: f64 = undefined;

    const format = std.fmt.comptimePrint("dd", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &x, &y) == 0) {
        return null;
    }

    const x_f32 = @as(f32, @floatCast(x));
    const y_f32 = @as(f32, @floatCast(y));

    const contains = x_f32 >= self.left and x_f32 <= self.right and
        y_f32 >= self.top and y_f32 <= self.bottom;

    return @ptrCast(py_utils.getPyBool(contains));
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

fn rectangle_grow(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    var amount: f64 = undefined;

    const format = std.fmt.comptimePrint("d", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &amount) == 0) {
        return null;
    }

    const amount_f32 = @as(f32, @floatCast(amount));

    // Create new rectangle with grown bounds
    const new_args = c.Py_BuildValue("(dddd)", @as(f64, self.left - amount_f32), @as(f64, self.top - amount_f32), @as(f64, self.right + amount_f32), @as(f64, self.bottom + amount_f32)) orelse return null;
    defer c.Py_DECREF(new_args);

    const new_rect = c.PyObject_CallObject(@ptrCast(&RectangleType), new_args);
    return new_rect;
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

fn rectangle_shrink(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    var amount: f64 = undefined;

    const format = std.fmt.comptimePrint("d", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &amount) == 0) {
        return null;
    }

    const amount_f32 = @as(f32, @floatCast(amount));

    // Create new rectangle with shrunk bounds
    const new_args = c.Py_BuildValue("(dddd)", @as(f64, self.left + amount_f32), @as(f64, self.top + amount_f32), @as(f64, self.right - amount_f32), @as(f64, self.bottom - amount_f32)) orelse return null;
    defer c.Py_DECREF(new_args);

    const new_rect = c.PyObject_CallObject(@ptrCast(&RectangleType), new_args);
    return new_rect;
}

const rectangle_intersect_doc =
    \\Calculate the intersection of this rectangle with another.
    \\
    \\## Parameters
    \\- `other` (Rectangle): The other rectangle to intersect with
    \\
    \\## Examples
    \\```python
    \\rect1 = Rectangle(0, 0, 100, 100)
    \\rect2 = Rectangle(50, 50, 150, 150)
    \\intersection = rect1.intersect(rect2)
    \\# Returns Rectangle(50, 50, 100, 100)
    \\
    \\rect3 = Rectangle(200, 200, 250, 250)
    \\result = rect1.intersect(rect3)  # Returns None (no overlap)
    \\```
;

fn rectangle_intersect(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));

    var other_obj: ?*c.PyObject = undefined;

    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &other_obj) == 0) {
        return null;
    }

    // Check if it's a Rectangle instance
    if (c.PyObject_IsInstance(other_obj, @ptrCast(&RectangleType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Argument must be a Rectangle instance");
        return null;
    }

    const other = @as(*RectangleObject, @ptrCast(other_obj.?));

    // Calculate intersection bounds
    const left = @max(self.left, other.left);
    const top = @max(self.top, other.top);
    const right = @min(self.right, other.right);
    const bottom = @min(self.bottom, other.bottom);

    // Check if the intersection is empty (for floats, use >=)
    if (left >= right or top >= bottom) {
        // Return None
        const none = c.Py_None();
        c.Py_INCREF(none);
        return none;
    }

    // Create intersection rectangle
    const new_args = c.Py_BuildValue("(dddd)", @as(f64, left), @as(f64, top), @as(f64, right), @as(f64, bottom)) orelse return null;
    defer c.Py_DECREF(new_args);

    const new_rect = c.PyObject_CallObject(@ptrCast(&RectangleType), new_args);
    return new_rect;
}

// Property getters
fn rectangle_get_left(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(@as(f64, self.left));
}

fn rectangle_get_top(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(@as(f64, self.top));
}

fn rectangle_get_right(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(@as(f64, self.right));
}

fn rectangle_get_bottom(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(@as(f64, self.bottom));
}

fn rectangle_get_width(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));
    const width = self.right - self.left;
    return c.PyFloat_FromDouble(@as(f64, width));
}

fn rectangle_get_height(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RectangleObject, @ptrCast(self_obj.?));
    const height = self.bottom - self.top;
    return c.PyFloat_FromDouble(@as(f64, height));
}

pub const rectangle_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "init_center",
        .meth = @ptrCast(&rectangle_init_center),
        .flags = c.METH_VARARGS | c.METH_CLASS,
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
        .flags = c.METH_VARARGS,
        .doc = rectangle_contains_doc,
        .params = "self, x: float, y: float",
        .returns = "bool",
    },
    .{
        .name = "grow",
        .meth = @ptrCast(&rectangle_grow),
        .flags = c.METH_VARARGS,
        .doc = rectangle_grow_doc,
        .params = "self, amount: float",
        .returns = "Rectangle",
    },
    .{
        .name = "shrink",
        .meth = @ptrCast(&rectangle_shrink),
        .flags = c.METH_VARARGS,
        .doc = rectangle_shrink_doc,
        .params = "self, amount: float",
        .returns = "Rectangle",
    },
    .{
        .name = "intersect",
        .meth = @ptrCast(&rectangle_intersect),
        .flags = c.METH_VARARGS,
        .doc = rectangle_intersect_doc,
        .params = "self, other: Rectangle",
        .returns = "Optional[Rectangle]",
    },
};

var rectangle_methods = stub_metadata.toPyMethodDefArray(&rectangle_methods_metadata);

pub const rectangle_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "left",
        .get = @ptrCast(&rectangle_get_left),
        .set = null,
        .doc = "Left coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "top",
        .get = @ptrCast(&rectangle_get_top),
        .set = null,
        .doc = "Top coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "right",
        .get = @ptrCast(&rectangle_get_right),
        .set = null,
        .doc = "Right coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "bottom",
        .get = @ptrCast(&rectangle_get_bottom),
        .set = null,
        .doc = "Bottom coordinate of the rectangle",
        .type = "float",
    },
    .{
        .name = "width",
        .get = @ptrCast(&rectangle_get_width),
        .set = null,
        .doc = "Width of the rectangle (right - left)",
        .type = "float",
    },
    .{
        .name = "height",
        .get = @ptrCast(&rectangle_get_height),
        .set = null,
        .doc = "Height of the rectangle (bottom - top)",
        .type = "float",
    },
};

var rectangle_getset = stub_metadata.toPyGetSetDefArray(&rectangle_properties_metadata);

pub var RectangleType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.Rectangle",
    .tp_basicsize = @sizeOf(RectangleObject),
    .tp_dealloc = rectangle_dealloc,
    .tp_repr = rectangle_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "A rectangle defined by its left, top, right, and bottom coordinates",
    .tp_methods = @ptrCast(&rectangle_methods),
    .tp_getset = @ptrCast(&rectangle_getset),
    .tp_init = rectangle_init,
    .tp_new = rectangle_new,
};

/// Convert a Python Rectangle object to a Zignal Rectangle(f32)
pub fn toZignalRectangle(rect_obj: ?*c.PyObject) !Rectangle(f32) {
    if (rect_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle object is null");
        return error.InvalidRectangle;
    }

    // Check if it's a Rectangle instance
    if (c.PyObject_IsInstance(rect_obj, @ptrCast(&RectangleType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Object must be a Rectangle instance");
        return error.InvalidRectangle;
    }

    const rect = @as(*RectangleObject, @ptrCast(rect_obj.?));
    return Rectangle(f32).init(rect.left, rect.top, rect.right, rect.bottom);
}
