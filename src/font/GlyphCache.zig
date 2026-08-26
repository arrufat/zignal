//! Per-font memo attached by `VectorFont.enableCache`: cmap lookups, kerning pairs, metrics,
//! bounds and parsed outlines (read once per glyph instead of once per occurrence), plus the
//! antialiased coverage masks `Canvas` rasterizes for filled text, keyed by glyph, scale and
//! quarter-pixel phase. Not thread-safe: draws sharing one font must not run concurrently.
//! Every copy of the font shares the cache; free it once.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Point2 = @import("../geometry/Point.zig").Point(2, f32);
const as = @import("../meta.zig").as;
const VectorFont = @import("VectorFont.zig");
const Outline = @import("Outline.zig");

const GlyphCache = @This();

/// Everything read once for a glyph id.
pub const Glyph = struct {
    metrics: ?VectorFont.GlyphMetrics = null,
    /// Read once; the inner null means the glyph has no ink.
    bounds: ??VectorFont.Bounds = null,
    /// Font units, owned by the cache.
    outline: ?Outline = null,
};

/// Antialiased coverage of one glyph at one scale and subpixel phase. `left`/`top` place
/// `data[0]` relative to the integer part of the pen origin.
pub const Mask = struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    /// `width * height` bytes, owned by the cache.
    data: []u8,
};

/// Subpixel phases per axis a mask is rendered at.
pub const phases = 4;

pub const MaskKey = packed struct(u64) {
    /// Bit pattern of the f32 scale.
    scale_bits: u32,
    gid: u16,
    /// Quarter-pixel phase of the origin.
    bx: u2,
    by: u2,
    _: u12 = 0,
};

/// Where a glyph's mask goes: its key, the integer pen position the mask is offset from,
/// and the snapped fraction the mask is rendered at.
pub const Placement = struct {
    key: MaskKey,
    x: i32,
    y: i32,
    /// In [0, 1) per axis.
    phase: Point2,
};

pub fn place(gid: u16, transform: Outline.Transform) Placement {
    const ox = @floor(transform.origin.x());
    const oy = @floor(transform.origin.y());
    const bx = phase(transform.origin.x() - ox);
    const by = phase(transform.origin.y() - oy);
    return .{
        .key = .{ .scale_bits = @bitCast(transform.scale), .gid = gid, .bx = bx, .by = by },
        .x = @trunc(ox),
        .y = @trunc(oy),
        .phase = .init(.{ as(f32, bx) / phases, as(f32, by) / phases }),
    };
}

/// `x - floor(x)` can round up to 1 for tiny negative `x`, hence the clamp.
fn phase(frac: f32) u2 {
    return @trunc(@min(frac * phases, phases - 1));
}

pub const Stats = struct {
    hits: usize = 0,
    misses: usize = 0,
};

gpa: Allocator,
glyphs: std.AutoHashMapUnmanaged(u16, Glyph) = .empty,
codepoints: std.AutoHashMapUnmanaged(u32, u16) = .empty,
/// Kerning by glyph pair, `left << 16 | right`.
kerns: std.AutoHashMapUnmanaged(u32, i16) = .empty,
masks: std.AutoHashMapUnmanaged(MaskKey, Mask) = .empty,
mask_bytes: usize = 0,
/// Every mask is dropped when an insert would exceed this; 0 keeps masks off entirely.
max_mask_bytes: usize = 16 << 20,
outline_stats: Stats = .{},
mask_stats: Stats = .{},
/// Times the mask budget overflowed and the masks were cleared.
evictions: usize = 0,

pub fn init(gpa: Allocator) GlyphCache {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *GlyphCache) void {
    var glyphs = self.glyphs.valueIterator();
    while (glyphs.next()) |g| if (g.outline) |*o| o.deinit(self.gpa);
    self.glyphs.deinit(self.gpa);
    self.codepoints.deinit(self.gpa);
    self.kerns.deinit(self.gpa);
    self.clearMasks();
    self.masks.deinit(self.gpa);
    self.* = undefined;
}

