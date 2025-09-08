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
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .grayscale => |img| {
                // Import numpy
                const np_module = c.PyImport_ImportModule("numpy") orelse {
                    c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
                    return null;
                };
                defer c.Py_DECREF(np_module);

                // Allocate shape and strides arrays that persist for the lifetime of the array
                const shape_array = allocator.alloc(c.Py_ssize_t, 3) catch {
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate shape array");
                    return null;
                };
                const strides_array = allocator.alloc(c.Py_ssize_t, 3) catch {
                    allocator.free(shape_array);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate strides array");
                    return null;
                };

                // Set shape: (rows, cols, 1)
                shape_array[0] = @intCast(img.rows);
                shape_array[1] = @intCast(img.cols);
                shape_array[2] = 1;

                // Set strides for proper memory layout: (stride*1, 1, 1)
                strides_array[0] = @intCast(img.stride * @sizeOf(u8));
                strides_array[1] = @sizeOf(u8);
                strides_array[2] = 1;

                // Create a 3D buffer view with proper strides
                var buffer = c.Py_buffer{
                    .buf = @ptrCast(img.data.ptr),
                    .obj = self_obj,
                    .len = @intCast(img.data.len * @sizeOf(u8)),
                    .itemsize = 1,
                    .readonly = 0,
                    .ndim = 3,
                    .format = @constCast("B"),
                    .shape = @ptrCast(shape_array.ptr),
                    .strides = @ptrCast(strides_array.ptr),
                    .suboffsets = null,
                    .internal = @ptrCast(shape_array.ptr), // Store for cleanup
                };
                c.Py_INCREF(self_obj); // Keep parent alive

                const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
                    c.Py_DECREF(self_obj);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };

                // Create numpy array from memoryview
                const np_asarray = c.PyObject_GetAttrString(np_module, "asarray") orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };
                defer c.Py_DECREF(np_asarray);

                const args_tuple = c.Py_BuildValue("(O)", memview) orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };
                defer c.Py_DECREF(args_tuple);

                const array = c.PyObject_CallObject(np_asarray, args_tuple) orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };

                // Clean up memoryview but arrays are kept alive by numpy array
                c.Py_DECREF(memview);

                return array;
            },
            .rgb => |img| {
                // Import numpy
                const np_module = c.PyImport_ImportModule("numpy") orelse {
                    c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
                    return null;
                };
                defer c.Py_DECREF(np_module);

                // Allocate shape and strides arrays that persist for the lifetime of the array
                const shape_array = allocator.alloc(c.Py_ssize_t, 3) catch {
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate shape array");
                    return null;
                };
                const strides_array = allocator.alloc(c.Py_ssize_t, 3) catch {
                    allocator.free(shape_array);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate strides array");
                    return null;
                };

                // Set shape: (rows, cols, 3)
                shape_array[0] = @intCast(img.rows);
                shape_array[1] = @intCast(img.cols);
                shape_array[2] = 3;

                // Set strides for proper memory layout: (stride*3, 3, 1)
                strides_array[0] = @intCast(img.stride * @sizeOf(Rgb));
                strides_array[1] = @sizeOf(Rgb);
                strides_array[2] = 1;

                // Create a 3D buffer view with proper strides
                var buffer = c.Py_buffer{
                    .buf = @ptrCast(img.data.ptr),
                    .obj = self_obj,
                    .len = @intCast(img.data.len * @sizeOf(Rgb)),
                    .itemsize = 1,
                    .readonly = 0,
                    .ndim = 3,
                    .format = @constCast("B"),
                    .shape = @ptrCast(shape_array.ptr),
                    .strides = @ptrCast(strides_array.ptr),
                    .suboffsets = null,
                    .internal = @ptrCast(shape_array.ptr), // Store for cleanup
                };
                c.Py_INCREF(self_obj); // Keep parent alive

                const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
                    c.Py_DECREF(self_obj);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };

                // Create numpy array from memoryview
                const np_asarray = c.PyObject_GetAttrString(np_module, "asarray") orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };
                defer c.Py_DECREF(np_asarray);

                const args_tuple = c.Py_BuildValue("(O)", memview) orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };
                defer c.Py_DECREF(args_tuple);

                const array = c.PyObject_CallObject(np_asarray, args_tuple) orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };

                // Clean up memoryview but arrays are kept alive by numpy array
                c.Py_DECREF(memview);

                return array;
            },
            .rgba => |img| {
                // Import numpy
                const np_module = c.PyImport_ImportModule("numpy") orelse {
                    c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
                    return null;
                };
                defer c.Py_DECREF(np_module);

                // Allocate shape and strides arrays that persist for the lifetime of the array
                const shape_array = allocator.alloc(c.Py_ssize_t, 3) catch {
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate shape array");
                    return null;
                };
                const strides_array = allocator.alloc(c.Py_ssize_t, 3) catch {
                    allocator.free(shape_array);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate strides array");
                    return null;
                };

                // Set shape: (rows, cols, 4)
                shape_array[0] = @intCast(img.rows);
                shape_array[1] = @intCast(img.cols);
                shape_array[2] = 4;

                // Set strides for proper memory layout: (stride*4, 4, 1)
                strides_array[0] = @intCast(img.stride * @sizeOf(Rgba));
                strides_array[1] = @sizeOf(Rgba);
                strides_array[2] = 1;

                // Create a 3D buffer view with proper strides
                var buffer = c.Py_buffer{
                    .buf = @ptrCast(img.data.ptr),
                    .obj = self_obj,
                    .len = @intCast(img.data.len * @sizeOf(Rgba)),
                    .itemsize = 1,
                    .readonly = 0,
                    .ndim = 3,
                    .format = @constCast("B"),
                    .shape = @ptrCast(shape_array.ptr),
                    .strides = @ptrCast(strides_array.ptr),
                    .suboffsets = null,
                    .internal = @ptrCast(shape_array.ptr), // Store for cleanup
                };
                c.Py_INCREF(self_obj); // Keep parent alive

                const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
                    c.Py_DECREF(self_obj);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };

                // Create numpy array from memoryview
                const np_asarray = c.PyObject_GetAttrString(np_module, "asarray") orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };
                defer c.Py_DECREF(np_asarray);

                const args_tuple = c.Py_BuildValue("(O)", memview) orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };
                defer c.Py_DECREF(args_tuple);

                const array = c.PyObject_CallObject(np_asarray, args_tuple) orelse {
                    c.Py_DECREF(memview);
                    allocator.free(shape_array);
                    allocator.free(strides_array);
                    return null;
                };

                // Clean up memoryview but arrays are kept alive by numpy array
                c.Py_DECREF(memview);

                return array;
            },
        }
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

