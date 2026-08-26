//! A scalable font parsed in place from TrueType or CFF OpenType bytes, standalone
//! or one face of a `.ttc` collection. Glyph outlines, advances and kerning are read
//! on demand from the borrowed buffer; nothing is decoded up front, so loading is
//! allocation-free. `enableCache` attaches an optional `GlyphCache` that remembers what
//! was read and, when drawing, the rasterized glyphs; copies of the font share it, so
//! enable it before copying the font into a `Font` or a `Layout`, and free it once.
//!
//! Example:
//! ```zig
//! var font: VectorFont = try .load(io, allocator, "DejaVuSans.ttf");
//! defer font.deinit(allocator);
//! try canvas.drawText("Hello", .init(.{ 10, 10 }), Rgb.black, .{ .vector = font }, 24, .soft);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Rectangle = @import("../geometry.zig").Rectangle;
const Point2 = @import("../geometry/Point.zig").Point(2, f32);
const as = @import("../meta.zig").as;
const font_mod = @import("../font.zig");
const truetype = @import("truetype.zig");
const Outline = @import("Outline.zig");
const GlyphCache = @import("GlyphCache.zig");

const VectorFont = @This();

pub const Error = truetype.Error;

pub const GlyphMetrics = struct {
    /// Horizontal advance in font units.
    advance: u16,
    /// Left side bearing in font units.
    lsb: i16,
};

/// Glyph bounding box in font units, y up.
pub const Bounds = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

/// The sfnt bytes. Borrowed by `loadFromBytes`, owned after `load`.
data: []const u8,
/// Faces in the file: 1 for a single font, the collection size for `ttcf`.
num_faces: u32,
units_per_em: u16,
num_glyphs: u16,
num_h_metrics: u16,
/// `head` flags bit 1: outlines are positioned so that x = 0 is the left side bearing.
lsb_is_at_x_zero: bool,
/// Vertical metrics in font units (`descent` is negative): `hhea`, or OS/2 typographic
/// metrics when `hhea` has none.
ascent: i16,
descent: i16,
line_gap: i16,
advance_width_max: u16,
/// From `post`; underline position is relative to the baseline, negative below.
underline_position: i16,
underline_thickness: i16,
/// From OS/2; the position is above the baseline.
strikeout_size: i16,
strikeout_position: i16,
tables: truetype.Tables,
cmap: truetype.cmap.Subtable,
/// Memo of parsed glyphs and rasterized masks; null until `enableCache`. Shared by every
/// copy of the font, freed by `deinit` or `disableCache`.
cache: ?*GlyphCache = null,

/// Parses the header tables of `data`, which must outlive the font. No allocation, no I/O.
/// A collection yields its first face; see `loadFromBytesFace`.
pub fn loadFromBytes(data: []const u8) Error!VectorFont {
    return truetype.parse(data);
}

/// `loadFromBytes` for face `face` of a `.ttc` collection; `error.InvalidFormat` past the
/// last face (a single font has only face 0).
pub fn loadFromBytesFace(data: []const u8, face: u32) Error!VectorFont {
    return truetype.parseFace(data, face);
}

/// Reads and parses a `.ttf`, `.otf` or `.ttc` (optionally gzipped). The font owns the
/// bytes; call `deinit`. A collection yields its first face; see `loadFace`.
pub fn load(io: Io, gpa: Allocator, path: []const u8) !VectorFont {
    return loadFace(io, gpa, path, 0);
}

/// `load` for face `face` of a collection.
pub fn loadFace(io: Io, gpa: Allocator, path: []const u8, face: u32) !VectorFont {
    const data = try font_mod.readFileMaybeGzip(io, gpa, path);
    errdefer gpa.free(data);
    return loadFromBytesFace(data, face);
}

/// Frees the bytes of a font from `load`, and its cache. Not for fonts from
/// `loadFromBytes`, which only need `disableCache`.
pub fn deinit(self: *VectorFont, gpa: Allocator) void {
    self.disableCache();
    gpa.free(self.data);
    self.* = undefined;
}

