const std = @import("std");

const zignal = @import("zignal");
const BitmapFont = zignal.BitmapFont;

const py_utils = @import("py_utils.zig");
const ctx = py_utils.ctx;
const allocator = ctx.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

pub const BitmapFontObject = extern struct {
    ob_base: c.PyObject,
    font: ?*BitmapFont,
};

// Cached singleton Python object for the built-in 8x8 font
var cached_font8x8: ?*c.PyObject = null;

// Using genericNew helper for standard object creation
const bitmap_font_new = py_utils.genericNew(BitmapFontObject);

// Helper function for custom cleanup
fn bitmapFontDeinit(self: *BitmapFontObject) void {
    if (self.font) |font| {
        font.deinit(allocator);
        allocator.destroy(font);
    }
}

// Using genericDealloc helper
const bitmap_font_dealloc = py_utils.genericDealloc(BitmapFontObject, bitmapFontDeinit);

fn bitmap_font_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(BitmapFontObject, self_obj);

    if (self.font) |font| {
        // Create a formatted string with the font name
        var buffer: [256]u8 = undefined;
        const repr_str = std.fmt.bufPrintZ(&buffer, "BitmapFont(name=\"{s}\", width={d}, height={d})", .{
            font.name,
            font.char_width,
            font.char_height,
        }) catch {
            // Fall back to simple representation if formatting fails
            return c.PyUnicode_FromString("BitmapFont()");
        };
        return c.PyUnicode_FromString(repr_str.ptr);
    }

    return c.PyUnicode_FromString("BitmapFont()");
}

// Class method: load
const bitmap_font_load_doc =
    \\Load a bitmap font from file.
    \\
    \\Supports BDF (Bitmap Distribution Format) and PCF (Portable Compiled Format) files, including
    \\optionally gzip-compressed variants (e.g., `.bdf.gz`, `.pcf.gz`).
    \\
    \\## Parameters
    \\- `path` (str): Path to the font file
    \\
    \\## Examples
    \\```python
    \\font = BitmapFont.load("unifont.bdf")
    \\canvas.draw_text("Hello", (10, 10), font, (255, 255, 255))
    \\```
;

fn bitmap_font_load(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        path: [*c]const u8,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const file_path = params.path;

    // Convert C string to Zig slice
    const path_slice = std.mem.span(file_path);

    // Create new BitmapFont instance
    const instance = c.PyObject_CallObject(@ptrCast(type_obj), null) orelse return null;
    const self = py_utils.safeCast(BitmapFontObject, instance);

    // Allocate font on heap
    const font_ptr = allocator.create(BitmapFont) catch {
        c.Py_DECREF(instance);
        py_utils.setMemoryError("font");
        return null;
    };
    // Important: set the font pointer initially to prevent issues
    self.font = font_ptr;

    // Load font from file (loading all characters)
    font_ptr.* = BitmapFont.load(ctx.io, allocator, path_slice, .all) catch |err| {
        // Clean up on error
        allocator.destroy(font_ptr);
        self.font = null; // Clear the pointer
        c.Py_DECREF(instance);

        // Set appropriate Python exception based on error
        py_utils.setErrorWithPath(err, path_slice);
        return null;
    };

    return instance;
}

// Class method: font8x8 (default font)
const bitmap_font_font8x8_doc =
    \\Get the built-in default 8x8 bitmap font with all available characters.
    \\
    \\This font includes ASCII, extended ASCII, Greek, and box drawing characters.
    \\
    \\## Examples
    \\```python
    \\font = BitmapFont.font8x8()
    \\canvas.draw_text("Hello World!", (10, 10), font, (255, 255, 255))
    \\```
;

fn bitmap_font8x8(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    // Return a cached singleton instance; create on first call
    if (cached_font8x8 == null) {
        const instance = c.PyObject_CallObject(@ptrCast(type_obj), null) orelse return null;
        const self = py_utils.safeCast(BitmapFontObject, instance);

        // Allocate font on heap and create with all characters
        const font_ptr = allocator.create(BitmapFont) catch {
            c.Py_DECREF(instance);
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate font");
            return null;
        };

        font_ptr.* = zignal.font.font8x8.create(allocator, .all) catch {
            allocator.destroy(font_ptr);
            c.Py_DECREF(instance);
            c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to create font8x8 with all characters");
            return null;
        };

        self.font = font_ptr;
        cached_font8x8 = instance; // keep a strong ref for the lifetime of the module
    }
    // Return a new reference to the cached singleton
    c.Py_INCREF(cached_font8x8);
    return cached_font8x8;
}

fn fontNameToPyObject(font: *BitmapFont) ?*c.PyObject {
    return c.PyUnicode_FromStringAndSize(font.name.ptr, @intCast(font.name.len));
}

fn fontWidthToPyObject(font: *BitmapFont) ?*c.PyObject {
    return c.PyLong_FromLong(font.char_width);
}

fn fontHeightToPyObject(font: *BitmapFont) ?*c.PyObject {
    return c.PyLong_FromLong(font.char_height);
}

// Methods metadata (used for both C API and stub generation)
pub const bitmap_font_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "load",
        .meth = @ptrCast(&bitmap_font_load),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = bitmap_font_load_doc,
        .params = "cls, path: str",
        .returns = "BitmapFont",
    },
    .{
        .name = "font8x8",
        .meth = @ptrCast(&bitmap_font8x8),
        .flags = c.METH_NOARGS | c.METH_CLASS,
        .doc = bitmap_font_font8x8_doc,
        .params = "cls",
        .returns = "BitmapFont",
    },
};

var bitmap_font_methods = stub_metadata.toPyMethodDefArray(&bitmap_font_methods_metadata);

// Properties for BitmapFont
var bitmap_font_getsetters = [_]c.PyGetSetDef{
    .{
        .name = "name",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalPtr(BitmapFontObject, "font", fontNameToPyObject))),
        .set = null,
        .doc = "Font name",
        .closure = null,
    },
    .{
        .name = "width",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalPtr(BitmapFontObject, "font", fontWidthToPyObject))),
        .set = null,
        .doc = "Character width in pixels",
        .closure = null,
    },
    .{
        .name = "height",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalPtr(BitmapFontObject, "font", fontHeightToPyObject))),
        .set = null,
        .doc = "Character height in pixels",
        .closure = null,
    },
    .{ .name = null }, // Sentinel
};

const bitmap_font_class_doc =
    "Bitmap font for text rendering. Supports BDF/PCF formats, including optional " ++
    "gzip-compressed files (.bdf.gz, .pcf.gz).";

// Using buildTypeObject helper for cleaner initialization
pub var BitmapFontType = py_utils.buildTypeObject(.{
    .name = "zignal.BitmapFont",
    .basicsize = @sizeOf(BitmapFontObject),
    .doc = bitmap_font_class_doc,
    .methods = @ptrCast(&bitmap_font_methods),
    .getset = @ptrCast(&bitmap_font_getsetters),
    .new = bitmap_font_new,
    .dealloc = bitmap_font_dealloc,
    .repr = bitmap_font_repr,
});
