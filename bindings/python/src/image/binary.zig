//! Binary image utilities exposed to Python

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const BinaryKernel = zignal.BinaryKernel;

const python = @import("../python.zig");
const allocator = python.ctx.allocator;
const c = python.c;

const ImageObject = @import("../image.zig").ImageObject;
const PyImage = @import("../PyImage.zig");
const moveImageToPython = @import("../image.zig").moveImageToPython;

const GrayscaleHandle = struct {
    owned: ?Image(u8) = null,
    view: *Image(u8),
};

fn prepareGrayscale(pimg: *PyImage) ?GrayscaleHandle {
    var handle = GrayscaleHandle{ .view = undefined };
    switch (pimg.data) {
        .gray => |*img| {
            handle.view = img;
        },
        .rgb => |*img| {
            const converted = img.convert(u8, allocator) catch {
                python.setMemoryError("image conversion");
                return null;
            };
            handle.owned = converted;
            handle.view = &handle.owned.?;
        },
        .rgba => |*img| {
            const converted = img.convert(u8, allocator) catch {
                python.setMemoryError("image conversion");
                return null;
            };
            handle.owned = converted;
            handle.view = &handle.owned.?;
        },
    }
    return handle;
}

fn squareKernel(kernel_size: usize) ?struct {
    storage: []u8,
    kernel: BinaryKernel,
} {
    if (kernel_size == 0 or kernel_size % 2 == 0) {
        python.setValueError("kernel_size must be a positive odd integer", .{});
        return null;
    }
    const total = kernel_size * kernel_size;
    const data = allocator.alloc(u8, total) catch {
        python.setMemoryError("kernel allocation");
        return null;
    };
    @memset(data, 1);
    return .{ .storage = data, .kernel = BinaryKernel.init(kernel_size, kernel_size, data) };
}

pub const image_threshold_otsu_doc =
    \\Binarize the image using Otsu's method.
    \\
    \\The input is converted to grayscale if needed. Returns a tuple containing the
    \\binary image (0 or 255 values) and the threshold chosen by the algorithm.
    \\
    \\## Returns
    \\- `tuple[Image, int]`: (binary image, threshold)
    \\
    \\## Examples
    \\```python
    \\binary, threshold = img.threshold_otsu()
    \\print(threshold)
    \\```
;

pub fn image_threshold_otsu(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = python.safeCast(ImageObject, self_obj);

    if (self.py_image == null) {
        python.setValueError("Image not initialized", .{});
        return null;
    }

    const handle_opt = prepareGrayscale(self.py_image.?) orelse return null;
    var handle = handle_opt;
    if (handle.owned) |*owned| {
        handle.view = owned;
    }
    defer if (handle.owned) |*owned| owned.deinit(allocator);

    const out = Image(u8).initLike(allocator, handle.view.*) catch {
        python.setMemoryError("threshold operation");
        return null;
    };
    const threshold = handle.view.thresholdOtsu(allocator, out) catch {
        python.setMemoryError("threshold operation");
        return null;
    };

    const binary_obj = moveImageToPython(out) orelse return null;
    const tuple = c.PyTuple_New(2) orelse {
        // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(binary_obj)));
        python.setMemoryError("return tuple");
        return null;
    };

    _ = c.PyTuple_SetItem(tuple, 0, @ptrCast(binary_obj));
    const threshold_obj = python.create(threshold);
    if (threshold_obj == null) {
        c.Py_DECREF(tuple);
        return null;
    }
    _ = c.PyTuple_SetItem(tuple, 1, threshold_obj);
    return tuple;
}

pub const image_threshold_adaptive_mean_doc =
    \\Adaptive mean thresholding producing a binary image.
    \\
    \\Pixels are compared to the mean of a local window (square of size `2*radius+1`).
    \\Values greater than `mean - c` become 255, others become 0.
    \\
    \\## Parameters
    \\- `radius` (int, optional): Neighborhood radius. Must be > 0. Default: 6.
    \\- `c` (float, optional): Subtracted constant. Default: 5.0.
    \\
    \\## Returns
    \\- `Image`: Binary image with values 0 or 255.
;

