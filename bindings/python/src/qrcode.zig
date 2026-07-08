const std = @import("std");

const zignal = @import("zignal");
const qrcode = zignal.qrcode;

const enum_utils = @import("enum_utils.zig");
const image = @import("image.zig");
const python = @import("python.zig");
const stub_metadata = @import("stub_metadata.zig");
const allocator = python.ctx.allocator;
const c = python.c;

// ============================================================================
// EC LEVEL ENUM
// ============================================================================

pub const ec_level_doc =
    \\QR code error correction level.
    \\
    \\Higher levels tolerate more damage at the cost of a larger symbol:
    \\LOW ~7%, MEDIUM ~15%, QUARTILE ~25%, HIGH ~30% of codewords recoverable.
;

pub const ec_level_values = [_]stub_metadata.EnumValueDoc{
    .{ .name = "LOW", .doc = "Recovers ~7% of damaged codewords" },
    .{ .name = "MEDIUM", .doc = "Recovers ~15% of damaged codewords" },
    .{ .name = "QUARTILE", .doc = "Recovers ~25% of damaged codewords" },
    .{ .name = "HIGH", .doc = "Recovers ~30% of damaged codewords" },
};

// ============================================================================
// QR DECODE RESULT TYPE
// ============================================================================

const qr_decode_result_doc =
    \\Result of decoding a QR code from an image.
    \\
    \\## Attributes
    \\- `data`: Decoded payload as bytes
    \\- `text`: Decoded payload as text (UTF-8, invalid bytes replaced)
    \\- `version`: QR version (1-40)
    \\- `ec_level`: Error correction level (comparable to EcLevel)
    \\- `corrected_errors`: Codewords repaired by error correction
    \\- `corners`: Image-space symbol corners as (x, y) tuples in order
    \\  top-left, top-right, bottom-left, bottom-right, or None
;

pub const QrDecodeResultObject = extern struct {
    ob_base: c.PyObject,
    /// Python bytes with the decoded payload.
    data: ?*c.PyObject,
    /// Python list of (x, y) tuples, or Py_None.
    corners: ?*c.PyObject,
    version: u8,
    ec_level: u8,
    corrected_errors: u32,
};

const qr_decode_result_new = python.genericNew(QrDecodeResultObject);

fn qr_decode_result_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;
    python.setTypeError("QrDecodeResult objects (created by qrcode_decode)", null);
    return -1;
}

fn qrDecodeResultDeinit(self: *QrDecodeResultObject) void {
    if (self.data) |obj| c.Py_DecRef(obj);
    if (self.corners) |obj| c.Py_DecRef(obj);
    self.data = null;
    self.corners = null;
}

const qr_decode_result_dealloc = python.genericDealloc(QrDecodeResultObject, qrDecodeResultDeinit);

fn qr_decode_result_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(QrDecodeResultObject, self_obj);
    const len = if (self.data) |obj| c.PyBytes_Size(obj) else 0;
    var buffer: [128]u8 = undefined;
    const slice = std.fmt.bufPrintSentinel(&buffer, "QrDecodeResult(version={d}, ec_level={d}, data={d} bytes)", .{
        self.version, self.ec_level, len,
    }, 0) catch return python.create("QrDecodeResult(...)");
    return python.create(slice);
}

fn qr_decode_result_get_text(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(QrDecodeResultObject, self_obj);
    const obj = self.data orelse return python.none();
    var ptr: [*c]u8 = undefined;
    var size: c.Py_ssize_t = undefined;
    if (c.PyBytes_AsStringAndSize(obj, &ptr, &size) != 0) return null;
    return c.PyUnicode_DecodeUTF8(ptr, size, "replace");
}

/// Converter for getterOptionalPtr fields that hold an owned Python object.
fn increfObject(obj: *c.PyObject) ?*c.PyObject {
    c.Py_IncRef(obj);
    return obj;
}

var qr_decode_result_getset = python.toPyGetSetDefArray(&qr_decode_result_properties_metadata);

