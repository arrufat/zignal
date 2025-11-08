const zignal = @import("zignal");
const FeatureDistributionMatching = zignal.FeatureDistributionMatching;
const Rgb = zignal.Rgb;

const image = @import("image.zig");
const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

// FeatureDistributionMatching Python object
pub const FeatureDistributionMatchingObject = extern struct {
    ob_base: c.PyObject,
    // Store a pointer to the heap-allocated FDM struct
    fdm_ptr: ?*FeatureDistributionMatching(Rgb),
};

// Using genericNew helper for standard object creation
const fdm_new = py_utils.genericNew(FeatureDistributionMatchingObject);

fn fdm_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = args;
    _ = kwds;
    const self = py_utils.safeCast(FeatureDistributionMatchingObject, self_obj);

    // Create and initialize FDM using helper
    self.fdm_ptr = py_utils.createHeapObject(FeatureDistributionMatching(Rgb), .{allocator}) catch return -1;
    return 0;
}

// Helper function for custom cleanup
fn fdmDeinit(self: *FeatureDistributionMatchingObject) void {
    py_utils.destroyHeapObject(FeatureDistributionMatching(Rgb), self.fdm_ptr);
}

// Using genericDealloc helper
const fdm_dealloc = py_utils.genericDealloc(FeatureDistributionMatchingObject, fdmDeinit);

fn fdm_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(FeatureDistributionMatchingObject, self_obj);

    if (self.fdm_ptr == null) {
        return c.PyUnicode_FromString("FeatureDistributionMatching(uninitialized)");
    }

    return c.PyUnicode_FromString("FeatureDistributionMatching()");
}

// set_target method
const set_target_doc =
    \\Set the target image whose distribution will be matched.
    \\
    \\This method computes and stores the target distribution statistics (mean and covariance)
    \\for reuse across multiple source images. This is more efficient than recomputing
    \\the statistics for each image when applying the same style to multiple images.
    \\
    \\## Parameters
    \\- `image` (`Image`): Target image providing the color distribution to match. Must be RGB.
    \\
    \\## Examples
    \\```python
    \\fdm = FeatureDistributionMatching()
    \\target = Image.load("sunset.png")
    \\fdm.set_target(target)
    \\```
;