/// The entry for `gid`, created empty on first use; null when it cannot be allocated, in
/// which case the caller reads the font directly. Valid until the next `glyph` call.
pub fn glyph(self: *GlyphCache, gid: u16) ?*Glyph {
    const slot = self.glyphs.getOrPut(self.gpa, gid) catch return null;
    if (!slot.found_existing) slot.value_ptr.* = .{};
    return slot.value_ptr;
}

pub fn getMask(self: *GlyphCache, key: MaskKey) ?Mask {
    const mask = self.masks.get(key);
    if (mask != null) self.mask_stats.hits += 1 else self.mask_stats.misses += 1;
    return mask;
}

/// Whether a `width` x `height` mask may be stored: no more than a sixteenth of the budget,
/// so one headline glyph cannot keep flushing the rest.
pub fn fits(self: GlyphCache, width: f32, height: f32) bool {
    return width * height <= as(f32, self.max_mask_bytes / 16);
}

/// Stores a zeroed mask for `key` (which must be new and `fits`) and returns it to be
/// rasterized into; every other mask is dropped first when the budget would overflow.
pub fn reserve(self: *GlyphCache, key: MaskKey, left: i32, top: i32, width: u32, height: u32) Allocator.Error!Mask {
    const bytes = @as(usize, width) * height;
    if (self.mask_bytes + bytes > self.max_mask_bytes) self.clearMasks();
    const data = try self.gpa.alloc(u8, bytes);
    errdefer self.gpa.free(data);
    @memset(data, 0);
    const mask: Mask = .{ .left = left, .top = top, .width = width, .height = height, .data = data };
    try self.masks.putNoClobber(self.gpa, key, mask);
    self.mask_bytes += bytes;
    return mask;
}

/// Forgets the mask for `key`, e.g. after failing to rasterize it.
pub fn drop(self: *GlyphCache, key: MaskKey) void {
    const removed = self.masks.fetchRemove(key) orelse return;
    self.mask_bytes -= removed.value.data.len;
    self.gpa.free(removed.value.data);
}

fn clearMasks(self: *GlyphCache) void {
    if (self.masks.count() == 0) return;
    var masks = self.masks.valueIterator();
    while (masks.next()) |m| self.gpa.free(m.data);
    self.masks.clearRetainingCapacity();
    self.mask_bytes = 0;
    self.evictions += 1;
}

const testing = std.testing;
const synthetic = @import("truetype/synthetic.zig");

test "enable and disable" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    var font = synthetic.font(&buf, .{});
    try testing.expect(font.cache == null);
    try font.enableCache(testing.allocator);
    const cache = font.cache.?;
    try font.enableCache(testing.allocator);
    try testing.expectEqual(cache, font.cache.?);
    // Copies share the pointer.
    const copy = font;
    try testing.expectEqual(cache, copy.cache.?);
    font.disableCache();
    try testing.expect(font.cache == null);
    font.disableCache();
}