// ============================================================================
// IMAGE FROM NUMPY
// ============================================================================

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
    var array_obj: ?*c.PyObject = undefined;

    const kw = comptime py_utils.kw(&.{"array"});
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(@constCast(&kw)), &array_obj) == 0) {
        return null;
    }

    if (array_obj == null or array_obj == c.Py_None()) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array cannot be None");
        return null;
    }

    // Get buffer interface from the array
    var buffer: c.Py_buffer = undefined;
    buffer = std.mem.zeroes(c.Py_buffer);

    // Request buffer with strides info
    const flags: c_int = 0x001c; // PyBUF_ND | PyBUF_STRIDES | PyBUF_FORMAT
    if (c.PyObject_GetBuffer(array_obj, &buffer, flags) != 0) {
        // Error already set by PyObject_GetBuffer
        return null;
    }
    defer c.PyBuffer_Release(&buffer);

    // Validate buffer format if available (should be 'B' for uint8)
    // Note: format might be null if PyBUF_FORMAT wasn't requested
    if (buffer.format != null and (buffer.format[0] != 'B' or buffer.format[1] != 0)) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array must have dtype uint8");
        return null;
    }

    // Validate dimensions and shape: only 3D arrays with 1, 3 or 4 channels are supported
    const ndim: c_int = buffer.ndim;
    if (ndim != 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have shape (rows, cols, 1|3|4)");
        return null;
    }

    const shape = @as([*]c.Py_ssize_t, @ptrCast(buffer.shape));
    const rows = @as(usize, @intCast(shape[0]));
    const cols = @as(usize, @intCast(shape[1]));
    const channels: usize = @as(usize, @intCast(shape[2]));
    if (!(channels == 1 or channels == 3 or channels == 4)) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have 1 channel (grayscale), 3 channels (RGB) or 4 channels (RGBA)");
        return null;
    }

    // Check if array strides are compatible (pixels must be contiguous within rows)
    const strides = @as([*]c.Py_ssize_t, @ptrCast(buffer.strides));
    const item = buffer.itemsize; // 1 for uint8

    // Check that pixels within a row are contiguous
    const expected_pixel_stride = item * @as(c.Py_ssize_t, @intCast(channels));
    if (strides[2] != item or strides[1] != expected_pixel_stride) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array pixels must be contiguous. Use numpy.ascontiguousarray() first.");
        return null;
    }

    // Calculate row stride in pixels (not bytes)
    const row_stride_bytes = strides[0];
    const pixel_size: c.Py_ssize_t = @intCast(channels);
    if (@rem(row_stride_bytes, pixel_size) != 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array row stride must be a multiple of pixel size.");
        return null;
    }
    const row_stride_pixels = @divExact(row_stride_bytes, pixel_size);

    // Create new Python object
    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(getImageType()), 0)));
    if (self == null) {
        return null;
    }

    if (channels == 1) {
        // Zero-copy: create grayscale image that points to NumPy's data directly
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const data_slice = data_ptr[0..@intCast(buffer.len)];

        // Create image with custom stride to handle non-contiguous arrays
        const img = Image(u8){
            .rows = rows,
            .cols = cols,
            .data = data_slice,
            .stride = @intCast(row_stride_pixels),
        };

        // Keep a reference to the NumPy array to prevent deallocation
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
        // Wrap as PyImage non-owning grayscale
        const pimg = PyImage.createFrom(allocator, img, .borrowed) orelse {
            c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
            return null;
        };
        self.?.py_image = pimg;
        self.?.parent_ref = null;
        return @as(?*c.PyObject, @ptrCast(self));
    } else if (channels == 4) {
        // Zero-copy: create image that points to NumPy's data directly
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const rgba_ptr = @as([*]Rgba, @ptrCast(@alignCast(data_ptr)));
        const data_slice = rgba_ptr[0..@divExact(@as(usize, @intCast(buffer.len)), @sizeOf(Rgba))];

        // Create image with custom stride to handle non-contiguous arrays
        const img = Image(Rgba){
            .rows = rows,
            .cols = cols,
            .data = data_slice,
            .stride = @intCast(row_stride_pixels),
        };

        // Keep a reference to the NumPy array to prevent deallocation
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
        // Wrap as PyImage non-owning RGBA
        const pimg = PyImage.createFrom(allocator, img, .borrowed) orelse {
            c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
            return null;
        };
        self.?.py_image = pimg;
        self.?.parent_ref = null;
        return @as(?*c.PyObject, @ptrCast(self));
    } else if (channels == 3) {
        // Zero-copy RGB
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const rgb_ptr = @as([*]Rgb, @ptrCast(@alignCast(data_ptr)));
        const data_slice = rgb_ptr[0..@divExact(@as(usize, @intCast(buffer.len)), @sizeOf(Rgb))];

        // Create image with custom stride to handle non-contiguous arrays
        const img = Image(Rgb){
            .rows = rows,
            .cols = cols,
            .data = data_slice,
            .stride = @intCast(row_stride_pixels),
        };
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
        const pimg = PyImage.createFrom(allocator, img, .borrowed) orelse {
            c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
            return null;
        };
        self.?.py_image = pimg;
        self.?.parent_ref = null;
    } else unreachable; // validated above
    return @as(?*c.PyObject, @ptrCast(self));
}
