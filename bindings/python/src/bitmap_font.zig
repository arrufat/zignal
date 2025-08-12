const std = @import("std");

const zignal = @import("zignal");
const BitmapFont = zignal.BitmapFont;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

pub const BitmapFontObject = extern struct {
    ob_base: c.PyObject,
    font: ?*BitmapFont,
};

// Cached singleton Python object for the built-in 8x8 font
var cached_font8x8: ?*c.PyObject = null;

fn bitmap_font_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*BitmapFontObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.font = null; // Initialize to null
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn bitmap_font_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*BitmapFontObject, @ptrCast(self_obj.?));

    if (self.font) |font| {
        font.deinit(allocator);
        allocator.destroy(font);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn bitmap_font_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self_obj;
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

fn bitmap_font_load(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var file_path: [*c]const u8 = undefined;

    if (c.PyArg_ParseTuple(args, "s", &file_path) == 0) {
        return null;
    }

    // Convert C string to Zig slice
    const path_slice = std.mem.span(file_path);

    // Create new BitmapFont instance
    const instance = c.PyObject_CallObject(@ptrCast(type_obj), null) orelse return null;
    const self = @as(*BitmapFontObject, @ptrCast(instance));

    // Allocate font on heap
    const font_ptr = allocator.create(BitmapFont) catch {
        c.Py_DECREF(instance);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate font");
        return null;
    };
    // Important: set the font pointer initially to prevent issues
    self.font = font_ptr;

    // Load font from file (loading all characters)
    font_ptr.* = BitmapFont.load(allocator, path_slice, .all) catch |err| {
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
        const self = @as(*BitmapFontObject, @ptrCast(instance));

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

// Methods metadata (used for both C API and stub generation)
pub const bitmap_font_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "load",
        .meth = @ptrCast(&bitmap_font_load),
        .flags = c.METH_VARARGS | c.METH_CLASS,
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

const bitmap_font_class_doc =
    "Bitmap font for text rendering. Supports BDF/PCF formats, including optional " ++
    "gzip-compressed files (.bdf.gz, .pcf.gz).";

pub var BitmapFontType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.BitmapFont",
    .tp_basicsize = @sizeOf(BitmapFontObject),
    .tp_dealloc = bitmap_font_dealloc,
    .tp_repr = bitmap_font_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = bitmap_font_class_doc,
    .tp_methods = @ptrCast(&bitmap_font_methods),
    .tp_new = bitmap_font_new,
};
