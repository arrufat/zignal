//! Line layout shared by every text drawing entry point: paragraphs, word wrap,
//! alignment and spacing, for bitmap and vector fonts alike. Widths come from
//! `Font.getTextBounds`, so vector kerning is honored when deciding breaks.

const std = @import("std");

const Font = @import("../font.zig").Font;
const BitmapFont = @import("BitmapFont.zig");
const VectorFont = @import("VectorFont.zig");
const Rectangle = @import("../geometry.zig").Rectangle;

pub const TextAlign = enum { left, center, right };
pub const VerticalAlign = enum { top, middle, bottom };

/// How `Canvas.drawTextBox` arranges lines inside its box.
pub const TextLayout = struct {
    halign: TextAlign = .left,
    valign: VerticalAlign = .top,
    /// Break lines at spaces so none exceeds the available width; a word wider than the
    /// width breaks between codepoints. `\n` always breaks.
    wrap: bool = false,
    /// Multiplier on the font's line height; values at or below zero stack the lines.
    line_spacing: f32 = 1,
    /// Extra pixels between consecutive glyphs; negative tightens.
    letter_spacing: f32 = 0,

    pub const default: TextLayout = .{};
};

/// A cursor over the glyphs of one line, in device pixels: kerned for vector fonts,
/// `letter_spacing` after every glyph for either kind. Wrapping and measuring walk the
/// text once through it.
pub const Pen = struct {
    inner: union(enum) { bitmap: BitmapFont.Layout, vector: VectorFont.Layout },
    iter: std.unicode.Utf8Iterator,
    letter_spacing: f32,
    glyphs: usize = 0,

    pub fn init(font: Font, text: []const u8, size: f32, letter_spacing: f32) Pen {
        return .{
            .inner = switch (font) {
                .bitmap => |b| blk: {
                    var layout: BitmapFont.Layout = .init(b, text, b.scaleFor(size));
                    layout.letter_spacing = letter_spacing;
                    break :blk .{ .bitmap = layout };
                },
                .vector => |v| blk: {
                    var layout: VectorFont.Layout = .init(v, text, size);
                    layout.letter_spacing = letter_spacing;
                    layout.with_bounds = false;
                    break :blk .{ .vector = layout };
                },
            },
            .iter = .{ .bytes = text, .i = 0 },
            .letter_spacing = letter_spacing,
        };
    }

    pub const Glyph = struct {
        codepoint: u21,
        /// Byte offset just past the codepoint.
        end: usize,
    };

    /// Places the next codepoint and advances past it.
    pub fn next(self: *Pen) ?Glyph {
        const codepoint = self.iter.nextCodepoint() orelse return null;
        switch (self.inner) {
            inline else => |*layout| _ = layout.place(codepoint),
        }
        self.glyphs += 1;
        return .{ .codepoint = codepoint, .end = self.iter.i };
    }

    /// Width of what has been placed: the pen position less the trailing letter spacing,
    /// never negative.
    pub fn width(self: Pen) f32 {
        if (self.glyphs == 0) return 0;
        const x = switch (self.inner) {
            inline else => |layout| layout.x,
        };
        return @max(0, x - self.letter_spacing);
    }
};

/// Width of `slice` drawn on one line with `letter_spacing` between its glyphs.
pub fn lineWidth(font: Font, slice: []const u8, size: f32, letter_spacing: f32) f32 {
    var pen: Pen = .init(font, slice, size, letter_spacing);
    while (pen.next()) |_| {}
    return pen.width();
}

/// Baseline-to-baseline distance under `layout`.
pub fn lineAdvance(font: Font, size: f32, layout: TextLayout) f32 {
    return font.lineHeight(size) * layout.line_spacing;
}