pub var QrDecodeResultType = python.buildTypeObject(.{
    .name = "zignal.QrDecodeResult",
    .basicsize = @sizeOf(QrDecodeResultObject),
    .doc = qr_decode_result_doc,
    .getset = &qr_decode_result_getset,
    .new = qr_decode_result_new,
    .init = qr_decode_result_init,
    .dealloc = qr_decode_result_dealloc,
    .repr = qr_decode_result_repr,
});

pub const qr_decode_result_properties_metadata = [_]python.PropertyWithMetadata{
    .{ .name = "data", .get = python.getterOptionalPtr(QrDecodeResultObject, "data", increfObject), .set = null, .doc = "Decoded payload as bytes", .type = "bytes" },
    .{ .name = "text", .get = @ptrCast(&qr_decode_result_get_text), .set = null, .doc = "Decoded payload as text (UTF-8, invalid bytes replaced)", .type = "str" },
    .{ .name = "version", .get = python.getterForField(QrDecodeResultObject, "version"), .set = null, .doc = "QR version (1-40)", .type = "int" },
    .{ .name = "ec_level", .get = python.getterForField(QrDecodeResultObject, "ec_level"), .set = null, .doc = "Error correction level (comparable to EcLevel)", .type = "int" },
    .{ .name = "corrected_errors", .get = python.getterForField(QrDecodeResultObject, "corrected_errors"), .set = null, .doc = "Codewords repaired by error correction", .type = "int" },
    .{ .name = "corners", .get = python.getterOptionalPtr(QrDecodeResultObject, "corners", increfObject), .set = null, .doc = "Symbol corners as (x, y) tuples (TL, TR, BL, BR), or None", .type = "list[tuple[float, float]] | None" },
};

// ============================================================================
// MODULE FUNCTIONS
// ============================================================================

const qrcode_encode_doc =
    \\Encode text or bytes as a QR code image.
    \\
    \\Supports all 40 versions, the four error correction levels, and the
    \\numeric, alphanumeric, and byte modes (the densest mode is selected
    \\automatically).
    \\
    \\## Parameters
    \\- `data`: Payload to encode (str is encoded as UTF-8)
    \\- `ec_level`: Error correction level (default EcLevel.MEDIUM)
    \\- `version`: Force a QR version 1-40 (default: smallest that fits)
    \\- `module_size`: Pixels per module (default 8)
    \\- `quiet_zone`: Light border around the symbol in modules (default 4)
    \\
    \\## Returns
    \\Grayscale Image with the rendered symbol.
    \\
    \\## Examples
    \\```python
    \\img = zignal.qrcode_encode("https://github.com/arrufat/zignal")
    \\img.save("qr.png")
    \\```
;

