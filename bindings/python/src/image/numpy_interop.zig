//! NumPy array conversion for Image objects

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;

const py_utils = @import("../py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;

const PyImageMod = @import("../PyImage.zig");
const PyImage = PyImageMod.PyImage;

// Import the ImageObject type from parent
const ImageObject = @import("../image.zig").ImageObject;
const getImageType = @import("../image.zig").getImageType;

const BufferExtra = extern struct {
    shape: [3]c.Py_ssize_t,
    strides: [3]c.Py_ssize_t,
};

/// Helper to convert a zignal.Image to a NumPy array
fn imageToNumpyHelper(self_obj: ?*c.PyObject, img: anytype) ?*c.PyObject {
    const T = @TypeOf(img.data[0]);
    const channels = comptime if (T == u8) 1 else if (T == Rgb) 3 else if (T == Rgba) 4 else @compileError("unsupported type");

    const np_module = c.PyImport_ImportModule("numpy") orelse {
        py_utils.setValueError("NumPy is not installed. Please install it with: pip install numpy", .{});
        return null;
    };
    defer c.Py_DECREF(np_module);

    const extra_raw = c.PyMem_Malloc(@sizeOf(BufferExtra)) orelse {
        py_utils.setMemoryError("buffer metadata");
        return null;
    };
    const extra = @as(*BufferExtra, @ptrCast(@alignCast(extra_raw)));
    var cleanup_extra = true;
    defer if (cleanup_extra) c.PyMem_Free(extra_raw);

    extra.shape = .{
        @intCast(img.rows),
        @intCast(img.cols),
        channels,
    };
    extra.strides = .{
        @intCast(img.stride * @sizeOf(T)),
        @sizeOf(T),
        if (channels == 1) @sizeOf(T) else 1,
    };

    var buffer = c.Py_buffer{
        .buf = @ptrCast(img.data.ptr),
        .obj = self_obj,
        .len = @intCast(img.data.len * @sizeOf(T)),
        .itemsize = 1,
        .readonly = 0,
        .ndim = 3,
        .format = @constCast("B"),
        .shape = @ptrCast(&extra.shape[0]),
        .strides = @ptrCast(&extra.strides[0]),
        .suboffsets = null,
        .internal = extra_raw,
    };
    c.Py_INCREF(self_obj);

    const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
        c.Py_DECREF(self_obj);
        return null;
    };
    cleanup_extra = false;

    const np_asarray = c.PyObject_GetAttrString(np_module, "asarray") orelse {
        c.Py_DECREF(memview);
        return null;
    };
    defer c.Py_DECREF(np_asarray);

    const args_tuple = c.Py_BuildValue("(N)", memview) orelse {
        return null;
    };
    defer c.Py_DECREF(args_tuple);

    const array = c.PyObject_CallObject(np_asarray, args_tuple) orelse {
        return null;
    };

    return array;
}

// ============================================================================
// IMAGE TO NUMPY
// ============================================================================

