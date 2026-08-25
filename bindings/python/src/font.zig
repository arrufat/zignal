const std = @import("std");

const zignal = @import("zignal");
const Font = zignal.Font;

const python = @import("python.zig");
const ctx = python.ctx;
const allocator = ctx.allocator;
const c = python.c;

pub const FontObject = extern struct {
    ob_base: c.PyObject,
    font: ?*Font,
};

// Cached singleton Python object for the built-in 8x8 font
var cached_font8x8: ?*c.PyObject = null;

const font_new = python.genericNew(FontObject);

fn fontDeinit(self: *FontObject) void {
    if (self.font) |font| {
        font.deinit(allocator);
        allocator.destroy(font);
    }
}

const font_dealloc = python.genericDealloc(FontObject, fontDeinit);

/// Wraps an owned font in a new Python object, freeing the font on failure.
fn wrap(font: Font) ?*c.PyObject {
    var owned = font;
    const instance = c.PyObject_CallObject(@ptrCast(&FontType), null) orelse {
        owned.deinit(allocator);
        return null;
    };
    const self = python.safeCast(FontObject, instance);
    self.font = allocator.create(Font) catch {
        owned.deinit(allocator);
        c.Py_DecRef(instance);
        python.setMemoryError("font");
        return null;
    };
    self.font.?.* = owned;
    return instance;
}

fn font_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(FontObject, self_obj);
    const font = self.font orelse return python.create("Font()");
    var buffer: [256]u8 = undefined;
    const repr_str = switch (font.*) {
        .bitmap => |b| std.fmt.bufPrintSentinel(&buffer, "Font(kind=\"bitmap\", name=\"{s}\", width={d}, height={d})", .{ b.name, b.char_width, b.char_height }, 0),
        .vector => |v| std.fmt.bufPrintSentinel(&buffer, "Font(kind=\"vector\", units_per_em={d}, glyphs={d})", .{ v.units_per_em, v.num_glyphs }, 0),
    } catch return python.create("Font(...)");
    return python.create(repr_str);
}

const font_load_doc =
    \\Load a font from a file, detecting its format.
    \\
    \\Supports bitmap fonts in BDF and PCF format (optionally gzip-compressed: `.bdf.gz`,
    \\`.pcf.gz`), TrueType fonts (`.ttf`) and CFF OpenType fonts (`.otf`).
    \\
    \\## Parameters
    \\- `path` (str): Path to the font file
    \\
    \\## Examples
    \\```python
    \\font = Font.load("DejaVuSans.ttf")
    \\canvas.draw_text("Hello", (10, 10), (255, 255, 255), font, size=24, mode=DrawMode.SOFT)
    \\```
;