/// The lines of `text` at `size`: paragraphs split on `\n`, then wrapped greedily to
/// `max_width` when one is given. A wrapped line ends at a word boundary, the spaces at
/// the break are consumed, and a word wider than `max_width` breaks between codepoints.
/// Empty text yields one empty line, like `getTextBounds`.
pub const Lines = struct {
    pub const Line = struct {
        text: []const u8,
        /// `lineWidth` of the text without trailing spaces, known from wrapping; `Lines.width`
        /// measures an unwrapped line on demand.
        width: ?f32,
    };

    font: Font,
    text: []const u8,
    size: f32,
    max_width: ?f32,
    letter_spacing: f32,
    /// Runs one past the end once the last line is out.
    pos: usize = 0,

    pub fn init(font: Font, text: []const u8, size: f32, max_width: ?f32, letter_spacing: f32) Lines {
        return .{ .font = font, .text = text, .size = size, .max_width = max_width, .letter_spacing = letter_spacing };
    }

    pub fn next(self: *Lines) ?Line {
        if (self.pos > self.text.len) return null;
        const rest = self.text[self.pos..];
        const newline = std.mem.indexOfScalar(u8, rest, '\n');
        const paragraph = if (newline) |n| rest[0..n] else rest;
        // Past the paragraph lies its newline or the end of the text.
        var consumed = paragraph.len + 1;
        var line: Line = undefined;
        if (self.max_width) |max_width| {
            const fitted = self.fit(paragraph, max_width);
            if (fitted.len < paragraph.len) consumed = fitted.consumed;
            line = .{ .text = paragraph[0..fitted.len], .width = fitted.width };
        } else {
            line = .{ .text = paragraph, .width = null };
        }
        self.pos += consumed;
        return line;
    }

    /// The line's width, measured now unless wrapping already did.
    pub fn width(self: Lines, line: Line) f32 {
        return line.width orelse lineWidth(self.font, std.mem.trimEnd(u8, line.text, " "), self.size, self.letter_spacing);
    }

    const Fit = struct { len: usize, consumed: usize, width: f32 };

    /// The longest prefix of `paragraph` ending at a word boundary that fits `max_width`,
    /// its width, and how far to skip past the spaces after it, from one walk of the
    /// paragraph. The whole paragraph, when it fits, comes back as `len == paragraph.len`.
    /// A first word too wide for the width keeps as many codepoints as fit, at least one.
    fn fit(self: Lines, paragraph: []const u8, max_width: f32) Fit {
        var pen: Pen = .init(self.font, paragraph, self.size, self.letter_spacing);
        var accepted: usize = 0;
        var accepted_width: f32 = 0;
        // The word being walked: where it ends and the width there.
        var word_end: usize = 0;
        var word_width: f32 = 0;
        // Longest prefix of the first word that fits, should no whole word.
        var partial: usize = 0;
        var partial_width: f32 = 0;
        var first_word = true;
        while (true) {
            const glyph = pen.next();
            const at_space = if (glyph) |g| g.codepoint == ' ' else true;
            if (at_space) {
                if (word_end > accepted) {
                    if (word_width > max_width) break;
                    accepted = word_end;
                    accepted_width = word_width;
                }
                if (glyph == null) return .{ .len = paragraph.len, .consumed = paragraph.len, .width = accepted_width };
                if (word_end > 0) first_word = false;
                continue;
            }
            word_end = glyph.?.end;
            word_width = pen.width();
            if (first_word) {
                if (word_width <= max_width or partial == 0) {
                    partial = word_end;
                    partial_width = word_width;
                }
            } else if (word_width > max_width) break;
        }
        if (accepted == 0) {
            accepted = partial;
            accepted_width = partial_width;
        }
        var consumed = accepted;
        while (consumed < paragraph.len and paragraph[consumed] == ' ') consumed += 1;
        return .{ .len = accepted, .consumed = consumed, .width = accepted_width };
    }
};

/// Box the lines of `text` occupy from their top-left corner: the widest line by the
/// number of lines times the line advance. `max_width` only applies when `layout.wrap` is set.
pub fn measure(font: Font, text: []const u8, size: f32, max_width: ?f32, layout: TextLayout) Rectangle(f32) {
    var lines: Lines = .init(font, text, size, if (layout.wrap) max_width else null, layout.letter_spacing);
    var width: f32 = 0;
    var count: usize = 0;
    while (lines.next()) |line| {
        width = @max(width, lines.width(line));
        count += 1;
    }
    return .{ .l = 0, .t = 0, .r = width, .b = @as(f32, @floatFromInt(count)) * lineAdvance(font, size, layout) };
}

const testing = std.testing;
const font8x8 = @import("font8x8.zig");
const synthetic = @import("truetype/synthetic.zig");

fn expectLines(font: Font, text: []const u8, max_width: ?f32, expected: []const []const u8) !void {
    var lines: Lines = .init(font, text, 8, max_width, 0);
    for (expected) |want| {
        const line = lines.next() orelse return error.TestExpectedMoreLines;
        try testing.expectEqualStrings(want, line.text);
        try testing.expectEqual(lineWidth(font, std.mem.trimEnd(u8, want, " "), 8, 0), lines.width(line));
    }
    try testing.expectEqual(null, lines.next());
}

test "paragraphs without wrapping" {
    const font: Font = .{ .bitmap = font8x8.basic };
    try expectLines(font, "", null, &.{""});
    try expectLines(font, "ab", null, &.{"ab"});
    try expectLines(font, "ab\ncd", null, &.{ "ab", "cd" });
    try expectLines(font, "ab\n", null, &.{ "ab", "" });
    try expectLines(font, "\n\nx", null, &.{ "", "", "x" });
    // `measure` only wraps when the layout says so.
    try testing.expectEqual(88, measure(font, "aaa bbb ccc", 8, 64, .default).r);
    try testing.expectEqual(56, measure(font, "aaa bbb ccc", 8, 64, .{ .wrap = true }).r);
}

