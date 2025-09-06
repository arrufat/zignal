//! Geometric transformations for Image objects

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;
const Interpolation = zignal.Interpolation;
const Rectangle = zignal.Rectangle;
const Point = zignal.Point;

const py_utils = @import("../py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;
const enum_utils = @import("../enum_utils.zig");

const PyImageMod = @import("../PyImage.zig");
const PyImage = PyImageMod.PyImage;
const transforms = @import("../transforms.zig");

// Import the ImageObject type from parent
const ImageObject = @import("../image.zig").ImageObject;
const getImageType = @import("../image.zig").getImageType;

// Helper: map Interpolation tag to union value (defaults for parameterized variants)
const InterpTag = @typeInfo(Interpolation).@"union".tag_type.?;
fn tagToInterpolation(tag: InterpTag) Interpolation {
    return switch (tag) {
        .nearest_neighbor => .nearest_neighbor,
        .bilinear => .bilinear,
        .bicubic => .bicubic,
        .catmull_rom => .catmull_rom,
        .mitchell => .{ .mitchell = .default },
        .lanczos => .lanczos,
    };
}

fn mapScaleError(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.OutOfMemory,
    };
}

fn image_scale(self: *ImageObject, scale: f32, method: Interpolation) !*ImageObject {
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |*img| {
                var out = img.scale(allocator, scale, method) catch |err| return mapScaleError(err);
                const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
        }
    }
    return error.ImageNotInitialized;
}

fn image_reshape(self: *ImageObject, rows: usize, cols: usize, method: Interpolation) !*ImageObject {
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |*img| {
                var out = @TypeOf(img.*).init(allocator, rows, cols) catch return error.OutOfMemory;
                img.resize(allocator, out, method) catch return error.OutOfMemory;
                const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
        }
    }
    return error.ImageNotInitialized;
}

fn image_letterbox_shape(self: *ImageObject, rows: usize, cols: usize, method: Interpolation) !*ImageObject {
    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return error.OutOfMemory;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).init(allocator, rows, cols) catch {
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                _ = img.letterbox(allocator, &out, method) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return result;
    }
    return error.ImageNotInitialized;
}

fn image_letterbox_square(self: *ImageObject, size: usize, method: Interpolation) !*ImageObject {
    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return error.OutOfMemory;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).init(allocator, size, size) catch {
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                _ = img.letterbox(allocator, &out, method) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return result;
    }
    return error.ImageNotInitialized;
}

// Transform functions
pub const image_resize_doc =
    \\Resize the image to the specified size.
    \\
    \\## Parameters
    \\- `size` (float or tuple[int, int]):
    \\  - If float: scale factor (e.g., 0.5 for half size, 2.0 for double size)
    \\  - If tuple: target dimensions as (rows, cols)
    \\- `method` (`Interpolation`, optional): Interpolation method to use. Default is `Interpolation.BILINEAR`.
;

pub fn image_resize(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var shape_or_scale: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR

    var kwlist = [_:null]?[*:0]u8{ @constCast("size"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("O|l", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &shape_or_scale, &method_value) == 0) {
        return null;
    }

    if (shape_or_scale == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "resize() missing required argument: 'size' (pos 1)");
        return null;
    }

    const tag_resize = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };
    const method = tagToInterpolation(tag_resize);

    // Check if argument is a number (scale) or tuple (dimensions)
    if (c.PyFloat_Check(shape_or_scale) != 0 or c.PyLong_Check(shape_or_scale) != 0) {
        // It's a scale factor
        const scale = c.PyFloat_AsDouble(shape_or_scale);
        if (scale == -1.0 and c.PyErr_Occurred() != null) {
            return null;
        }
        if (scale <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Scale factor must be positive");
            return null;
        }

        const result = image_scale(self, @floatCast(scale), method) catch return null;
        return @ptrCast(result);
    } else if (c.PyTuple_Check(shape_or_scale) != 0) {
        // It's a tuple of dimensions
        if (c.PyTuple_Size(shape_or_scale) != 2) {
            c.PyErr_SetString(c.PyExc_ValueError, "Size must be a 2-tuple of (rows, cols)");
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(shape_or_scale, 0);
        const cols_obj = c.PyTuple_GetItem(shape_or_scale, 1);

        const rows = c.PyLong_AsLong(rows_obj);
        if (rows == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Rows must be an integer");
            return null;
        }
        if (rows <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Rows must be positive");
            return null;
        }

        const cols = c.PyLong_AsLong(cols_obj);
        if (cols == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Cols must be an integer");
            return null;
        }
        if (cols <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Cols must be positive");
            return null;
        }

        const result = image_reshape(self, @intCast(rows), @intCast(cols), method) catch return null;
        return @ptrCast(result);
    } else {
        c.PyErr_SetString(c.PyExc_TypeError, "resize() argument must be a number (scale) or tuple (rows, cols)");
        return null;
    }
}

