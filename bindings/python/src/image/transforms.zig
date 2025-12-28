//! Geometric transformations for Image objects

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);
const Rgb = zignal.Rgb(u8);
const Gray = zignal.Gray(u8);
const Interpolation = zignal.Interpolation;
const Blending = zignal.Blending;

const py_utils = @import("../py_utils.zig");
const allocator = py_utils.ctx.allocator;
const c = py_utils.c;
const enum_utils = @import("../enum_utils.zig");

const transforms = @import("../transforms.zig");
const moveImageToPython = @import("../image.zig").moveImageToPython;
const PyImageMod = @import("../PyImage.zig");
const PyImage = PyImageMod.PyImage;

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
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return error.ImageNotInitialized;
    return self.py_image.?.dispatch(.{ scale, method }, struct {
        fn apply(img: anytype, s: f32, m: Interpolation) !*ImageObject {
            const out = img.scale(allocator, s, m) catch |err| return mapScaleError(err);
            return moveImageToPython(out) orelse error.OutOfMemory;
        }
    }.apply);
}

fn image_reshape(self: *ImageObject, rows: usize, cols: usize, method: Interpolation) !*ImageObject {
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return error.ImageNotInitialized;
    return self.py_image.?.dispatch(.{ rows, cols, method }, struct {
        fn apply(img: anytype, r: usize, col: usize, m: Interpolation) !*ImageObject {
            const out = @TypeOf(img.*).init(allocator, r, col) catch return error.OutOfMemory;
            img.resize(allocator, out, m) catch return error.OutOfMemory;
            return moveImageToPython(out) orelse error.OutOfMemory;
        }
    }.apply);
}

fn image_letterbox_shape(self: *ImageObject, rows: usize, cols: usize, method: Interpolation) !*ImageObject {
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return error.ImageNotInitialized;
    return self.py_image.?.dispatch(.{ rows, cols, method }, struct {
        fn apply(img: anytype, r: usize, col: usize, m: Interpolation) !*ImageObject {
            var out = @TypeOf(img.*).init(allocator, r, col) catch return error.OutOfMemory;
            _ = img.letterbox(allocator, &out, m) catch {
                out.deinit(allocator);
                return error.OutOfMemory;
            };
            return moveImageToPython(out) orelse error.OutOfMemory;
        }
    }.apply);
}