fn qrcode_encode(self: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;
    const Params = struct {
        data: ?*c.PyObject,
        ec_level: ?*c.PyObject = null,
        version: ?*c.PyObject = null,
        module_size: c_long = qrcode.EncodeOptions.default.module_size,
        quiet_zone: c_long = qrcode.EncodeOptions.default.quiet_zone,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    // str is encoded as UTF-8; bytes pass through (may contain NUL).
    var payload: []const u8 = undefined;
    if (c.PyUnicode_Check(params.data) != 0) {
        var size: c.Py_ssize_t = undefined;
        const ptr = c.PyUnicode_AsUTF8AndSize(params.data, &size) orelse return null;
        payload = ptr[0..@intCast(size)];
    } else if (c.PyBytes_Check(params.data) != 0) {
        var ptr: [*c]u8 = undefined;
        var size: c.Py_ssize_t = undefined;
        if (c.PyBytes_AsStringAndSize(params.data, &ptr, &size) != 0) return null;
        payload = ptr[0..@intCast(size)];
    } else {
        python.setTypeError("str or bytes", params.data);
        return null;
    }

    var ec_level = qrcode.EncodeOptions.default.ec_level;
    if (params.ec_level != null and params.ec_level != c.Py_None()) {
        ec_level = enum_utils.pyToEnum(qrcode.EcLevel, params.ec_level.?) catch return null;
    }
    var version: ?u8 = null;
    if (params.version != null and params.version != c.Py_None()) {
        const value = python.parse(c_long, params.version.?) catch return null;
        version = python.validateRange(u8, value, 1, 40, "version") catch return null;
    }
    const module_size = python.validatePositive(u32, params.module_size, "module_size") catch return null;
    const quiet_zone = python.validateNonNegative(u32, params.quiet_zone, "quiet_zone") catch return null;

    const img = qrcode.encode(allocator, payload, .{
        .ec_level = ec_level,
        .version = version,
        .module_size = module_size,
        .quiet_zone = quiet_zone,
    }) catch |err| {
        switch (err) {
            error.DataTooLarge => python.setValueError("data too long for a QR code", .{}),
            else => python.setZigError(err),
        }
        return null;
    };
    return @ptrCast(image.moveImageToPython(img));
}

const qrcode_decode_doc =
    \\Decode a QR code from an image.
    \\
    \\Handles photographs (perspective distortion, uneven lighting, moderate
    \\blur) as well as clean generated images, in any rotation, mirrored or
    \\not. Color images are converted to grayscale internally.
    \\
    \\## Parameters
    \\- `image`: Image to scan
    \\
    \\## Returns
    \\QrDecodeResult, or None when no QR code is found.
    \\
    \\## Examples
    \\```python
    \\result = zignal.qrcode_decode(zignal.Image.load("photo.jpg"))
    \\if result is not None:
    \\    print(result.text)
    \\```
;

fn qrcode_decode(self: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;
    const Params = struct {
        image: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    if (c.PyObject_IsInstance(params.image, @ptrCast(&image.ImageType)) != 1) {
        python.setTypeError("Image", params.image);
        return null;
    }
    const img_obj = python.safeCast(image.ImageObject, params.image);
    const pimg = img_obj.py_image orelse {
        python.setValueError("Image is not initialized", .{});
        return null;
    };

    var result = (switch (pimg.data) {
        inline else => |img| qrcode.decode(allocator, img),
    } catch |err| {
        python.setZigError(err);
        return null;
    }) orelse return python.none();
    defer result.deinit(allocator);

    const py_obj = c.PyType_GenericAlloc(@ptrCast(&QrDecodeResultType), 0) orelse return null;
    const obj = python.safeCast(QrDecodeResultObject, py_obj);
    obj.version = result.version;
    obj.ec_level = @intFromEnum(result.ec_level);
    obj.corrected_errors = result.corrected_errors;
    obj.data = null;
    obj.corners = null;

    obj.data = c.PyBytes_FromStringAndSize(@ptrCast(result.data.ptr), @intCast(result.data.len)) orelse {
        c.Py_DecRef(py_obj);
        return null;
    };
    if (result.corners) |corners| {
        obj.corners = python.listFromSliceCustom(zignal.Point(2, f32), &corners, struct {
            fn toPythonTuple(corner: zignal.Point(2, f32), _: usize) ?*c.PyObject {
                return python.create(corner);
            }
        }.toPythonTuple) orelse {
            c.Py_DecRef(py_obj);
            return null;
        };
    }
    return py_obj;
}

pub const qrcode_functions_metadata = [_]python.FunctionWithMetadata{
    .{
        .name = "qrcode_encode",
        .meth = @ptrCast(&qrcode_encode),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = qrcode_encode_doc,
        .params = "data: str | bytes, ec_level: EcLevel = EcLevel.MEDIUM, version: int | None = None, module_size: int = 8, quiet_zone: int = 4",
        .returns = "Image",
    },
    .{
        .name = "qrcode_decode",
        .meth = @ptrCast(&qrcode_decode),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = qrcode_decode_doc,
        .params = "image: Image",
        .returns = "QrDecodeResult | None",
    },
};
