//! A scalable font parsed in place from TrueType bytes. Glyph outlines,
//! advances and kerning are read on demand from the borrowed buffer; nothing is
//! decoded up front, so loading is allocation-free.
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

const VectorFont = @This();

pub const Error = truetype.Error;
pub const IndexToLocFormat = enum(u1) { short, long };

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
units_per_em: u16,
num_glyphs: u16,
num_h_metrics: u16,
/// `head` flags bit 1: outlines are positioned so that x = 0 is the left side bearing.
lsb_is_at_x_zero: bool,
index_to_loc_format: IndexToLocFormat,
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

/// Parses the header tables of `data`, which must outlive the font. No allocation, no I/O.
pub fn loadFromBytes(data: []const u8) Error!VectorFont {
    return truetype.parse(data);
}

/// Reads and parses a `.ttf` (optionally gzipped). The font owns the bytes; call `deinit`.
pub fn load(io: Io, gpa: Allocator, path: []const u8) !VectorFont {
    const data = try font_mod.readFileMaybeGzip(io, gpa, path);
    errdefer gpa.free(data);
    return loadFromBytes(data);
}

/// Frees the bytes of a font from `load`. Not for fonts from `loadFromBytes`.
pub fn deinit(self: *VectorFont, gpa: Allocator) void {
    gpa.free(self.data);
    self.* = undefined;
}

/// Glyph index for `codepoint`; 0 (`.notdef`) when unmapped.
pub fn glyphIndex(self: VectorFont, codepoint: u21) u16 {
    const r: truetype.Reader = .init(self.data);
    const gid = truetype.cmap.lookup(r.table(self.tables.cmap), self.cmap, codepoint);
    return if (gid < self.num_glyphs) gid else 0;
}

/// Advance and left side bearing; the widest advance for an invalid index.
pub fn glyphMetrics(self: VectorFont, gid: u16) GlyphMetrics {
    if (gid >= self.num_glyphs) return .{ .advance = self.advance_width_max, .lsb = 0 };
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

/// The glyph's bounding box from its header, without parsing the outline; null for
/// glyphs without contours (spaces, `.notdef`).
pub fn glyphBounds(self: VectorFont, gid: u16) ?Bounds {
    return truetype.glyf.bounds(self, gid);
}

/// The glyph's outline in font units, composites resolved. Caller owns the result.
pub fn outline(self: VectorFont, gpa: Allocator, gid: u16) (Error || Allocator.Error)!Outline {
    return truetype.glyf.outline(self, gpa, gid);
}

/// Horizontal kerning to add to `left`'s advance when followed by `right`, in font units.
pub fn kern(self: VectorFont, left: u16, right: u16) i16 {
    const r: truetype.Reader = .init(self.data);
    if (self.tables.gpos) |t| return truetype.gpos.pairAdjust(r.table(t), left, right);
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
            if (codepoint == '\n') {
                self.x = 0;
                self.baseline += self.line_height;
                self.prev = null;
                continue;
            }
            const gid = self.font.glyphIndex(codepoint);
            if (self.prev) |p| self.x += as(f32, self.font.kern(p, gid)) * self.scale;
            const metrics = self.font.glyphMetrics(gid);
            const bounds = self.font.glyphBounds(gid);
            // Unless head says the outline already starts at its bearing, shift it there.
            const shift: f32 = if (self.font.lsb_is_at_x_zero or bounds == null) 0 else as(f32, @as(i32, metrics.lsb) - bounds.?.x_min);
            const item: Item = .{
                .gid = gid,
                .origin = .init(.{ self.x + shift * self.scale, self.baseline }),
                .bounds = bounds,
            };
            self.x += as(f32, metrics.advance) * self.scale;
            self.prev = gid;
            return item;
        }
        return null;
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
    try writer.print("VectorFont{{ .units_per_em = {d}, .glyphs = {d}, .ascent = {d}, .descent = {d} }}", .{
        self.units_per_em,
        self.num_glyphs,
        self.ascent,
        self.descent,
    });
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
    try testing.expectEqual(.short, font.index_to_loc_format);
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
    try testing.expectEqual(.long, long.index_to_loc_format);
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
    @memcpy(otto[0..4], "OTTO");
    try testing.expectError(error.UnsupportedFontFormat, VectorFont.loadFromBytes(&otto));
    @memcpy(otto[0..4], "ttcf");
    try testing.expectError(error.UnsupportedFontFormat, VectorFont.loadFromBytes(&otto));
    @memcpy(otto[0..4], "abcd");
    try testing.expectError(error.InvalidFormat, VectorFont.loadFromBytes(&otto));
    try testing.expectError(error.UnexpectedEof, VectorFont.loadFromBytes(""));

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