/// Attaches a glyph cache allocated from `gpa`; a second call keeps the existing one.
pub fn enableCache(self: *VectorFont, gpa: Allocator) Allocator.Error!void {
    if (self.cache != null) return;
    const cache = try gpa.create(GlyphCache);
    cache.* = .init(gpa);
    self.cache = cache;
}

/// Frees the cache, if any; other copies of the font must not use it afterwards.
pub fn disableCache(self: *VectorFont) void {
    const cache = self.cache orelse return;
    const gpa = cache.gpa;
    cache.deinit();
    gpa.destroy(cache);
    self.cache = null;
}

/// Glyph index for `codepoint`; 0 (`.notdef`) when unmapped.
pub fn glyphIndex(self: VectorFont, codepoint: u21) u16 {
    const cache = self.cache orelse return self.lookupGlyphIndex(codepoint);
    const slot = cache.codepoints.getOrPut(cache.gpa, codepoint) catch return self.lookupGlyphIndex(codepoint);
    if (!slot.found_existing) slot.value_ptr.* = self.lookupGlyphIndex(codepoint);
    return slot.value_ptr.*;
}

fn lookupGlyphIndex(self: VectorFont, codepoint: u21) u16 {
    const r: truetype.Reader = .init(self.data);
    const gid = truetype.cmap.lookup(r.table(self.tables.cmap), self.cmap, codepoint);
    return if (gid < self.num_glyphs) gid else 0;
}

/// Advance and left side bearing; the widest advance for an invalid index.
pub fn glyphMetrics(self: VectorFont, gid: u16) GlyphMetrics {
    if (gid >= self.num_glyphs) return .{ .advance = self.advance_width_max, .lsb = 0 };
    return self.metricsOf(self.cachedGlyph(gid), gid);
}

/// `glyphMetrics` through the cache entry `g` of a valid `gid`, when there is one.
fn metricsOf(self: VectorFont, g: ?*GlyphCache.Glyph, gid: u16) GlyphMetrics {
    const entry = g orelse return self.readMetrics(gid);
    if (entry.metrics == null) entry.metrics = self.readMetrics(gid);
    return entry.metrics.?;
}

/// The cache entry for `gid`; null without a cache, for an invalid id or when out of memory.
fn cachedGlyph(self: VectorFont, gid: u16) ?*GlyphCache.Glyph {
    const cache = self.cache orelse return null;
    if (gid >= self.num_glyphs) return null;
    return cache.glyph(gid);
}

fn readMetrics(self: VectorFont, gid: u16) GlyphMetrics {
    const r: truetype.Reader = .init(self.data);
    const hmtx = r.table(self.tables.hmtx);
    const last = self.num_h_metrics - 1;
    // Past numberOfHMetrics only bearings are stored; the advance is the last one listed.
    const advance = hmtx.u16At(4 * @as(usize, @min(gid, last))) catch self.advance_width_max;
    const lsb = if (gid <= last)
        hmtx.i16At(4 * @as(usize, gid) + 2) catch 0
    else
        hmtx.i16At(4 * @as(usize, self.num_h_metrics) + 2 * @as(usize, gid - self.num_h_metrics)) catch 0;
    return .{ .advance = advance, .lsb = lsb };
}

/// The glyph's bounding box: from its `glyf` header, or the control box of its CFF
/// charstring. Null for glyphs without contours (spaces, `.notdef`).
pub fn glyphBounds(self: VectorFont, gid: u16) ?Bounds {
    return self.boundsOf(self.cachedGlyph(gid), gid);
}

/// `glyphBounds` through the cache entry `g`, when there is one.
fn boundsOf(self: VectorFont, g: ?*GlyphCache.Glyph, gid: u16) ?Bounds {
    const entry = g orelse return self.readBounds(gid);
    if (entry.bounds == null) {
        // A CFF box is the charstring interpreted, as its outline is: parse the outline
        // once into the cache and read the box off it.
        if (self.tables.outlines == .cff and entry.outline == null) {
            const cache = self.cache.?;
            cache.outline_stats.misses += 1;
            entry.outline = self.outline(cache.gpa, gid) catch null;
        }
        entry.bounds = if (entry.outline) |o| controlBox(o) else self.readBounds(gid);
    }
    return entry.bounds.?;
}