fn image_letterbox_square(self: *ImageObject, size: usize, method: Interpolation) !*ImageObject {
    return image_letterbox_shape(self, size, size, method);
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    // Parse arguments
    const Params = struct {
        size: ?*c.PyObject,
        method: c_long = 1,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const shape_or_scale = params.size;
    const method_value = params.method;

    if (shape_or_scale == null) {
        py_utils.setTypeError("size argument", null);
        return null;
    }

    const tag_resize = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        py_utils.setValueError("Invalid interpolation method", .{});
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
        const scale_pos = py_utils.validatePositive(f64, scale, "Scale factor") catch return null;

        const result = image_scale(self, @floatCast(scale_pos), method) catch return null;
        return @ptrCast(result);
    } else if (c.PyTuple_Check(shape_or_scale) != 0) {
        // It's a tuple of dimensions
        if (c.PyTuple_Size(shape_or_scale) != 2) {
            py_utils.setValueError("Size must be a 2-tuple of (rows, cols)", .{});
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(shape_or_scale, 0);
        const cols_obj = c.PyTuple_GetItem(shape_or_scale, 1);

        const rows = c.PyLong_AsLong(rows_obj);
        if (rows == -1 and c.PyErr_Occurred() != null) {
            py_utils.setTypeError("integer", rows_obj);
            return null;
        }

        const cols = c.PyLong_AsLong(cols_obj);
        if (cols == -1 and c.PyErr_Occurred() != null) {
            py_utils.setTypeError("integer", cols_obj);
            return null;
        }

        const rows_pos = py_utils.validatePositive(usize, rows, "Rows") catch return null;
        const cols_pos = py_utils.validatePositive(usize, cols, "Cols") catch return null;

        const result = image_reshape(self, rows_pos, cols_pos, method) catch return null;
        return @ptrCast(result);
    } else {
        py_utils.setTypeError("number or tuple", shape_or_scale);
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    // Parse arguments
    const Params = struct {
        size: ?*c.PyObject,
        method: c_long = 1,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const size = params.size;
    const method_value = params.method;

    if (size == null) {
        py_utils.setTypeError("size argument", null);
        return null;
    }

    const tag_letterbox = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        py_utils.setValueError("Invalid interpolation method", .{});
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
        const size_pos = py_utils.validatePositive(usize, square_size, "Size") catch return null;
        const result = image_letterbox_square(self, size_pos, method) catch return null;
        return @ptrCast(result);
    } else if (c.PyTuple_Check(size) != 0) {
        // It's a tuple for dimensions
        if (c.PyTuple_Size(size) != 2) {
            py_utils.setValueError("size must be a 2-tuple of (rows, cols)", .{});
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(size, 0);
        const cols_obj = c.PyTuple_GetItem(size, 1);

        if (c.PyLong_Check(rows_obj) == 0 or c.PyLong_Check(cols_obj) == 0) {
            py_utils.setTypeError("2-tuple", size);
            return null;
        }

        const rows = c.PyLong_AsLong(rows_obj);
        const cols = c.PyLong_AsLong(cols_obj);

        if ((rows == -1 or cols == -1) and c.PyErr_Occurred() != null) {
            return null;
        }

        const rows_pos = py_utils.validatePositive(usize, rows, "Rows") catch return null;
        const cols_pos = py_utils.validatePositive(usize, cols, "Cols") catch return null;

        const result = image_letterbox_shape(self, rows_pos, cols_pos, method) catch return null;
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
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    // Parse arguments
    const Params = struct {
        angle: f64,
        method: c_long = 1,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const angle = params.angle;
    const method_value = params.method;

    const tag_rotate = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        py_utils.setValueError("Invalid interpolation method", .{});
        return null;
    };
    const method = tagToInterpolation(tag_rotate);

    return self.py_image.?.dispatch(.{ angle, method }, struct {
        fn apply(img: anytype, a: f64, m: Interpolation) ?*c.PyObject {
            const out = img.rotate(allocator, @floatCast(a), m) catch {
                py_utils.setMemoryError("image rotate");
                return null;
            };
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    }.apply);
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
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    // Parse arguments
    const Params = struct {
        transform: ?*c.PyObject,
        shape: ?*c.PyObject = null,
        method: c_long = 1,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const transform_obj = params.transform;
    const shape_obj = params.shape;
    const method_value = params.method;

    const tag_warp = enum_utils.longToUnionTag(Interpolation, @intCast(method_value)) catch {
        py_utils.setValueError("Invalid interpolation method", .{});
        return null;
    };
    const method = tagToInterpolation(tag_warp);

    // Determine output dimensions
    var out_rows = self.py_image.?.rows();
    var out_cols = self.py_image.?.cols();

    if (shape_obj != null and shape_obj != c.Py_None()) {
        // Parse shape tuple
        if (c.PyTuple_Check(shape_obj) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "shape must be a 2-tuple of (rows, cols)");
            return null;
        }

        if (c.PyTuple_Size(shape_obj) != 2) {
            c.PyErr_SetString(c.PyExc_ValueError, "shape must be a 2-tuple of (rows, cols)");
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(shape_obj, 0);
        const cols_obj = c.PyTuple_GetItem(shape_obj, 1);

        const rows_val = c.PyLong_AsLong(rows_obj);
        const cols_val = c.PyLong_AsLong(cols_obj);

        out_rows = py_utils.validatePositive(usize, rows_val, "rows") catch return null;
        out_cols = py_utils.validatePositive(usize, cols_val, "cols") catch return null;
    }

    return self.py_image.?.dispatch(.{ transform_obj, method, out_rows, out_cols }, struct {
        fn apply(img: anytype, t_obj: ?*c.PyObject, m: Interpolation, orows: usize, ocols: usize) ?*c.PyObject {
            var warped_img: @TypeOf(img.*) = .empty;

            // Determine transform type and apply warp
            if (c.PyObject_IsInstance(t_obj, @ptrCast(&transforms.SimilarityTransformType)) > 0) {
                const transform = @as(*transforms.SimilarityTransformObject, @ptrCast(t_obj));
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
                img.warp(allocator, zignal_transform, m, &warped_img, orows, ocols) catch {
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to warp image");
                    return null;
                };
            } else if (c.PyObject_IsInstance(t_obj, @ptrCast(&transforms.AffineTransformType)) > 0) {
                const transform = @as(*transforms.AffineTransformObject, @ptrCast(t_obj));
                const zignal_transform: zignal.AffineTransform(f32) = .{
                    .matrix = .init(.{
                        .{ @floatCast(transform.matrix[0][0]), @floatCast(transform.matrix[0][1]) },
                        .{ @floatCast(transform.matrix[1][0]), @floatCast(transform.matrix[1][1]) },
                    }),
                    .bias = .init(.{
                        .{@floatCast(transform.bias[0])},
                        .{@floatCast(transform.bias[1])},
                    }),
                };
                img.warp(allocator, zignal_transform, m, &warped_img, orows, ocols) catch {
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to warp image");
                    return null;
                };
            } else if (c.PyObject_IsInstance(t_obj, @ptrCast(&transforms.ProjectiveTransformType)) > 0) {
                const transform = @as(*transforms.ProjectiveTransformObject, @ptrCast(t_obj));
                const zignal_transform: zignal.ProjectiveTransform(f32) = .{
                    .matrix = .init(.{
                        .{ @floatCast(transform.matrix[0][0]), @floatCast(transform.matrix[0][1]), @floatCast(transform.matrix[0][2]) },
                        .{ @floatCast(transform.matrix[1][0]), @floatCast(transform.matrix[1][1]), @floatCast(transform.matrix[1][2]) },
                        .{ @floatCast(transform.matrix[2][0]), @floatCast(transform.matrix[2][1]), @floatCast(transform.matrix[2][2]) },
                    }),
                };
                img.warp(allocator, zignal_transform, m, &warped_img, orows, ocols) catch {
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to warp image");
                    return null;
                };
            } else {
                c.PyErr_SetString(c.PyExc_TypeError, "transform must be a SimilarityTransform, AffineTransform, or ProjectiveTransform");
                return null;
            }

            return @ptrCast(moveImageToPython(warped_img) orelse return null);
        }
    }.apply);
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
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    return self.py_image.?.dispatch(.{}, struct {
        fn apply(img: anytype) ?*c.PyObject {
            var out = img.dupe(allocator) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                return null;
            };
            out.flipLeftRight();
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    }.apply);
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
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    return self.py_image.?.dispatch(.{}, struct {
        fn apply(img: anytype) ?*c.PyObject {
            var out = img.dupe(allocator) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                return null;
            };
            out.flipTopBottom();
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    }.apply);
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

pub fn image_crop(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    // Parse Rectangle argument
    const Params = struct {
        rect: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(f32, params.rect) catch return null;

    return self.py_image.?.dispatch(.{rect}, struct {
        fn apply(img: anytype, r: zignal.Rectangle(f32)) ?*c.PyObject {
            const out = img.crop(allocator, r) catch {
                py_utils.setMemoryError("cropped image");
                return null;
            };
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    }.apply);
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
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    // Parse arguments
    const Params = struct {
        rect: ?*c.PyObject,
        angle: f64 = 0.0,
        size: ?*c.PyObject = null,
        method: c_long = 1,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const rect_obj = params.rect;
    const angle = params.angle;
    const size_obj = params.size;
    const method_value = params.method;

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(f32, rect_obj) catch return null;

    const tag_extract = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        py_utils.setValueError("Invalid interpolation method", .{});
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
            const sq = py_utils.validatePositive(usize, square, "size") catch return null;
            out_rows = sq;
            out_cols = sq;
        } else if (c.PyTuple_Check(size_obj) != 0) {
            if (c.PyTuple_Size(size_obj) != 2) {
                py_utils.setValueError("size must be a 2-tuple of (rows, cols)", .{});
                return null;
            }

            const rows_obj = c.PyTuple_GetItem(size_obj, 0);
            const cols_obj = c.PyTuple_GetItem(size_obj, 1);

            const rows = c.PyLong_AsLong(rows_obj);
            if (rows == -1 and c.PyErr_Occurred() != null) {
                py_utils.setTypeError("integer", rows_obj);
                return null;
            }

            const cols = c.PyLong_AsLong(cols_obj);
            if (cols == -1 and c.PyErr_Occurred() != null) {
                py_utils.setTypeError("integer", cols_obj);
                return null;
            }

            out_rows = py_utils.validatePositive(usize, rows, "Rows") catch return null;
            out_cols = py_utils.validatePositive(usize, cols, "Cols") catch return null;
        } else {
            py_utils.setTypeError("int or tuple", size_obj);
            return null;
        }
    }

    return self.py_image.?.dispatch(.{ rect, angle, out_rows, out_cols, method }, struct {
        fn apply(img: anytype, r: zignal.Rectangle(f32), a: f64, orows: usize, ocols: usize, m: Interpolation) ?*c.PyObject {
            const out = @TypeOf(img.*).init(allocator, orows, ocols) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                return null;
            };
            img.extract(r, @floatCast(a), out, m);
            return @ptrCast(moveImageToPython(out) orelse return null);
        }
    }.apply);
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
    \\- `blend_mode` (Blending, optional): Compositing mode for RGBA images. Default: NONE
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
    const self = py_utils.safeCast(ImageObject, self_obj);
    py_utils.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    // Parse arguments
    const Params = struct {
        source: ?*c.PyObject,
        rect: ?*c.PyObject,
        angle: f64 = 0.0,
        method: c_long = 1,
        blend_mode: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const source_obj = params.source;
    const rect_obj = params.rect;
    const angle = params.angle;
    const method_value = params.method;
    const blend_obj = params.blend_mode;

    // Check if source is an Image object
    if (c.PyObject_IsInstance(source_obj, @ptrCast(getImageType())) <= 0) {
        py_utils.setTypeError("Image object", source_obj);
        return null;
    }

    const source = py_utils.safeCast(ImageObject, source_obj);

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(f32, rect_obj) catch return null;

    const tag_insert = enum_utils.longToUnionTag(Interpolation, method_value) catch {
        py_utils.setValueError("Invalid interpolation method", .{});
        return null;
    };
    const method = tagToInterpolation(tag_insert);

    var blend_mode: Blending = .none;
    if (blend_obj) |obj| {
        if (obj != c.Py_None()) {
            blend_mode = enum_utils.pyToEnum(Blending, obj) catch {
                py_utils.setValueError("Invalid blend_mode", .{});
                return null;
            };
        }
    }

    // Variant-aware in-place insert
    switch (self.py_image.?.data) {
        .gray => |*dst| {
            const src_pimg = source.py_image orelse {
                py_utils.setTypeError("initialized Image", source_obj);
                return null;
            };
            switch (src_pimg.data) {
                .gray => |img| dst.insert(img, rect, @floatCast(angle), method, blend_mode),
                .rgb => |img| {
                    var src_converted = img.convert(u8, allocator) catch {
                        py_utils.setMemoryError("source image conversion");
                        return null;
                    };
                    defer src_converted.deinit(allocator);
                    dst.insert(src_converted, rect, @floatCast(angle), method, blend_mode);
                },
                .rgba => |img| {
                    var src_converted = img.convert(u8, allocator) catch {
                        py_utils.setMemoryError("source image conversion");
                        return null;
                    };
                    defer src_converted.deinit(allocator);
                    dst.insert(src_converted, rect, @floatCast(angle), method, blend_mode);
                },
            }
        },
        .rgb => |*dst| {
            const src_pimg = source.py_image orelse {
                py_utils.setTypeError("initialized Image", source_obj);
                return null;
            };
            switch (src_pimg.data) {
                .gray => |img| {
                    var src_converted = img.convert(Rgb, allocator) catch {
                        py_utils.setMemoryError("source image conversion");
                        return null;
                    };
                    defer src_converted.deinit(allocator);
                    dst.insert(src_converted, rect, @floatCast(angle), method, blend_mode);
                },
                .rgb => |img| dst.insert(img, rect, @floatCast(angle), method, blend_mode),
                .rgba => |img| {
                    var src_converted = img.convert(Rgb, allocator) catch {
                        py_utils.setMemoryError("source image conversion");
                        return null;
                    };
                    defer src_converted.deinit(allocator);
                    dst.insert(src_converted, rect, @floatCast(angle), method, blend_mode);
                },
            }
        },
        .rgba => |*dst| {
            const src_pimg = source.py_image orelse {
                py_utils.setTypeError("initialized Image", source_obj);
                return null;
            };
            switch (src_pimg.data) {
                .gray => |img| {
                    var src_converted = img.convert(Rgba, allocator) catch {
                        py_utils.setMemoryError("source image conversion");
                        return null;
                    };
                    defer src_converted.deinit(allocator);
                    dst.insert(src_converted, rect, @floatCast(angle), method, blend_mode);
                },
                .rgb => |img| {
                    var src_converted = img.convert(Rgba, allocator) catch {
                        py_utils.setMemoryError("source image conversion");
                        return null;
                    };
                    defer src_converted.deinit(allocator);
                    dst.insert(src_converted, rect, @floatCast(angle), method, blend_mode);
                },
                .rgba => |img| dst.insert(img, rect, @floatCast(angle), method, blend_mode),
            }
        },
    }
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}