test "word wrap" {
    const font: Font = .{ .bitmap = font8x8.basic };
    // 8 px per glyph: "aaa bbb" is 56 px, "aaa bbb ccc" 88.
    try expectLines(font, "aaa bbb ccc", 64, &.{ "aaa bbb", "ccc" });
    try expectLines(font, "aaa bbb ccc", 56, &.{ "aaa bbb", "ccc" });
    try expectLines(font, "aaa bbb ccc", 55, &.{ "aaa", "bbb", "ccc" });
    try expectLines(font, "aaa bbb ccc", 200, &.{"aaa bbb ccc"});
    // Spaces at the break are consumed, trailing ones are kept out of the width.
    try expectLines(font, "aaa   bbb  ", 40, &.{ "aaa", "bbb  " });
    try expectLines(font, "aaa   ", 40, &.{"aaa   "});
    // A word wider than the box breaks between codepoints, at least one per line.
    try expectLines(font, "abcdefgh ij", 24, &.{ "abc", "def", "gh", "ij" });
    try expectLines(font, "abc", 4, &.{ "a", "b", "c" });
    try expectLines(font, "ééé", 16, &.{ "éé", "é" });
    try expectLines(font, "  abcd", 24, &.{ "  a", "bcd" });
    // Explicit breaks still apply inside wrapped text.
    try expectLines(font, "aaa bbb\nccc ddd", 40, &.{ "aaa", "bbb", "ccc", "ddd" });
    try expectLines(font, "aaa\n\nbbb", 40, &.{ "aaa", "", "bbb" });
}

test "spacing and measure" {
    const font: Font = .{ .bitmap = font8x8.basic };
    try testing.expectEqual(24, lineWidth(font, "abc", 8, 0));
    try testing.expectEqual(28, lineWidth(font, "abc", 8, 2));
    try testing.expectEqual(20, lineWidth(font, "abc", 8, -2));
    try testing.expectEqual(0, lineWidth(font, "abc", 8, -20));
    try testing.expectEqual(0, lineWidth(font, "", 8, 5));
    try testing.expectEqual(8, lineWidth(font, "a", 8, 5));

    const spaced: TextLayout = .{ .wrap = true, .line_spacing = 1.5, .letter_spacing = 2 };
    try testing.expectEqual(12, lineAdvance(font, 8, spaced));
    // "aaa bbb" would be 68 px with tracking, so it wraps at 64.
    const box = measure(font, "aaa bbb ccc", 8, 64, spaced);
    try testing.expectEqual(Rectangle(f32){ .l = 0, .t = 0, .r = 28, .b = 36 }, box);
    try testing.expectEqual(Rectangle(f32){ .l = 0, .t = 0, .r = 0, .b = 8 }, measure(font, "", 8, null, .default));
    try testing.expectEqual(font.getTextBounds("ab\ncd", 8), measure(font, "ab\ncd", 8, null, .default));
}

test "pen walks bitmap and vector lines alike" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const vector: Font = .{ .vector = synthetic.font(&buf, .{}) };
    const bitmap: Font = .{ .bitmap = font8x8.basic };
    for ([_]Font{ bitmap, vector }) |font| {
        var pen: Pen = .init(font, "AB", 10, 3);
        try testing.expectEqual(0, pen.width());
        const a = pen.next().?;
        try testing.expectEqual('A', a.codepoint);
        try testing.expectEqual(1, a.end);
        try testing.expectEqual(font.getTextBounds("A", 10).r, pen.width());
        _ = pen.next().?;
        try testing.expectEqual(font.getTextBounds("AB", 10).r + 3, pen.width());
        try testing.expectEqual(null, pen.next());
        try testing.expectEqual(pen.width(), lineWidth(font, "AB", 10, 3));
    }
}

test "vector widths follow kerning" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font: Font = .{ .vector = synthetic.font(&buf, .{}) };
    // A then B kerns by -30 units; at 1000 px per em that is 800 - 30 + 800.
    try testing.expectEqual(font.getTextBounds("AB", 1000).r, lineWidth(font, "AB", 1000, 0));
    try testing.expectEqual(1570 + 10, lineWidth(font, "AB", 1000, 10));
    var lines: Lines = .init(font, "AB AB", 1000, 1600, 0);
    try testing.expectEqualStrings("AB", lines.next().?.text);
    try testing.expectEqualStrings("AB", lines.next().?.text);
    try testing.expectEqual(null, lines.next());
}