/// Box of an outline's points, controls included, as `cff.bounds` computes it.
fn controlBox(o: Outline) ?Bounds {
    if (o.points.len == 0) return null;
    var min: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var max: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (o.points) |p| {
        min = .{ @min(min[0], p.x), @min(min[1], p.y) };
        max = .{ @max(max[0], p.x), @max(max[1], p.y) };
    }
    return .{
        .x_min = std.math.lossyCast(i16, @floor(min[0])),
        .y_min = std.math.lossyCast(i16, @floor(min[1])),
        .x_max = std.math.lossyCast(i16, @ceil(max[0])),
        .y_max = std.math.lossyCast(i16, @ceil(max[1])),
    };
}

fn readBounds(self: VectorFont, gid: u16) ?Bounds {
    return switch (self.tables.outlines) {
        .glyf => truetype.glyf.bounds(self, gid),
        .cff => truetype.cff.bounds(self, gid),
    };
}

/// The glyph's outline in font units, composites resolved. Caller owns the result; the
/// cache is bypassed, see `outlineRef`.
pub fn outline(self: VectorFont, gpa: Allocator, gid: u16) (Error || Allocator.Error)!Outline {
    return switch (self.tables.outlines) {
        .glyf => truetype.glyf.outline(self, gpa, gid),
        .cff => truetype.cff.outline(self, gpa, gid),
    };
}

/// An outline that may be borrowed from the cache; `deinit` frees it only when owned.
pub const OutlineRef = struct {
    outline: Outline,
    owned: bool,

    pub fn deinit(self: *OutlineRef, gpa: Allocator) void {
        if (self.owned) self.outline.deinit(gpa);
        self.* = undefined;
    }
};

/// `outline` through the cache: parsed once and borrowed when one is enabled, owned by the
/// caller otherwise. Parse failures are not remembered.
pub fn outlineRef(self: VectorFont, gpa: Allocator, gid: u16) (Error || Allocator.Error)!OutlineRef {
    const g = self.cachedGlyph(gid) orelse return .{ .outline = try self.outline(gpa, gid), .owned = true };
    const cache = self.cache.?;
    if (g.outline == null) {
        cache.outline_stats.misses += 1;
        g.outline = try self.outline(cache.gpa, gid);
    } else cache.outline_stats.hits += 1;
    return .{ .outline = g.outline.?, .owned = false };
}

/// Horizontal kerning to add to `left`'s advance when followed by `right`, in font units.
pub fn kern(self: VectorFont, left: u16, right: u16) i16 {
    if (self.tables.gpos == null and self.tables.kern == null) return 0;
    const cache = self.cache orelse return self.lookupKern(left, right);
    const slot = cache.kerns.getOrPut(cache.gpa, @as(u32, left) << 16 | right) catch return self.lookupKern(left, right);
    if (!slot.found_existing) slot.value_ptr.* = self.lookupKern(left, right);
    return slot.value_ptr.*;
}

fn lookupKern(self: VectorFont, left: u16, right: u16) i16 {
    const r: truetype.Reader = .init(self.data);
    if (self.tables.gpos) |pairs| return truetype.gpos.pairAdjust(r.table(pairs.table), pairs, left, right);
    if (self.tables.kern) |t| return truetype.kern.lookup(r.table(t), left, right);
    return 0;
}

/// Device pixels per font unit at `size` pixels per em.
pub fn scaleFor(self: VectorFont, size: f32) f32 {
    return size / as(f32, self.units_per_em);
}

/// Baseline-to-baseline distance at `size` pixels per em.
pub fn lineHeight(self: VectorFont, size: f32) f32 {
    return as(f32, @as(i32, self.ascent) - self.descent + self.line_gap) * self.scaleFor(size);
}