pub fn image_threshold_adaptive_mean(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);

    if (self.py_image == null) {
        python.setValueError("Image not initialized", .{});
        return null;
    }

    const Params = struct {
        radius: c_long = 6,
        c: f64 = 5.0,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const radius_long = params.radius;
    const c_value = params.c;

    if (!std.math.isFinite(c_value)) {
        python.setValueError("c must be finite", .{});
        return null;
    }

    const radius = python.validatePositive(usize, radius_long, "radius") catch return null;

    const handle_opt = prepareGrayscale(self.py_image.?) orelse return null;
    var handle = handle_opt;
    if (handle.owned) |*owned| {
        handle.view = owned;
    }
    defer if (handle.owned) |*owned| owned.deinit(allocator);

    const out = Image(u8).initLike(allocator, handle.view.*) catch {
        python.setMemoryError("adaptive threshold operation");
        return null;
    };
    handle.view.thresholdAdaptiveMean(allocator, radius, @floatCast(c_value), out) catch |err| {
        switch (err) {
            error.InvalidRadius => python.setValueError("radius must be > 0", .{}),
            else => python.setMemoryError("threshold operation"),
        }
        return null;
    };

    return @ptrCast(moveImageToPython(out) orelse return null);
}

fn morphologyCommon(
    self: *ImageObject,
    kernel_size_long: c_long,
    iterations_long: c_long,
    op: enum { dilate, erode, open, close },
) ?*c.PyObject {
    if (self.py_image == null) {
        python.setValueError("Image not initialized", .{});
        return null;
    }

    const kernel_size = python.validatePositive(usize, kernel_size_long, "kernel_size") catch return null;
    const iterations = python.validateNonNegative(usize, iterations_long, "iterations") catch return null;

    const kernel_bundle = squareKernel(kernel_size) orelse return null;
    defer allocator.free(kernel_bundle.storage);

    const handle_opt = prepareGrayscale(self.py_image.?) orelse return null;
    var handle = handle_opt;
    if (handle.owned) |*owned| {
        handle.view = owned;
    }
    defer if (handle.owned) |*owned| owned.deinit(allocator);

    const kernel = kernel_bundle.kernel;

    const out = Image(u8).initLike(allocator, handle.view.*) catch {
        python.setMemoryError("morphological operation");
        return null;
    };
    const result = switch (op) {
        .dilate => handle.view.dilateBinary(allocator, kernel, iterations, out),
        .erode => handle.view.erodeBinary(allocator, kernel, iterations, out),
        .open => handle.view.openBinary(allocator, kernel, iterations, out),
        .close => handle.view.closeBinary(allocator, kernel, iterations, out),
    };

    result catch {
        python.setMemoryError("morphological operation");
        return null;
    };

    return @ptrCast(moveImageToPython(out) orelse return null);
}

pub const image_dilate_binary_doc =
    \\Dilate a binary image using a square structuring element.
    \\
    \\## Parameters
    \\- `kernel_size` (int, optional): Side length of the square element (odd, >= 1). Default: 3.
    \\- `iterations` (int, optional): Number of passes. Default: 1.
    \\
    \\## Returns
    \\- `Image`: Dilated binary image.
;

pub fn image_dilate_binary(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    const Params = struct {
        kernel_size: c_long = 3,
        iterations: c_long = 1,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return morphologyCommon(self, params.kernel_size, params.iterations, .dilate);
}

pub const image_erode_binary_doc =
    \\Erode a binary image using a square structuring element.
    \\
    \\Same parameters as `dilate_binary`.
;

pub fn image_erode_binary(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    const Params = struct {
        kernel_size: c_long = 3,
        iterations: c_long = 1,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return morphologyCommon(self, params.kernel_size, params.iterations, .erode);
}

pub const image_open_binary_doc =
    \\Perform binary opening (erosion followed by dilation).
    \\
    \\Useful for removing isolated noise while preserving overall shapes.
;

pub fn image_open_binary(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    const Params = struct {
        kernel_size: c_long = 3,
        iterations: c_long = 1,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return morphologyCommon(self, params.kernel_size, params.iterations, .open);
}

pub const image_close_binary_doc =
    \\Perform binary closing (dilation followed by erosion).
    \\
    \\Useful for filling small holes and connecting nearby components.
;

pub fn image_close_binary(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    const Params = struct {
        kernel_size: c_long = 3,
        iterations: c_long = 1,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return morphologyCommon(self, params.kernel_size, params.iterations, .close);
}
