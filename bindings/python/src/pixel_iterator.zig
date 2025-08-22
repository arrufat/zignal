const std = @import("std");

const zignal = @import("zignal");
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;

const ImageObject = @import("image.zig").ImageObject;
const py_utils = @import("py_utils.zig");
const c = py_utils.c;

pub const PixelIteratorObject = extern struct {
    ob_base: c.PyObject,
    image_ref: ?*c.PyObject,
    index: usize,
};

const pixel_iterator_doc =
    \\
    \\Iterator over image pixels yielding (row, col, pixel) in native format.
    \\
    \\This iterator walks the image in row-major order (top-left to bottom-right).
    \\For views, iteration respects the view bounds and the underlying stride, so
    \\you only traverse the visible sub-rectangle without copying.
    \\
    \\## Examples
    \\
    \\```python
    \\image = Image(2, 3, Rgb(255, 0, 0), format=zignal.Rgb)
    \\for r, c, pixel in image:
    \\    print(f"image[{r}, {c}] = {pixel}")
    \\```
    \\
    \\## Notes
    \\- Returned by `iter(Image)` / `Image.__iter__()`\n
    \\- Use `Image.to_numpy()` when you need bulk numeric processing for best performance.
;

fn pixel_iterator_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*PixelIteratorObject, @ptrCast(self_obj.?));
    if (self.image_ref) |ref| c.Py_XDECREF(ref);
    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn pixel_iterator_iter(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = self_obj.?;
    c.Py_INCREF(self);
    return self;
}

fn pixel_iterator_next(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*PixelIteratorObject, @ptrCast(self_obj.?));
    if (self.image_ref == null) {
        c.PyErr_SetNone(c.PyExc_StopIteration);
        return null;
    }

    const img_py = @as(*ImageObject, @ptrCast(self.image_ref.?));
    const total = if (img_py.py_image) |pimg| pimg.rows() * pimg.cols() else 0;
    if (self.index >= total) {
        c.PyErr_SetNone(c.PyExc_StopIteration);
        return null;
    }

    // Compute row/col and get pixel in native format
    var row: usize = undefined;
    var col: usize = undefined;
    var pixel_obj: ?*c.PyObject = null;

    if (img_py.py_image == null) {
        c.PyErr_SetNone(c.PyExc_StopIteration);
        return null;
    }
    const pimg = img_py.py_image.?;
    row = self.index / pimg.cols();
    col = self.index % pimg.cols();
    switch (pimg.data) {
        .gray => |img| {
            const v = img.at(row, col).*;
            pixel_obj = c.PyLong_FromLong(@intCast(v));
        },
        .rgb => |img| {
            const p = img.at(row, col).*;
            const color_module = @import("color.zig");
            const rgb_obj = c.PyType_GenericAlloc(@ptrCast(&color_module.RgbType), 0) orelse return null;
            const rgb = @as(*color_module.RgbBinding.PyObjectType, @ptrCast(rgb_obj));
            rgb.field0 = p.r;
            rgb.field1 = p.g;
            rgb.field2 = p.b;
            pixel_obj = rgb_obj;
        },
        .rgba => |img| {
            const p = img.at(row, col).*;
            const color_module = @import("color.zig");
            const rgba_obj = c.PyType_GenericAlloc(@ptrCast(&color_module.RgbaType), 0) orelse return null;
            const rgba = @as(*color_module.RgbaBinding.PyObjectType, @ptrCast(rgba_obj));
            rgba.field0 = p.r;
            rgba.field1 = p.g;
            rgba.field2 = p.b;
            rgba.field3 = p.a;
            pixel_obj = rgba_obj;
        },
    }

    if (pixel_obj == null) return null;

    // Build tuple (row, col, pixel)
    const result = c.Py_BuildValue("(nnO)", @as(c.Py_ssize_t, @intCast(row)), @as(c.Py_ssize_t, @intCast(col)), pixel_obj.?) orelse {
        c.Py_DECREF(pixel_obj.?);
        return null;
    };

    self.index += 1;
    return result;
}

pub var PixelIteratorType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.PixelIterator",
    .tp_basicsize = @sizeOf(PixelIteratorObject),
    .tp_dealloc = pixel_iterator_dealloc,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = pixel_iterator_doc,
    .tp_iter = pixel_iterator_iter,
    .tp_iternext = pixel_iterator_next,
};

/// Create a new iterator bound to the given Image PyObject
pub fn new(image_obj: ?*c.PyObject) ?*c.PyObject {
    if (c.PyType_Ready(&PixelIteratorType) < 0) return null;
    const it_obj = @as(?*PixelIteratorObject, @ptrCast(c.PyType_GenericAlloc(&PixelIteratorType, 0)));
    if (it_obj == null) return null;
    if (image_obj) |img| c.Py_INCREF(img);
    it_obj.?.image_ref = image_obj;
    it_obj.?.index = 0;
    return @ptrCast(it_obj);
}

// Stub metadata for PixelIterator
pub const pixel_iterator_special_methods_metadata = [_]@import("stub_metadata.zig").MethodInfo{
    .{
        .name = "__iter__",
        .params = "self",
        .returns = "PixelIterator",
        .doc = "Return self as an iterator.",
    },
    .{
        .name = "__next__",
        .params = "self",
        .returns = "tuple[int, int, Color]",
        .doc = "Return the next (row, col, pixel) where pixel is native: int | Rgb | Rgba.",
    },
};