/// Lays out `text` from a top-left origin with `\n` line breaks, yielding each glyph
/// placed in device pixels.
pub const Layout = struct {
    pub const Item = struct {
        gid: u16,
        /// Pen position on the baseline, relative to the text's top-left corner, with the
        /// outline's side-bearing shift already applied.
        origin: Point2,
        /// Font-unit box of the glyph; null when it has no ink.
        bounds: ?Bounds,
    };

    font: VectorFont,
    scale: f32,
    line_height: f32,
    iter: std.unicode.Utf8Iterator,
    x: f32 = 0,
    baseline: f32,
    prev: ?u16 = null,
    /// Extra device pixels after every glyph's advance.
    letter_spacing: f32 = 0,
    /// Whether items carry glyph bounds. Measuring turns this off, which spares CFF fonts
    /// an interpretation per glyph; the bearing shift still reads them when it needs to.
    with_bounds: bool = true,

    pub fn init(font: VectorFont, text: []const u8, size: f32) Layout {
        const scale = font.scaleFor(size);
        return .{
            .font = font,
            .scale = scale,
            .line_height = font.lineHeight(size),
            .iter = .{ .bytes = text, .i = 0 },
            .baseline = as(f32, font.ascent) * scale,
        };
    }

    pub fn next(self: *Layout) ?Item {
        while (self.iter.nextCodepoint()) |codepoint| {
            if (self.place(codepoint)) |item| return item;
        }
        return null;
    }

    /// Places `codepoint` at the pen and advances past it; `\n` starts the next line and
    /// places nothing.
    pub fn place(self: *Layout, codepoint: u21) ?Item {
        if (codepoint == '\n') {
            self.x = 0;
            self.baseline += self.line_height;
            self.prev = null;
            return null;
        }
        const gid = self.font.glyphIndex(codepoint);
        if (self.prev) |p| self.x += as(f32, self.font.kern(p, gid)) * self.scale;
        // One cache lookup serves both reads; `glyphIndex` keeps gid valid.
        const cached = self.font.cachedGlyph(gid);
        const metrics = self.font.metricsOf(cached, gid);
        const bounds = if (self.with_bounds or !self.font.lsb_is_at_x_zero) self.font.boundsOf(cached, gid) else null;
        // Unless head says the outline already starts at its bearing, shift it there.
        const shift: f32 = if (self.font.lsb_is_at_x_zero or bounds == null) 0 else as(f32, @as(i32, metrics.lsb) - bounds.?.x_min);
        const item: Item = .{
            .gid = gid,
            .origin = .init(.{ self.x + shift * self.scale, self.baseline }),
            .bounds = bounds,
        };
        self.x += as(f32, metrics.advance) * self.scale + self.letter_spacing;
        self.prev = gid;
        return item;
    }

    /// Device-pixel box of the glyph's ink, relative to the text's top-left corner.
    pub fn inkBounds(self: Layout, item: Item) ?Rectangle(f32) {
        const b = item.bounds orelse return null;
        return .{
            .l = item.origin.x() + as(f32, b.x_min) * self.scale,
            .t = item.origin.y() - as(f32, b.y_max) * self.scale,
            .r = item.origin.x() + as(f32, b.x_max) * self.scale,
            .b = item.origin.y() - as(f32, b.y_min) * self.scale,
        };
    }

    /// The transform that places the glyph's outline when the text starts at `position`.
    pub fn transform(self: Layout, item: Item, position: Point2) Outline.Transform {
        return .{ .scale = self.scale, .origin = position.add(item.origin) };
    }
};

/// Box occupied by `text` at `size` pixels per em, relative to its top-left corner:
/// the widest line's advance by the number of lines times the line height.
pub fn getTextBounds(self: VectorFont, text: []const u8, size: f32) Rectangle(f32) {
    var layout: Layout = .init(self, text, size);
    layout.with_bounds = false;
    var width: f32 = 0;
    while (layout.next()) |_| width = @max(width, layout.x);
    const lines = 1 + std.mem.count(u8, text, "\n");
    return .{ .l = 0, .t = 0, .r = width, .b = as(f32, lines) * layout.line_height };
}