fn font_load(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;
    const Params = struct {
        path: [*c]const u8,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const path = std.mem.span(params.path);

    const font = Font.load(ctx.io, allocator, path) catch |err| {
        python.setErrorWithPath(err, path);
        return null;
    };
    return wrap(font);
}

const font_save_doc =
    \\Save a bitmap font to a file.
    \\
    \\Supports BDF (`.bdf`, `.bdf.gz`) and PCF (`.pcf`, `.pcf.gz`) formats, chosen by the
    \\file extension. Vector fonts cannot be saved.
    \\
    \\## Parameters
    \\- `path` (str): Path to save the font file
    \\
    \\## Examples
    \\```python
    \\# Convert BDF to PCF
    \\font = Font.load("original.bdf")
    \\font.save("converted.pcf.gz")
    \\```
;

fn font_save(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const font = python.unwrap(FontObject, "font", self_obj, "Font") orelse return null;
    const Params = struct {
        path: [*c]const u8,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const path = std.mem.span(params.path);

    switch (font.*) {
        .bitmap => |b| b.save(ctx.io, allocator, path) catch |err| {
            python.setErrorWithPath(err, path);
            return null;
        },
        .vector => {
            python.setValueError("vector fonts cannot be saved", .{});
            return null;
        },
    }
    return python.none();
}

const font_font8x8_doc =
    \\Get the built-in 8x8 bitmap font with all available characters.
    \\
    \\This font includes ASCII, extended ASCII, Greek, and box drawing characters. It is the
    \\default font of `Canvas.draw_text`.
    \\
    \\## Examples
    \\```python
    \\font = Font.font8x8()
    \\canvas.draw_text("Hello World!", (10, 10), (255, 255, 255), font, size=16)
    \\```
;

/// The shared built-in font object (a borrowed reference), created on first use and kept
/// for the module's lifetime.
pub fn font8x8Object() ?*c.PyObject {
    if (cached_font8x8 == null) {
        const bitmap = zignal.font.font8x8.create(allocator, .all) catch {
            python.setRuntimeError("Failed to create font8x8 with all characters", .{});
            return null;
        };
        cached_font8x8 = wrap(.{ .bitmap = bitmap }) orelse return null;
    }
    return cached_font8x8;
}

fn font_font8x8(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;
    _ = args;
    const obj = font8x8Object() orelse return null;
    c.Py_IncRef(obj);
    return obj;
}

const font_ascent_doc =
    \\Distance from the top of a line to its baseline, in pixels, at `size`.
    \\
    \\## Parameters
    \\- `size` (float): Font size in pixels
;

const font_line_height_doc =
    \\Baseline-to-baseline distance, in pixels, at `size`.
    \\
    \\## Parameters
    \\- `size` (float): Font size in pixels
;

const PyMethod = fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject;

/// A method calling `Font.<method>(size)` and returning the number.
fn sizedMetric(comptime method: []const u8) PyMethod {
    return struct {
        fn call(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const font = python.unwrap(FontObject, "font", self_obj, "Font") orelse return null;
            const Params = struct {
                size: f64,
            };
            var params: Params = undefined;
            python.parseArgs(Params, args, kwds, &params) catch return null;
            return python.create(@field(Font, method)(font.*, @floatCast(params.size)));
        }
    }.call;
}

const font_has_glyph_doc =
    \\Whether the font has a glyph for a character.
    \\
    \\## Parameters
    \\- `char` (str): A single character
;

fn font_has_glyph(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const font = python.unwrap(FontObject, "font", self_obj, "Font") orelse return null;
    const Params = struct {
        char: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    if (c.PyUnicode_Check(params.char) == 0 or c.PyUnicode_GetLength(params.char) != 1) {
        python.setTypeError("single character", params.char);
        return null;
    }
    return python.create(font.hasGlyph(@intCast(c.PyUnicode_ReadChar(params.char, 0))));
}

const font_get_text_bounds_doc =
    \\Box occupied by `text` drawn at `size`, relative to its top-left corner.
    \\
    \\Width is the widest line's advance, height is the number of lines times the line height.
    \\
    \\## Parameters
    \\- `text` (str): Text to measure; `\n` starts a new line
    \\- `size` (float): Font size in pixels
;

const font_get_text_bounds_tight_doc =
    \\Box of the inked pixels of `text` drawn at `size`, relative to its top-left corner.
    \\
    \\## Parameters
    \\- `text` (str): Text to measure; `\n` starts a new line
    \\- `size` (float): Font size in pixels
;

/// A method calling `Font.<method>(text, size)` and returning the `Rectangle`.
fn textBounds(comptime method: []const u8) PyMethod {
    return struct {
        fn call(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const font = python.unwrap(FontObject, "font", self_obj, "Font") orelse return null;
            const Params = struct {
                text: [*c]const u8,
                size: f64,
            };
            var params: Params = undefined;
            python.parseArgs(Params, args, kwds, &params) catch return null;
            const rect = @field(Font, method)(font.*, std.mem.span(params.text), @floatCast(params.size));
            return python.create(rect.as(f64));
        }
    }.call;
}

fn fontKind(font: *Font) ?*c.PyObject {
    return python.create(@tagName(font.*));
}

fn fontName(font: *Font) ?*c.PyObject {
    return switch (font.*) {
        .bitmap => |b| python.create(b.name),
        .vector => python.none(),
    };
}

fn fontHeight(font: *Font) ?*c.PyObject {
    return switch (font.*) {
        .bitmap => |b| python.create(b.char_height),
        .vector => python.none(),
    };
}

pub const font_methods_metadata = [_]python.MethodWithMetadata{
    .{
        .name = "load",
        .meth = @ptrCast(&font_load),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = font_load_doc,
        .params = "cls, path: str",
        .returns = "Font",
    },
    .{
        .name = "font8x8",
        .meth = @ptrCast(&font_font8x8),
        .flags = c.METH_NOARGS | c.METH_CLASS,
        .doc = font_font8x8_doc,
        .params = "cls",
        .returns = "Font",
    },
    .{
        .name = "save",
        .meth = @ptrCast(&font_save),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = font_save_doc,
        .params = "self, path: str",
        .returns = "None",
    },
    .{
        .name = "ascent",
        .meth = @ptrCast(&sizedMetric("ascent")),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = font_ascent_doc,
        .params = "self, size: float",
        .returns = "float",
    },
    .{
        .name = "line_height",
        .meth = @ptrCast(&sizedMetric("lineHeight")),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = font_line_height_doc,
        .params = "self, size: float",
        .returns = "float",
    },
    .{
        .name = "has_glyph",
        .meth = @ptrCast(&font_has_glyph),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = font_has_glyph_doc,
        .params = "self, char: str",
        .returns = "bool",
    },
    .{
        .name = "get_text_bounds",
        .meth = @ptrCast(&textBounds("getTextBounds")),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = font_get_text_bounds_doc,
        .params = "self, text: str, size: float",
        .returns = "Rectangle",
    },
    .{
        .name = "get_text_bounds_tight",
        .meth = @ptrCast(&textBounds("getTextBoundsTight")),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = font_get_text_bounds_tight_doc,
        .params = "self, text: str, size: float",
        .returns = "Rectangle",
    },
};

var font_methods = python.toPyMethodDefArray(&font_methods_metadata);

pub const font_properties_metadata = [_]python.PropertyWithMetadata{
    .{
        .name = "kind",
        .get = python.getterOptionalPtr(FontObject, "font", fontKind),
        .doc = "\"bitmap\" or \"vector\"",
        .type = "str",
    },
    .{
        .name = "name",
        .get = python.getterOptionalPtr(FontObject, "font", fontName),
        .doc = "Name of a bitmap font; None for TrueType fonts",
        .type = "str | None",
    },
    .{
        .name = "height",
        .get = python.getterOptionalPtr(FontObject, "font", fontHeight),
        .doc = "Character height in pixels of a bitmap font (its native size); None for TrueType fonts",
        .type = "int | None",
    },
};

var font_getset = python.toPyGetSetDefArray(&font_properties_metadata);

const font_class_doc =
    "Font for text rendering: a bitmap font (BDF/PCF, optionally gzip-compressed) or a " ++
    "vector font (TrueType .ttf, CFF OpenType .otf), detected from the file. Sizes are always " ++
    "in pixels: the em height for vector fonts, the character height for bitmap fonts.";

pub var FontType = python.buildTypeObject(.{
    .name = "zignal.Font",
    .basicsize = @sizeOf(FontObject),
    .doc = font_class_doc,
    .methods = @ptrCast(&font_methods),
    .getset = @ptrCast(&font_getset),
    .new = font_new,
    .dealloc = font_dealloc,
    .repr = font_repr,
});