pub const image_letterbox_doc =
    \\Resize image to fit within the specified size while preserving aspect ratio.
    \\
    \\The image is scaled to fit within the target dimensions and centered with
    \\black borders (letterboxing) to maintain the original aspect ratio.
    \\
    \\## Parameters
    \\- `size` (int or tuple[int, int]):
    \\  - If int: creates a square output of size x size
    \\  - If tuple: target dimensions as (rows, cols)
    \\- `method` (`Interpolation`, optional): Interpolation method to use. Default is `Interpolation.BILINEAR`.
;

pub fn image_letterbox(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var size: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR
    var kwlist = [_:null]?[*:0]u8{ @constCast("size"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("O|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &size, &method_value) == 0) {
        return null;
    }

    if (size == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "letterbox() missing required argument: 'size' (pos 1)");
        return null;
    }

    const tag_letterbox = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };
    const method = tagToInterpolation(tag_letterbox);

    // Check if argument is a number (square) or tuple (dimensions)
    if (c.PyLong_Check(size) != 0) {
        // It's an integer for square letterbox
        const square_size = c.PyLong_AsLong(size);
        if (square_size == -1 and c.PyErr_Occurred() != null) {
            return null;
        }
        if (square_size <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Size must be positive");
            return null;
        }
        const result = image_letterbox_square(self, @intCast(square_size), method) catch return null;
        return @ptrCast(result);
    } else if (c.PyTuple_Check(size) != 0) {
        // It's a tuple for dimensions
        if (c.PyTuple_Size(size) != 2) {
            c.PyErr_SetString(c.PyExc_ValueError, "Dimensions must be a tuple of 2 integers (rows, cols)");
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(size, 0);
        const cols_obj = c.PyTuple_GetItem(size, 1);

        if (c.PyLong_Check(rows_obj) == 0 or c.PyLong_Check(cols_obj) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "Dimensions must be integers");
            return null;
        }

        const rows = c.PyLong_AsLong(rows_obj);
        const cols = c.PyLong_AsLong(cols_obj);

        if ((rows == -1 or cols == -1) and c.PyErr_Occurred() != null) {
            return null;
        }

        if (rows <= 0 or cols <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Dimensions must be positive");
            return null;
        }

        const result = image_letterbox_shape(self, @intCast(rows), @intCast(cols), method) catch return null;
        return @ptrCast(result);
    } else {
        c.PyErr_SetString(c.PyExc_TypeError, "letterbox() argument must be an integer (square) or tuple (rows, cols)");
        return null;
    }
}

pub const image_rotate_doc =
    \\Rotate the image by the specified angle around its center.
    \\
    \\The output image is automatically sized to fit the entire rotated image without clipping.
    \\
    \\## Parameters
    \\- `angle` (float): Rotation angle in radians counter-clockwise.
    \\- `method` (`Interpolation`, optional): Interpolation method to use. Default is `Interpolation.BILINEAR`.
    \\
    \\## Examples
    \\```python
    \\import math
    \\img = Image.load("photo.png")
    \\
    \\# Rotate 45 degrees with default bilinear interpolation
    \\rotated = img.rotate(math.radians(45))
    \\
    \\# Rotate 90 degrees with nearest neighbor (faster, lower quality)
    \\rotated = img.rotate(math.radians(90), Interpolation.NEAREST_NEIGHBOR)
    \\
    \\# Rotate -30 degrees with Lanczos (slower, higher quality)
    \\rotated = img.rotate(math.radians(-30), Interpolation.LANCZOS)
    \\```