/// Union of the glyph boxes of `text`, relative to its top-left corner; empty when no
/// glyph has ink.
pub fn getTextBoundsTight(self: VectorFont, text: []const u8, size: f32) Rectangle(f32) {
    var layout: Layout = .init(self, text, size);
    var bounds: ?Rectangle(f32) = null;
    while (layout.next()) |item| {
        const box = layout.inkBounds(item) orelse continue;
        bounds = if (bounds) |acc| acc.merge(box) else box;
    }
    return bounds orelse .{ .l = 0, .t = 0, .r = 0, .b = 0 };
}

pub fn format(self: VectorFont, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("VectorFont{{ .units_per_em = {d}, .glyphs = {d}, .ascent = {d}, .descent = {d}", .{
        self.units_per_em,
        self.num_glyphs,
        self.ascent,
        self.descent,
    });
    if (self.num_faces > 1) try writer.print(", .faces = {d}", .{self.num_faces});
    try writer.writeAll(" }");
}

const testing = std.testing;
const synthetic = @import("truetype/synthetic.zig");

test "header metrics" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    try testing.expectEqual(@as(u16, 1000), font.units_per_em);
    try testing.expectEqual(@as(u16, 7), font.num_glyphs);
    try testing.expectEqual(@as(u16, 3), font.num_h_metrics);
    try testing.expect(font.lsb_is_at_x_zero);
    try testing.expectEqual(.short, font.tables.outlines.glyf.index_to_loc_format);
    try testing.expectEqual(@as(i16, 900), font.ascent);
    try testing.expectEqual(@as(i16, -250), font.descent);
    try testing.expectEqual(@as(i16, 0), font.line_gap);
    try testing.expectEqual(@as(u16, 800), font.advance_width_max);
    try testing.expectEqual(@as(i16, -100), font.underline_position);
    try testing.expectEqual(@as(i16, 50), font.underline_thickness);
    try testing.expectEqual(@as(i16, 50), font.strikeout_size);
    try testing.expectEqual(@as(i16, 300), font.strikeout_position);
    try testing.expectEqual(@as(f32, 0.024), font.scaleFor(24));
    try testing.expectEqual(@as(f32, 57.5), font.lineHeight(50));

    const long = synthetic.font(&buf, .{ .long_loca = true, .lsb_at_x_zero = false });
    try testing.expectEqual(.long, long.tables.outlines.glyf.index_to_loc_format);
    try testing.expect(!long.lsb_is_at_x_zero);
    // Glyph 1 has lsb 60 but starts at x = 100, so its outline shifts left by 40 units.
    var shifted: Layout = .init(long, "A", 1000);
    try testing.expectEqual(@as(f32, -40), shifted.next().?.origin.x());
    var unshifted: Layout = .init(font, "A", 1000);
    try testing.expectEqual(@as(f32, 0), unshifted.next().?.origin.x());
}

test "glyph metrics incl. the hmtx tail" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    try testing.expectEqual(GlyphMetrics{ .advance = 500, .lsb = 0 }, font.glyphMetrics(0));
    try testing.expectEqual(GlyphMetrics{ .advance = 800, .lsb = 100 }, font.glyphMetrics(1));
    try testing.expectEqual(GlyphMetrics{ .advance = 800, .lsb = 100 }, font.glyphMetrics(2));
    try testing.expectEqual(GlyphMetrics{ .advance = 800, .lsb = 0 }, font.glyphMetrics(3));
    try testing.expectEqual(GlyphMetrics{ .advance = 800, .lsb = 100 }, font.glyphMetrics(6));
    try testing.expectEqual(GlyphMetrics{ .advance = 800, .lsb = 0 }, font.glyphMetrics(7));
}

