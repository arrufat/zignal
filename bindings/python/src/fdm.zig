const std = @import("std");

const zignal = @import("zignal");

const image = @import("image.zig");
const py_utils = @import("py_utils.zig");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// Documentation for the feature_distribution_match function
pub const feature_distribution_match_doc =
    \\feature_distribution_match(source, reference, /)
    \\--
    \\
    \\Apply Feature Distribution Matching (FDM) to transfer color/style from reference to source image.
    \\
    \\This function modifies the source image in-place to match the color distribution
    \\(mean and covariance) of the reference image while preserving the structure of the source.
    \\
    \\Parameters
    \\----------
    \\source : Image
    \\    Source image to be modified (modified in-place)
    \\reference : Image
    \\    Reference image providing target color distribution
    \\
    \\Returns
    \\-------
    \\None
    \\    This function modifies the source image in-place
    \\
    \\Examples
    \\--------
    \\>>> src_img = Image.load("source.png")
    \\>>> ref_img = Image.load("reference.png")
    \\>>> zignal.feature_distribution_match(src_img, ref_img)
    \\>>> src_img.save("result.png")
;

pub fn feature_distribution_match(self: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;

    var src_obj: ?*c.PyObject = undefined;
    var ref_obj: ?*c.PyObject = undefined;

    const format = std.fmt.comptimePrint("OO", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &src_obj, &ref_obj) == 0) {
        return null;
    }

    // Check if both arguments are Image objects
    if (c.PyObject_IsInstance(src_obj, @ptrCast(&image.ImageType)) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "First argument must be an Image object");
        return null;
    }

    if (c.PyObject_IsInstance(ref_obj, @ptrCast(&image.ImageType)) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "Second argument must be an Image object");
        return null;
    }

    // Cast to ImageObject
    const src_img_obj = @as(*image.ImageObject, @ptrCast(src_obj.?));
    const ref_img_obj = @as(*image.ImageObject, @ptrCast(ref_obj.?));

    // Check if images are initialized
    if (src_img_obj.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Source image is not initialized");
        return null;
    }

    if (ref_img_obj.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Reference image is not initialized");
        return null;
    }

    var arena = py_utils.createArenaAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Call the FDM function
    zignal.featureDistributionMatch(zignal.Rgba, allocator, src_img_obj.image_ptr.?.*, ref_img_obj.image_ptr.?.*) catch |err| {
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory during feature distribution matching"),
        }
        return null;
    };

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}