;

pub fn image_rotate(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var angle: f64 = 0;
    var method_value: c_long = 1; // Default to BILINEAR
    var kwlist = [_:null]?[*:0]u8{ @constCast("angle"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("d|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &angle, &method_value) == 0) {
        return null;
    }

    const tag_rotate = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };
    const method = tagToInterpolation(tag_rotate);

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).empty;
                img.rotate(allocator, @floatCast(angle), method, &out) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_warp_doc =
    \\Apply a geometric transform to the image.
    \\
    \\This method warps an image using a geometric transform (Similarity, Affine, or Projective).
    \\For each pixel in the output image, it applies the transform to find the corresponding
    \\location in the source image and samples using the specified interpolation method.
    \\
    \\## Parameters
    \\- `transform`: A geometric transform object (SimilarityTransform, AffineTransform, or ProjectiveTransform)
    \\- `shape` (optional): Output image shape as (rows, cols) tuple. Defaults to input image shape.
    \\- `method` (optional): Interpolation method. Defaults to Interpolation.BILINEAR.
    \\
    \\## Examples
    \\```python
    \\# Apply similarity transform
    \\from_points = [(0, 0), (100, 0), (100, 100)]
    \\to_points = [(10, 10), (110, 20), (105, 115)]
    \\transform = SimilarityTransform(from_points, to_points)
    \\warped = img.warp(transform)
    \\
    \\# Apply with custom output size and interpolation
    \\warped = img.warp(transform, shape=(512, 512), method=Interpolation.BICUBIC)
    \\```
;

pub fn image_warp(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var transform_obj: ?*c.PyObject = null;
    var shape_obj: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR

    const keywords = [_:null]?[*:0]const u8{ "transform", "shape", "method", null };
    const format = std.fmt.comptimePrint("O|Ol", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(@constCast(&keywords)), &transform_obj, &shape_obj, &method_value) == 0) {
        return null;
    }

    // Check if image is initialized
    if (self.py_image == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    const tag_warp = enum_utils.longToUnionTag(Interpolation, @intCast(method_value)) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };
    const method = tagToInterpolation(tag_warp);

    // Determine output dimensions
    var out_rows = self.py_image.?.rows();
    var out_cols = self.py_image.?.cols();

    if (shape_obj != null and shape_obj != c.Py_None()) {
        // Parse shape tuple
        if (c.PyTuple_Check(shape_obj) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "shape must be a tuple of (rows, cols)");
            return null;
        }

        if (c.PyTuple_Size(shape_obj) != 2) {
            c.PyErr_SetString(c.PyExc_ValueError, "shape must have exactly 2 elements");
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(shape_obj, 0);
        const cols_obj = c.PyTuple_GetItem(shape_obj, 1);

        const rows_val = c.PyLong_AsLong(rows_obj);
        const cols_val = c.PyLong_AsLong(cols_obj);

        if (rows_val <= 0 or cols_val <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Output dimensions must be positive");
            return null;
        }

        out_rows = @intCast(rows_val);
        out_cols = @intCast(cols_val);
    }

    // Create output Python image object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
    const result = @as(*ImageObject, @ptrCast(py_obj));

    // Create PyImage wrapper for the warped result
    const warped_pyimage = allocator.create(PyImageMod.PyImage) catch {
        c.Py_DECREF(py_obj);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate memory for warped image");
        return null;
    };

    // Apply warp using inline else to handle all image formats generically
    switch (self.py_image.?.data) {
        inline else => |img| {
            var warped_img: @TypeOf(img) = .empty;

            // Determine transform type and apply warp
            if (c.PyObject_IsInstance(transform_obj, @ptrCast(&transforms.SimilarityTransformType)) > 0) {
                const transform = @as(*transforms.SimilarityTransformObject, @ptrCast(transform_obj));
                const zignal_transform: zignal.SimilarityTransform(f32) = .{
                    .matrix = .init(.{
                        .{ @floatCast(transform.matrix[0][0]), @floatCast(transform.matrix[0][1]) },
                        .{ @floatCast(transform.matrix[1][0]), @floatCast(transform.matrix[1][1]) },
                    }),
                    .bias = .init(.{
                        .{@floatCast(transform.bias[0])},
                        .{@floatCast(transform.bias[1])},
                    }),
                };
                img.warp(allocator, zignal_transform, method, &warped_img, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    allocator.destroy(warped_pyimage);
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to warp image");
                    return null;
                };
            } else if (c.PyObject_IsInstance(transform_obj, @ptrCast(&transforms.AffineTransformType)) > 0) {
                const transform = @as(*transforms.AffineTransformObject, @ptrCast(transform_obj));
                const zignal_transform: zignal.AffineTransform(f32) = .{
                    .matrix = .init(.{
                        .{ @floatCast(transform.matrix[0][0]), @floatCast(transform.matrix[0][1]) },
                        .{ @floatCast(transform.matrix[1][0]), @floatCast(transform.matrix[1][1]) },
                    }),
                    .bias = .init(.{
                        .{@floatCast(transform.bias[0])},
                        .{@floatCast(transform.bias[1])},
                    }),
                    .allocator = allocator,
                };
                img.warp(allocator, zignal_transform, method, &warped_img, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    allocator.destroy(warped_pyimage);
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to warp image");
                    return null;
                };
            } else if (c.PyObject_IsInstance(transform_obj, @ptrCast(&transforms.ProjectiveTransformType)) > 0) {
                const transform = @as(*transforms.ProjectiveTransformObject, @ptrCast(transform_obj));
                const zignal_transform: zignal.ProjectiveTransform(f32) = .{
                    .matrix = .init(.{
                        .{ @floatCast(transform.matrix[0][0]), @floatCast(transform.matrix[0][1]), @floatCast(transform.matrix[0][2]) },
                        .{ @floatCast(transform.matrix[1][0]), @floatCast(transform.matrix[1][1]), @floatCast(transform.matrix[1][2]) },
                        .{ @floatCast(transform.matrix[2][0]), @floatCast(transform.matrix[2][1]), @floatCast(transform.matrix[2][2]) },
                    }),
                };
                img.warp(allocator, zignal_transform, method, &warped_img, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    allocator.destroy(warped_pyimage);
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to warp image");
                    return null;
                };
            } else {
                c.Py_DECREF(py_obj);
                allocator.destroy(warped_pyimage);
                c.PyErr_SetString(c.PyExc_TypeError, "transform must be a SimilarityTransform, AffineTransform, or ProjectiveTransform");
                return null;
            }

            // Create PyImage wrapper for the warped result based on image type
            warped_pyimage.* = switch (@TypeOf(img)) {
                zignal.Image(u8) => .{ .data = .{ .grayscale = warped_img }, .ownership = .owned },
                zignal.Image(Rgb) => .{ .data = .{ .rgb = warped_img }, .ownership = .owned },
                zignal.Image(Rgba) => .{ .data = .{ .rgba = warped_img }, .ownership = .owned },
                else => unreachable,
            };
        },
    }

    result.py_image = warped_pyimage;
    result.numpy_ref = null;
    result.parent_ref = null;

    return py_obj;
}