pub const image_to_numpy_doc =
    \\Convert the image to a NumPy array (zero-copy when possible).
    \\
    \\Returns an array in the image's native dtype:\n
    \\- Grayscale → shape (rows, cols, 1)\n
    \\- Rgb → shape (rows, cols, 3)\n
    \\- Rgba → shape (rows, cols, 4)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\arr = img.to_numpy()
    \\print(arr.shape, arr.dtype)
    \\# Example: (H, W, C) uint8 where C is 1, 3, or 4
    \\```
;

pub fn image_to_numpy(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = py_utils.safeCast(ImageObject, self_obj);

    if (self.py_image) |pimg| {
        return switch (pimg.data) {
            inline else => |img| imageToNumpyHelper(self_obj, img),
        };
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

// ============================================================================
// IMAGE FROM NUMPY
// ============================================================================

/// Helper to create a zignal.Image from a NumPy buffer
fn imageFromNumpyHelper(
    comptime T: type,
    self_opt: ?*ImageObject,
    array_obj: ?*c.PyObject,
    buffer: *c.Py_buffer,
    rows: usize,
    cols: usize,
    row_stride_pixels: usize,
) ?*c.PyObject {
    const self = self_opt orelse {
        // This should be unreachable if called correctly
        py_utils.setRuntimeError("Internal error: ImageObject is null", .{});
        return null;
    };

    const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
    const pixel_ptr = @as([*]T, @ptrCast(@alignCast(data_ptr)));
    const data_slice = pixel_ptr[0..@divExact(@as(usize, @intCast(buffer.len)), @sizeOf(T))];

    const img = Image(T){
        .rows = rows,
        .cols = cols,
        .data = data_slice,
        .stride = row_stride_pixels,
    };

    c.Py_INCREF(array_obj.?);
    self.numpy_ref = array_obj;

    const pimg = PyImage.createFrom(allocator, img, .borrowed) orelse {
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
        py_utils.setMemoryError("image");
        return null;
    };
    self.py_image = pimg;
    self.parent_ref = null;

    return @as(?*c.PyObject, @ptrCast(self));
}

pub const image_from_numpy_doc =
    \\Create Image from a NumPy array with dtype uint8.
    \\
    \\Zero-copy is used for arrays with these shapes:
    \\- Grayscale: (rows, cols, 1) → Image(Grayscale)
    \\- RGB: (rows, cols, 3) → Image(Rgb)
    \\- RGBA: (rows, cols, 4) → Image(Rgba)
    \\
    \\The array can have row strides (e.g., from views or slicing) as long as pixels
    \\within each row are contiguous. For arrays with incompatible strides (e.g., transposed),
    \\use `numpy.ascontiguousarray()` first.
    \\
    \\## Parameters
    \\- `array` (NDArray[np.uint8]): NumPy array with shape (rows, cols, 1), (rows, cols, 3) or (rows, cols, 4) and dtype uint8.
    \\  Pixels within rows must be contiguous.
    \\
    \\## Raises
    \\- `TypeError`: If array is None or has wrong dtype
    \\- `ValueError`: If array has wrong shape or incompatible strides
    \\
    \\## Notes
    \\The array can have row strides (padding between rows) but pixels within
    \\each row must be contiguous. For incompatible layouts (e.g., transposed
    \\arrays), use np.ascontiguousarray() first:
    \\
    \\```python
    \\arr = np.ascontiguousarray(arr)
    \\img = Image.from_numpy(arr)
    \\```
    \\
    \\## Examples
    \\```python
    \\arr = np.zeros((100, 200, 3), dtype=np.uint8)
    \\img = Image.from_numpy(arr)
    \\print(img.rows, img.cols)
    \\# Output: 100 200
    \\```
;

pub fn image_from_numpy(_: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        array: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const array_obj = params.array;

    if (array_obj == null or array_obj == c.Py_None()) {
        py_utils.setTypeError("non-None array", array_obj);
        return null;
    }

    var buffer: c.Py_buffer = undefined;
    buffer = std.mem.zeroes(c.Py_buffer);

    const flags: c_int = 0x001c; // PyBUF_ND | PyBUF_STRIDES | PyBUF_FORMAT
    if (c.PyObject_GetBuffer(array_obj, &buffer, flags) != 0) {
        return null;
    }
    defer c.PyBuffer_Release(&buffer);

    if (buffer.format != null and (buffer.format[0] != 'B' or buffer.format[1] != 0)) {
        py_utils.setTypeError("uint8 array", array_obj);
        return null;
    }

    if (buffer.ndim != 3) {
        py_utils.setValueError("Array must have shape (rows, cols, 1|3|4)", .{});
        return null;
    }

    const shape = @as([*]c.Py_ssize_t, @ptrCast(buffer.shape));
    const rows: usize = @intCast(shape[0]);
    const cols: usize = @intCast(shape[1]);
    const channels: usize = @intCast(shape[2]);

    if (channels != 1 and channels != 3 and channels != 4) {
        py_utils.setValueError("Array must have 1, 3, or 4 channels", .{});
        return null;
    }

    const strides = @as([*]c.Py_ssize_t, @ptrCast(buffer.strides));
    const item_size = buffer.itemsize;

    const expected_pixel_stride = item_size * @as(c.Py_ssize_t, @intCast(channels));
    if (strides[2] != item_size or strides[1] != expected_pixel_stride) {
        py_utils.setValueError("Array pixels must be contiguous. Use numpy.ascontiguousarray() first.", .{});
        return null;
    }

    const row_stride_bytes = strides[0];
    const pixel_size: c.Py_ssize_t = @intCast(channels);
    if (@rem(row_stride_bytes, pixel_size) != 0) {
        py_utils.setValueError("Array row stride must be a multiple of pixel size.", .{});
        return null;
    }
    const row_stride_pixels: usize = @intCast(@divExact(row_stride_bytes, pixel_size));

    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(getImageType()), 0))) orelse return null;

    return switch (channels) {
        1 => imageFromNumpyHelper(u8, self, array_obj, &buffer, rows, cols, row_stride_pixels),
        3 => imageFromNumpyHelper(Rgb, self, array_obj, &buffer, rows, cols, row_stride_pixels),
        4 => imageFromNumpyHelper(Rgba, self, array_obj, &buffer, rows, cols, row_stride_pixels),
        else => unreachable,
    };
}