test "text bounds" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    // A then B: 800 + kern(1, 2) = -30, then 800; two lines of 1150 units.
    const bounds = font.getTextBounds("AB\nA", 50);
    try testing.expectApproxEqAbs(@as(f32, (800 - 30 + 800) * 0.05), bounds.r, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2 * 57.5), bounds.b, 1e-4);

    const tight = font.getTextBoundsTight("A", 100);
    try testing.expectApproxEqAbs(@as(f32, 10), tight.l, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 70), tight.r, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 90 - 70), tight.t, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 90), tight.b, 1e-4);
    try testing.expectEqual(@as(f32, 0), font.getTextBoundsTight("", 100).r);
}

test "rejects other formats and truncation without panicking" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const full = synthetic.build(&buf, .{});
    var otto: [64]u8 = undefined;
    @memcpy(otto[0..64], full[0..64]);
    // A collection header claiming zero faces.
    @memcpy(otto[0..4], "ttcf");
    try testing.expectError(error.InvalidFormat, VectorFont.loadFromBytes(&otto));
    @memcpy(otto[0..4], "abcd");
    try testing.expectError(error.InvalidFormat, VectorFont.loadFromBytes(&otto));
    try testing.expectError(error.UnexpectedEof, VectorFont.loadFromBytes(""));

    // An OTTO tag on a font without a `CFF ` table.
    var cff_less: [synthetic.buffer_size]u8 = undefined;
    @memcpy(cff_less[0..full.len], full);
    @memcpy(cff_less[0..4], "OTTO");
    try testing.expectError(error.MissingTable, VectorFont.loadFromBytes(cff_less[0..full.len]));

    var len: usize = 0;
    while (len < full.len) : (len += 7) {
        if (VectorFont.loadFromBytes(full[0..len])) |font| {
            // Loadable prefixes must still answer every query safely.
            _ = font.glyphIndex('A');
            _ = font.kern(1, 2);
            _ = font.glyphMetrics(6);
            _ = font.glyphBounds(4);
            if (font.outline(testing.allocator, 5)) |o| {
                var owned = o;
                owned.deinit(testing.allocator);
            } else |_| {}
        } else |_| {}
    }
}

test "collections" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const bytes = synthetic.build(&buf, .{ .collection = true });
    try testing.expectEqual(.ttc, font_mod.FontFormat.detectFromBytes(bytes));
    const first = try VectorFont.loadFromBytes(bytes);
    const second = try VectorFont.loadFromBytesFace(bytes, 1);
    try testing.expectEqual(2, first.num_faces);
    try testing.expectEqual(first.tables, second.tables);
    try testing.expectEqual(first.glyphIndex('B'), second.glyphIndex('B'));
    try testing.expectError(error.InvalidFormat, VectorFont.loadFromBytesFace(bytes, 2));

    var single: [synthetic.buffer_size]u8 = undefined;
    const plain = synthetic.build(&single, .{});
    try testing.expectEqual(1, (try VectorFont.loadFromBytes(plain)).num_faces);
    try testing.expectError(error.InvalidFormat, VectorFont.loadFromBytesFace(plain, 1));

    var text: [128]u8 = undefined;
    const printed = try std.fmt.bufPrint(&text, "{f}", .{first});
    try testing.expectEqualStrings("VectorFont{ .units_per_em = 1000, .glyphs = 7, .ascent = 900, .descent = -250, .faces = 2 }", printed);

    // Truncated collections fail cleanly too.
    var len: usize = 0;
    while (len < bytes.len) : (len += 7) {
        if (VectorFont.loadFromBytesFace(bytes[0..len], 1)) |font| {
            _ = font.glyphIndex('A');
            _ = font.glyphBounds(4);
        } else |_| {}
    }
}

test "loading from a file" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const bytes = synthetic.build(&buf, .{});
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "synth.ttf", .data = bytes });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "synth.ttf", testing.allocator);
    defer testing.allocator.free(path);

    var font: VectorFont = try .load(testing.io, testing.allocator, path);
    defer font.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 2), font.glyphIndex('B'));

    var text: [128]u8 = undefined;
    const printed = try std.fmt.bufPrint(&text, "{f}", .{font});
    try testing.expectEqualStrings("VectorFont{ .units_per_em = 1000, .glyphs = 7, .ascent = 900, .descent = -250 }", printed);
}