pub const image_flip_left_right_doc =
    \\Flip image left-to-right (horizontal mirror).
    \\
    \\Returns a new image that is a horizontal mirror of the original.
    \\```python
    \\flipped = img.flip_left_right()
    \\```
;

pub fn image_flip_left_right(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipLeftRight();
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_flip_top_bottom_doc =
    \\Flip image top-to-bottom (vertical mirror).
    \\
    \\Returns a new image that is a vertical mirror of the original.
    \\```python
    \\flipped = img.flip_top_bottom()
    \\```
;

pub fn image_flip_top_bottom(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipTopBottom();
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_crop_doc =
    \\Extract a rectangular region from the image.
    \\
    \\Returns a new Image containing the cropped region. Pixels outside the original
    \\image bounds are filled with transparent black (0, 0, 0, 0).
    \\
    \\## Parameters
    \\- `rect` (Rectangle): The rectangular region to extract
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\rect = Rectangle(10, 10, 110, 110)  # 100x100 region starting at (10, 10)
    \\cropped = img.crop(rect)
    \\print(cropped.rows, cropped.cols)  # 100 100
    \\```
;

pub fn image_crop(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse Rectangle argument
    var rect_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &rect_obj) == 0) {
        return null;
    }

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(f32, rect_obj) catch return null;

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |*img| {
                var out = @TypeOf(img.*).init(allocator, img.rows, img.cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                img.crop(allocator, rect, &out) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate cropped image");
                    return null;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_extract_doc =
    \\Extract a rotated rectangular region from the image and resample it.
    \\
    \\Returns a new Image containing the extracted and resampled region.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): The rectangular region to extract (before rotation)
    \\- `angle` (float, optional): Rotation angle in radians (counter-clockwise). Default: 0.0
    \\- `size` (int or tuple[int, int], optional). If not specified, uses the rectangle's dimensions.
    \\  - If int: output is a square of side `size`
    \\  - If tuple: output size as (rows, cols)
    \\- `method` (Interpolation, optional): Interpolation method. Default: BILINEAR
    \\
    \\## Examples
    \\```python
    \\import math
    \\img = Image.load("photo.png")
    \\rect = Rectangle(10, 10, 110, 110)
    \\
    \\# Extract without rotation
    \\extracted = img.extract(rect)
    \\
    \\# Extract with 45-degree rotation
    \\rotated = img.extract(rect, angle=math.radians(45))
    \\
    \\# Extract and resize to specific dimensions
    \\resized = img.extract(rect, size=(50, 75))
    \\
    \\# Extract to a 64x64 square
    \\square = img.extract(rect, size=64)
    \\```
;

pub fn image_extract(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var rect_obj: ?*c.PyObject = undefined;
    var angle: f64 = 0.0;
    var size_obj: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR

    var kwlist = [_:null]?[*:0]u8{ @constCast("rect"), @constCast("angle"), @constCast("size"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("O|dOl", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &rect_obj, &angle, &size_obj, &method_value) == 0) {
        return null;
    }

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(f32, rect_obj) catch return null;

    const tag_extract = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };
    const method = tagToInterpolation(tag_extract);

    // Determine output size
    var out_rows: usize = @intFromFloat(@round(rect.height()));
    var out_cols: usize = @intFromFloat(@round(rect.width()));

    if (size_obj != null and size_obj != c.Py_None()) {
        // Accept either an integer (square) or a tuple (rows, cols)
        if (c.PyLong_Check(size_obj) != 0) {
            const square = c.PyLong_AsLong(size_obj);
            if (square == -1 and c.PyErr_Occurred() != null) {
                return null;
            }
            if (square <= 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "size must be positive");
                return null;
            }
            out_rows = @intCast(square);
            out_cols = @intCast(square);
        } else if (c.PyTuple_Check(size_obj) != 0) {
            if (c.PyTuple_Size(size_obj) != 2) {
                c.PyErr_SetString(c.PyExc_ValueError, "size must be a 2-tuple of (rows, cols)");
                return null;
            }

            const rows_obj = c.PyTuple_GetItem(size_obj, 0);
            const cols_obj = c.PyTuple_GetItem(size_obj, 1);

            const rows = c.PyLong_AsLong(rows_obj);
            if (rows == -1 and c.PyErr_Occurred() != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "Rows must be an integer");
                return null;
            }
            if (rows <= 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "Rows must be positive");
                return null;
            }

            const cols = c.PyLong_AsLong(cols_obj);
            if (cols == -1 and c.PyErr_Occurred() != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "Cols must be an integer");
                return null;
            }
            if (cols <= 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "Cols must be positive");
                return null;
            }

            out_rows = @intCast(rows);
            out_cols = @intCast(cols);
        } else {
            c.PyErr_SetString(c.PyExc_TypeError, "size must be an int (square) or a tuple (rows, cols)");
            return null;
        }
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).init(allocator, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                img.extract(rect, @floatCast(angle), out, method);
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_insert_doc =
    \\Insert a source image into this image at a specified rectangle with optional rotation.
    \\
    \\This method modifies the image in-place.
    \\
    \\## Parameters
    \\- `source` (Image): The image to insert
    \\- `rect` (Rectangle): Destination rectangle where the source will be placed
    \\- `angle` (float, optional): Rotation angle in radians (counter-clockwise). Default: 0.0
    \\- `method` (Interpolation, optional): Interpolation method. Default: BILINEAR
    \\
    \\## Examples
    \\```python
    \\import math
    \\canvas = Image(500, 500)
    \\logo = Image.load("logo.png")
    \\
    \\# Insert at top-left
    \\rect = Rectangle(10, 10, 110, 110)
    \\canvas.insert(logo, rect)
    \\
    \\# Insert with rotation
    \\rect2 = Rectangle(200, 200, 300, 300)
    \\canvas.insert(logo, rect2, angle=math.radians(45))
    \\```
;

pub fn image_insert(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var source_obj: ?*c.PyObject = undefined;
    var rect_obj: ?*c.PyObject = undefined;
    var angle: f64 = 0.0;
    var method_value: c_long = 1; // Default to BILINEAR

    var kwlist = [_:null]?[*:0]u8{ @constCast("source"), @constCast("rect"), @constCast("angle"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("OO|dl", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &source_obj, &rect_obj, &angle, &method_value) == 0) {
        return null;
    }

    // Check if source is an Image object
    if (c.PyObject_IsInstance(source_obj, @ptrCast(getImageType())) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "source must be an Image object");
        return null;
    }

    const source = @as(*ImageObject, @ptrCast(source_obj.?));

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(f32, rect_obj) catch return null;

    const tag_insert = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };
    const method = tagToInterpolation(tag_insert);

    // Variant-aware in-place insert
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .grayscale => |*dst| {
                var src_u8: Image(u8) = undefined;
                if (source.py_image == null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "Source image not initialized");
                    return null;
                }
                const src_pimg = source.py_image.?;
                switch (src_pimg.data) {
                    .grayscale => |img| src_u8 = img,
                    .rgb => |img| src_u8 = img.convert(u8, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                    .rgba => |img| src_u8 = img.convert(u8, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                }
                defer src_u8.deinit(allocator);
                dst.insert(src_u8, rect, @floatCast(angle), method);
            },
            .rgb => |*dst| {
                var src_rgb: Image(Rgb) = undefined;
                if (source.py_image == null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "Source image not initialized");
                    return null;
                }
                const src_pimg = source.py_image.?;
                switch (src_pimg.data) {
                    .rgb => |img| src_rgb = img,
                    .grayscale => |img| src_rgb = img.convert(Rgb, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                    .rgba => |img| src_rgb = img.convert(Rgb, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                }
                defer src_rgb.deinit(allocator);
                dst.insert(src_rgb, rect, @floatCast(angle), method);
            },
            .rgba => |*dst| {
                var src_rgba: Image(Rgba) = undefined;
                if (source.py_image == null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "Source image not initialized");
                    return null;
                }
                const src_pimg = source.py_image.?;
                switch (src_pimg.data) {
                    .rgba => |img| src_rgba = img,
                    .grayscale => |img| src_rgba = img.convert(Rgba, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                    .rgb => |img| src_rgba = img.convert(Rgba, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                }
                dst.insert(src_rgba, rect, @floatCast(angle), method);
            },
        }
        const none = c.Py_None();
        c.Py_INCREF(none);
        return none;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}
