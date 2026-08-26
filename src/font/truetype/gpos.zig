//! GPOS pair adjustment (kerning): lookup type 2 in formats 1 and 2, reached
//! directly or through extension lookups (type 9). Script and feature lists are
//! ignored; every pair-positioning lookup in the font applies.

const std = @import("std");

const truetype = @import("../truetype.zig");
const Error = truetype.Error;
const Reader = truetype.Reader;

const lookup_type_pair = 2;
const lookup_type_extension = 9;
const value_x_advance: u16 = 0x0004;

/// Whether the font has any pair-positioning lookup; without one the table is useless here.
pub fn hasPairPos(r: Reader) bool {
    return hasPairPosInner(r) catch false;
}

fn hasPairPosInner(r: Reader) Error!bool {
    const lookup_list: usize = try r.u16At(8);
    const count = try r.u16At(lookup_list);
    for (0..count) |i| {
        const lookup = lookup_list + try r.u16At(lookup_list + 2 + 2 * i);
        var kind = try r.u16At(lookup);
        if (kind == lookup_type_extension) {
            if (try r.u16At(lookup + 4) == 0) continue;
            kind = try r.u16At(lookup + try r.u16At(lookup + 6) + 2);
        }
        if (kind == lookup_type_pair) return true;
    }
    return false;
}

/// Horizontal advance adjustment for the pair, summed over lookups; within a lookup the
/// first subtable that covers the pair wins. 0 when nothing applies or the table is malformed.
pub fn pairAdjust(r: Reader, left: u16, right: u16) i16 {
    return pairAdjustInner(r, left, right) catch 0;
}

fn pairAdjustInner(r: Reader, left: u16, right: u16) Error!i16 {
    const lookup_list: usize = try r.u16At(8);
    const count = try r.u16At(lookup_list);
    var total: i32 = 0;
    for (0..count) |i| {
        const lookup = lookup_list + try r.u16At(lookup_list + 2 + 2 * i);
        const kind = try r.u16At(lookup);
        if (kind != lookup_type_pair and kind != lookup_type_extension) continue;
        const subtable_count = try r.u16At(lookup + 4);
        for (0..subtable_count) |j| {
            var subtable = lookup + try r.u16At(lookup + 6 + 2 * j);
            if (kind == lookup_type_extension) {
                if (try r.u16At(subtable + 2) != lookup_type_pair) break;
                subtable += try r.u32At(subtable + 4);
            }
            if (try pairSubtable(r, subtable, left, right)) |value| {
                total += value;
                break;
            }
        }
    }
    return std.math.lossyCast(i16, total);
}

/// The pair's x-advance adjustment, or null when this subtable does not cover it.
fn pairSubtable(r: Reader, sub: usize, left: u16, right: u16) Error!?i16 {
    const coverage = sub + try r.u16At(sub + 2);
    const coverage_index = try coverageIndex(r, coverage, left) orelse return null;
    const value_format1 = try r.u16At(sub + 4);
    const value_format2 = try r.u16At(sub + 6);
    const record_size = 2 * @as(usize, @popCount(value_format1)) + 2 * @as(usize, @popCount(value_format2));
    // XPlacement and YPlacement precede XAdvance in a value record.
    const x_advance: ?usize = if (value_format1 & value_x_advance != 0) 2 * @as(usize, @popCount(value_format1 & 0x3)) else null;

    switch (try r.u16At(sub)) {
        1 => {
            const pair_set_count = try r.u16At(sub + 8);
            if (coverage_index >= pair_set_count) return null;
            const pair_set = sub + try r.u16At(sub + 10 + 2 * @as(usize, coverage_index));
            const pair_count = try r.u16At(pair_set);
            const pair_size = 2 + record_size;
            const i = try r.lowerBound(u16, pair_set + 2, pair_size, pair_count, 0, right);
            const rec = pair_set + 2 + i * pair_size;
            if (i == pair_count or try r.u16At(rec) != right) return null;
            return try valueAt(r, rec + 2, x_advance);
        },
        2 => {
            const class1 = try classOf(r, sub + try r.u16At(sub + 8), left);
            const class2 = try classOf(r, sub + try r.u16At(sub + 10), right);
            const class1_count = try r.u16At(sub + 12);
            const class2_count = try r.u16At(sub + 14);
            if (class1 >= class1_count or class2 >= class2_count) return null;
            const rec = sub + 16 + (@as(usize, class1) * class2_count + class2) * record_size;
            return try valueAt(r, rec, x_advance);
        },
        else => return null,
    }
}

fn valueAt(r: Reader, rec: usize, x_advance: ?usize) Error!i16 {
    return if (x_advance) |off| try r.i16At(rec + off) else 0;
}

/// Index of `gid` in a coverage table, or null when not covered.
fn coverageIndex(r: Reader, cov: usize, gid: u16) Error!?u16 {
    switch (try r.u16At(cov)) {
        1 => {
            const count = try r.u16At(cov + 2);
            const i = try r.lowerBound(u16, cov + 4, 2, count, 0, gid);
            if (i == count or try r.u16At(cov + 4 + 2 * i) != gid) return null;
            return @intCast(i);
        },
        2 => {
            const rec = try rangeRecord(r, cov + 4, try r.u16At(cov + 2), gid) orelse return null;
            return rec.value +% (gid - rec.start);
        },
        else => return null,
    }
}

/// The `{start, end, value}` range record containing `gid`, or null.
fn rangeRecord(r: Reader, base: usize, count: u16, gid: u16) Error!?struct { start: u16, value: u16 } {
    // The ranges are sorted and disjoint: the first whose end reaches gid is the candidate.
    const i = try r.lowerBound(u16, base, 6, count, 2, gid);
    if (i == count) return null;
    const rec = base + 6 * i;
    const start = try r.u16At(rec);
    if (gid < start) return null;
    return .{ .start = start, .value = try r.u16At(rec + 4) };
}

/// Class of `gid` in a class definition table; 0 when unlisted.
fn classOf(r: Reader, class_def: usize, gid: u16) Error!u16 {
    switch (try r.u16At(class_def)) {
        1 => {
            const start = try r.u16At(class_def + 2);
            const count = try r.u16At(class_def + 4);
            if (gid < start or gid - start >= count) return 0;
            return try r.u16At(class_def + 6 + 2 * @as(usize, gid - start));
        },
        2 => {
            const rec = try rangeRecord(r, class_def + 4, try r.u16At(class_def + 2), gid) orelse return 0;
            return rec.value;
        },
        else => return 0,
    }
}

const synthetic = @import("synthetic.zig");
const VectorFont = @import("../VectorFont.zig");

test "pair adjustment: format 1, format 2 via extension, GPOS over kern" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    try std.testing.expect(font.tables.gpos != null);
    // Format 1 pair set of glyph 1; the class lookup adds 0 for (class 1, class 0).
    try std.testing.expectEqual(@as(i16, -80), font.kern(1, 3));
    // Not in the pair set, so only the format 2 class pair (1, 1) applies; the kern
    // table's -50 for the same pair is ignored.
    try std.testing.expectEqual(@as(i16, -30), font.kern(1, 2));
    try std.testing.expectEqual(@as(i16, -30), font.kern(2, 2));
    try std.testing.expectEqual(@as(i16, 0), font.kern(3, 1));
    try std.testing.expectEqual(@as(i16, 0), font.kern(0, 0));
}

test "truncated GPOS reads as no kerning" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    var font = synthetic.font(&buf, .{});
    font.tables.gpos.?.len = 12;
    try std.testing.expectEqual(@as(i16, 0), font.kern(1, 3));
}