test "level 1 matches the uncached font" {
    for ([_]synthetic.Options{ .{}, .{ .cff = true } }) |opts| {
        var plain_buf: [synthetic.buffer_size]u8 = undefined;
        const plain = synthetic.font(&plain_buf, opts);
        var buf: [synthetic.buffer_size]u8 = undefined;
        var cached = synthetic.font(&buf, opts);
        try cached.enableCache(testing.allocator);
        defer cached.disableCache();
        const cache = cached.cache.?;

        for ([_]u21{ 'A', 'B', 'C', 'D', 'E', 'F', 'a', 0x1F600, 'Z', 'A' }) |cp| {
            try testing.expectEqual(plain.glyphIndex(cp), cached.glyphIndex(cp));
        }
        try testing.expectEqual(@as(usize, 9), cache.codepoints.count());
        for ([_][2]u16{ .{ 1, 2 }, .{ 2, 1 }, .{ 1, 2 }, .{ 3, 3 } }) |pair| {
            try testing.expectEqual(plain.kern(pair[0], pair[1]), cached.kern(pair[0], pair[1]));
        }
        try testing.expectEqual(@as(usize, 3), cache.kerns.count());

        for (0..plain.num_glyphs) |i| {
            const gid: u16 = @intCast(i);
            try testing.expectEqual(plain.glyphMetrics(gid), cached.glyphMetrics(gid));
            try testing.expectEqual(plain.glyphBounds(gid), cached.glyphBounds(gid));
            try testing.expectEqual(plain.glyphBounds(gid), cached.glyphBounds(gid));

            var expected = try plain.outline(testing.allocator, gid);
            defer expected.deinit(testing.allocator);
            var first = try cached.outlineRef(testing.allocator, gid);
            defer first.deinit(testing.allocator);
            var second = try cached.outlineRef(testing.allocator, gid);
            defer second.deinit(testing.allocator);
            try testing.expect(!first.owned and !second.owned);
            try testing.expectEqual(first.outline.points.ptr, second.outline.points.ptr);
            try testing.expectEqualSlices(Outline.Point, expected.points, second.outline.points);
            try testing.expectEqualSlices(u32, expected.contour_ends, second.outline.contour_ends);
        }
        try testing.expectEqual(@as(usize, plain.num_glyphs), cache.glyphs.count());
        // Every outline was parsed once; for CFF the bounds read above parsed it, so both
        // `outlineRef` calls were hits.
        const hits: usize = if (opts.cff) 2 * @as(usize, plain.num_glyphs) else plain.num_glyphs;
        try testing.expectEqual(Stats{ .hits = hits, .misses = plain.num_glyphs }, cache.outline_stats);

        // An invalid id gets the fallback values and no entry.
        const invalid = plain.num_glyphs;
        try testing.expectEqual(plain.glyphMetrics(invalid), cached.glyphMetrics(invalid));
        try testing.expectEqual(plain.glyphBounds(invalid), cached.glyphBounds(invalid));
        try testing.expectEqual(@as(usize, plain.num_glyphs), cache.glyphs.count());

        // Without a cache the outline is owned.
        var owned = try plain.outlineRef(testing.allocator, 1);
        defer owned.deinit(testing.allocator);
        try testing.expect(owned.owned);
    }
}

test "placement snaps the origin to a quarter pixel" {
    const placed = place(7, .{ .scale = 0.5, .origin = .init(.{ 10.3, -0.9 }) });
    try testing.expectEqual(MaskKey{ .scale_bits = @bitCast(@as(f32, 0.5)), .gid = 7, .bx = 1, .by = 0 }, placed.key);
    try testing.expectEqual(@as(i32, 10), placed.x);
    try testing.expectEqual(@as(i32, -1), placed.y);
    try testing.expectEqual(@as(f32, 0.25), placed.phase.x());
    try testing.expectEqual(@as(f32, 0), placed.phase.y());
    // The fraction never rounds up into the next pixel.
    try testing.expectEqual(@as(u2, 3), phase(0.9999999));
}

test "mask store honors the budget" {
    var cache: GlyphCache = .init(testing.allocator);
    defer cache.deinit();
    cache.max_mask_bytes = 160;
    try testing.expect(cache.fits(2, 5));
    try testing.expect(!cache.fits(1, 11));

    const key: MaskKey = .{ .scale_bits = 0, .gid = 1, .bx = 0, .by = 0 };
    try testing.expect(cache.getMask(key) == null);
    for (0..3) |i| {
        const mask = try cache.reserve(.{ .scale_bits = 0, .gid = @intCast(i), .bx = 0, .by = 0 }, 0, 0, 6, 10);
        try testing.expect(std.mem.allEqual(u8, mask.data, 0));
    }
    // The third insert would have exceeded 160 bytes: the first two were dropped.
    try testing.expectEqual(@as(usize, 1), cache.masks.count());
    try testing.expectEqual(@as(usize, 60), cache.mask_bytes);
    try testing.expectEqual(@as(usize, 1), cache.evictions);
    try testing.expect(cache.getMask(key) == null);
    const two: MaskKey = .{ .scale_bits = 0, .gid = 2, .bx = 0, .by = 0 };
    try testing.expect(cache.getMask(two) != null);
    try testing.expectEqual(Stats{ .hits = 1, .misses = 2 }, cache.mask_stats);

    cache.drop(two);
    cache.drop(two);
    try testing.expectEqual(@as(usize, 0), cache.masks.count());
    try testing.expectEqual(@as(usize, 0), cache.mask_bytes);

    cache.max_mask_bytes = 0;
    try testing.expect(!cache.fits(1, 1));
}