test "system font, when one is installed" {
    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/TTF/Roboto-Regular.ttf",
    };
    var font: VectorFont = for (candidates) |path| {
        break VectorFont.load(testing.io, testing.allocator, path) catch continue;
    } else return error.SkipZigTest;
    defer font.deinit(testing.allocator);

    try testing.expect(font.units_per_em > 0);
    const a = font.glyphIndex('A');
    try testing.expect(a != 0);
    try testing.expect(font.glyphMetrics(a).advance > 0);
    var b = try font.outline(testing.allocator, font.glyphIndex('B'));
    defer b.deinit(testing.allocator);
    try testing.expect(b.contourCount() >= 2);
    try testing.expect(font.kern(a, font.glyphIndex('V')) <= 0);
    try testing.expect(font.getTextBounds("Hello", 24).r > 24);
}

test "system collection, when one is installed" {
    const candidates = [_][]const u8{
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/OTF/NotoSansCJK-Regular.ttc",
    };
    const path = for (candidates) |path| {
        Io.Dir.cwd().access(testing.io, path, .{}) catch continue;
        break path;
    } else return error.SkipZigTest;
    var font: VectorFont = try .load(testing.io, testing.allocator, path);
    defer font.deinit(testing.allocator);

    try testing.expect(font.num_faces > 1);
    try testing.expect(font.tables.outlines == .cff);
    try testing.expect(font.tables.outlines.cff.cid != null);
    try testing.expect(font.glyphIndex(0x4E2D) != 0);
    // Hiragana "a": curves, unlike the straight strokes of many kanji.
    const kana = font.glyphIndex(0x3042);
    try testing.expect(kana != 0);
    var o = try font.outline(testing.allocator, kana);
    defer o.deinit(testing.allocator);
    try testing.expect(o.contourCount() >= 1);
    var cubics: usize = 0;
    for (o.points) |p| cubics += @intFromBool(p.kind == .cubic_control);
    try testing.expect(cubics > 0);
    try testing.expect(font.getTextBounds("中文", 24).r > 24);

    var last: VectorFont = try .loadFace(testing.io, testing.allocator, path, font.num_faces - 1);
    defer last.deinit(testing.allocator);
    try testing.expectEqual(font.num_glyphs, last.num_glyphs);
    try testing.expectError(error.InvalidFormat, VectorFont.loadFace(testing.io, testing.allocator, path, font.num_faces));
}

test "system CFF font, when one is installed" {
    const candidates = [_][]const u8{
        "/usr/share/fonts/gnu-free/FreeSans.otf",
        "/usr/share/fonts/opentype/freefont/FreeSans.otf",
        "/usr/share/fonts/OTF/FreeSans.otf",
    };
    var font: VectorFont = for (candidates) |path| {
        break VectorFont.load(testing.io, testing.allocator, path) catch continue;
    } else return error.SkipZigTest;
    defer font.deinit(testing.allocator);

    try testing.expect(font.tables.outlines == .cff);
    const a = font.glyphIndex('A');
    try testing.expect(a != 0);
    try testing.expect(font.glyphMetrics(a).advance > 0);
    var b = try font.outline(testing.allocator, font.glyphIndex('B'));
    defer b.deinit(testing.allocator);
    try testing.expect(b.contourCount() >= 2);
    var cubics: usize = 0;
    for (b.points) |p| cubics += @intFromBool(p.kind == .cubic_control);
    try testing.expect(cubics > 0 and cubics % 2 == 0);
    const bounds = font.glyphBounds(font.glyphIndex('B')).?;
    try testing.expect(bounds.x_max > bounds.x_min and bounds.y_max > bounds.y_min);
    try testing.expect(font.kern(a, font.glyphIndex('V')) <= 0);
    try testing.expect(font.getTextBounds("Hello", 24).r > 24);
}