fn fdm_set_target(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(FeatureDistributionMatchingObject, self_obj);

    const fdm_ptr = py_utils.validateNonNull(*FeatureDistributionMatching(Rgb), self.fdm_ptr, "FeatureDistributionMatching") catch return null;

    const Params = struct {
        image: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const target_obj = params.image;

    // Check if argument is an Image object and cast
    if (target_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Object is null");
        return null;
    }
    if (c.PyObject_IsInstance(target_obj, @ptrCast(&image.ImageType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Type mismatch");
        return null;
    }
    const target_img_obj = py_utils.safeCast(image.ImageObject, target_obj);

    // Accept only RGB format
    if (target_img_obj.py_image == null) {
        py_utils.setTypeError("Image object", target_obj);
        return null;
    }
    const target_rgb: zignal.Image(zignal.Rgb) = switch (target_img_obj.py_image.?.data) {
        .rgb => |imgv| imgv,
        else => {
            py_utils.setTypeError("RGB image", target_obj);
            return null;
        },
    };
    fdm_ptr.setTarget(target_rgb) catch |err| {
        switch (err) {
            error.OutOfMemory => py_utils.setMemoryError("target image"),
            else => py_utils.setRuntimeError("Failed to set target image: {s}", .{@errorName(err)}),
        }
        return null;
    };
    // Success

    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// set_source method
const set_source_doc =
    \\Set the source image to be transformed.
    \\
    \\The source image will be modified in-place when update() is called.
    \\
    \\## Parameters
    \\- `image` (`Image`): Source image to be modified. Must be RGB.
    \\
    \\## Examples
    \\```python
    \\fdm = FeatureDistributionMatching()
    \\source = Image.load("portrait.png")
    \\fdm.set_source(source)
    \\```
;

fn fdm_set_source(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*FeatureDistributionMatchingObject, @ptrCast(self_obj.?));

    const fdm_ptr = py_utils.validateNonNull(*FeatureDistributionMatching(Rgb), self.fdm_ptr, "FeatureDistributionMatching") catch return null;

    const Params = struct {
        image: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const source_obj = params.image;

    // Check if argument is an Image object and cast
    if (source_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Object is null");
        return null;
    }
    if (c.PyObject_IsInstance(source_obj, @ptrCast(&image.ImageType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Type mismatch");
        return null;
    }
    const source_img_obj = py_utils.safeCast(image.ImageObject, source_obj);

    if (source_img_obj.py_image == null) {
        py_utils.setTypeError("Image object", source_obj);
        return null;
    }
    const src_rgb: zignal.Image(zignal.Rgb) = switch (source_img_obj.py_image.?.data) {
        .rgb => |imgv| imgv,
        else => {
            py_utils.setTypeError("RGB image", source_obj);
            return null;
        },
    };
    fdm_ptr.setSource(src_rgb) catch |err| {
        switch (err) {
            error.OutOfMemory => py_utils.setMemoryError("source image"),
        }
        return null;
    };
    // Success

    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// match method
const match_doc =
    \\Set both source and target images and apply the transformation.
    \\
    \\This is a convenience method that combines set_source(), set_target(), and update()
    \\into a single call. The source image is modified in-place.
    \\
    \\## Parameters
    \\- `source` (`Image`): Source image to be modified (RGB)
    \\- `target` (`Image`): Target image providing the color distribution to match (RGB)
    \\
    \\## Examples
    \\```python
    \\fdm = FeatureDistributionMatching()
    \\source = Image.load("portrait.png")
    \\target = Image.load("sunset.png")
    \\fdm.match(source, target)  # source is now modified
    \\source.save("portrait_sunset.png")
    \\```
;

fn fdm_match(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*FeatureDistributionMatchingObject, @ptrCast(self_obj.?));

    const fdm_ptr = py_utils.validateNonNull(*FeatureDistributionMatching(Rgb), self.fdm_ptr, "FeatureDistributionMatching") catch return null;

    const Params = struct {
        source: ?*c.PyObject,
        target: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;
    const source_obj = params.source;
    const target_obj = params.target;

    // Check if both arguments are Image objects
    if (c.PyObject_IsInstance(source_obj, @ptrCast(&image.ImageType)) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "First argument must be an Image object");
        return null;
    }

    if (c.PyObject_IsInstance(target_obj, @ptrCast(&image.ImageType)) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "Second argument must be an Image object");
        return null;
    }

    // Cast to ImageObject
    const source_img_obj = @as(*image.ImageObject, @ptrCast(source_obj.?));
    const target_img_obj = @as(*image.ImageObject, @ptrCast(target_obj.?));

    // Accept only RGB format
    if (source_img_obj.py_image == null or target_img_obj.py_image == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Source and target must be Image objects");
        return null;
    }
    const src_rgb2: zignal.Image(zignal.Rgb) = switch (source_img_obj.py_image.?.data) {
        .rgb => |imgv| imgv,
        else => {
            py_utils.setTypeError("RGB image", source_obj);
            return null;
        },
    };
    const dst_rgb2: zignal.Image(zignal.Rgb) = switch (target_img_obj.py_image.?.data) {
        .rgb => |imgv| imgv,
        else => {
            py_utils.setTypeError("RGB image", target_obj);
            return null;
        },
    };

    // Call match
    fdm_ptr.match(src_rgb2, dst_rgb2) catch |err| {
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory during match"),
            error.NoTargetSet => c.PyErr_SetString(c.PyExc_RuntimeError, "No target image set"),
            error.NoSourceSet => c.PyErr_SetString(c.PyExc_RuntimeError, "No source image set"),
            else => c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to match images"),
        }
        return null;
    };

    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// update method
const update_doc =
    \\Apply the feature distribution matching transformation.
    \\
    \\This method modifies the source image in-place to match the target distribution.
    \\Both source and target must be set before calling this method.
    \\
    \\## Raises
    \\- `RuntimeError`: If source or target has not been set
    \\
    \\## Examples
    \\```python
    \\fdm = FeatureDistributionMatching()
    \\fdm.set_target(target)
    \\fdm.set_source(source)
    \\fdm.update()  # source is now modified
    \\```
    \\
    \\### Batch processing
    \\```python
    \\fdm.set_target(style_image)
    \\for img in images:
    \\    fdm.set_source(img)
    \\    fdm.update()  # Each img is modified in-place
    \\```
;

fn fdm_update(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*FeatureDistributionMatchingObject, @ptrCast(self_obj.?));

    if (self.fdm_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "FeatureDistributionMatching not initialized");
        return null;
    }

    // Apply the transformation
    self.fdm_ptr.?.update() catch |err| {
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory during update"),
            error.NoTargetSet => c.PyErr_SetString(c.PyExc_RuntimeError, "No target image set. Call set_target() or match() first"),
            error.NoSourceSet => c.PyErr_SetString(c.PyExc_RuntimeError, "No source image set. Call set_source() or match() first"),
            else => c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to update FDM transformation"),
        }
        return null;
    };

    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// Method definitions with metadata
pub const fdm_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "set_target",
        .meth = @ptrCast(&fdm_set_target),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = set_target_doc,
        .params = "self, image: Image",
        .returns = "None",
    },
    .{
        .name = "set_source",
        .meth = @ptrCast(&fdm_set_source),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = set_source_doc,
        .params = "self, image: Image",
        .returns = "None",
    },
    .{
        .name = "match",
        .meth = @ptrCast(&fdm_match),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = match_doc,
        .params = "self, source: Image, target: Image",
        .returns = "None",
    },
    .{
        .name = "update",
        .meth = @ptrCast(&fdm_update),
        .flags = c.METH_NOARGS,
        .doc = update_doc,
        .params = "self",
        .returns = "None",
    },
};

// Generate PyMethodDef array from metadata
var fdm_methods = stub_metadata.toPyMethodDefArray(&fdm_methods_metadata);

// Class documentation - keep it simple
const fdm_class_doc = "Feature Distribution Matching for image style transfer.";

// Init documentation - detailed explanation
pub const fdm_init_doc =
    \\Initialize a new FeatureDistributionMatching instance.
    \\
    \\Creates a new FDM instance that can be used to transfer color distributions
    \\between images. The instance maintains internal state for efficient batch
    \\processing of multiple images with the same target distribution.
    \\
    \\## Examples
    \\```python
    \\# Create an FDM instance
    \\fdm = FeatureDistributionMatching()
    \\
    \\# Single image transformation
    \\source = Image.load("portrait.png")
    \\target = Image.load("sunset.png")
    \\fdm.match(source, target)  # source is modified in-place
    \\source.save("portrait_sunset.png")
    \\
    \\# Batch processing with same style
    \\style = Image.load("style_reference.png")
    \\fdm.set_target(style)
    \\for filename in image_files:
    \\    img = Image.load(filename)
    \\    fdm.set_source(img)
    \\    fdm.update()
    \\    img.save(f"styled_{filename}")
    \\```
    \\
    \\## Notes
    \\- The algorithm matches mean and covariance of pixel distributions
    \\- Target statistics are computed once and can be reused for multiple sources
    \\- See: https://facebookresearch.github.io/dino/blog/
;

// Special methods metadata for stub generation
pub const fdm_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self",
        .returns = "None",
        .doc = fdm_init_doc,
    },
};

// Using buildTypeObject helper for cleaner initialization
pub var FeatureDistributionMatchingType = py_utils.buildTypeObject(.{
    .name = "zignal.FeatureDistributionMatching",
    .basicsize = @sizeOf(FeatureDistributionMatchingObject),
    .doc = fdm_class_doc,
    .methods = @ptrCast(&fdm_methods),
    .new = fdm_new,
    .init = fdm_init,
    .dealloc = fdm_dealloc,
    .repr = fdm_repr,
});
