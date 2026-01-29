//! Run-Length Encoding (RLE) utility
//!
//! Provides generic RLE compression and expansion logic suitable for various
//! protocols, including Sixel graphics.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic RLE entry representing a value and its repetition count.
pub fn Entry(comptime T: type) type {
    return struct {
        value: T,
        count: usize,
    };
}

/// Compress a slice using RLE, returning a list of Entries.
/// Callers own the returned memory.
pub fn compress(comptime T: type, allocator: Allocator, data: []const T) ![]Entry(T) {
    if (data.len == 0) return &[_]Entry(T){};

    var result: std.ArrayList(Entry(T)) = .empty;
    errdefer result.deinit(allocator);

    var current_value = data[0];
    var current_count: usize = 1;

    for (data[1..]) |val| {
        if (std.meta.eql(val, current_value)) {
            current_count += 1;
        } else {
            try result.append(allocator, .{ .value = current_value, .count = current_count });
            current_value = val;
            current_count = 1;
        }
    }

    try result.append(allocator, .{ .value = current_value, .count = current_count });
    return result.toOwnedSlice(allocator);
}

/// Decompress a slice of RLE entries into a flat slice.
/// Callers own the returned memory.
pub fn decompress(comptime T: type, allocator: Allocator, entries: []const Entry(T)) ![]T {
    var total_count: usize = 0;
    for (entries) |entry| total_count = try std.math.add(usize, total_count, entry.count);

    const result = try allocator.alloc(T, total_count);
    errdefer allocator.free(result);

    var pos: usize = 0;
    for (entries) |entry| {
        @memset(result[pos .. pos + entry.count], entry.value);
        pos += entry.count;
    }

    return result;
}

/// Generic iterator for streaming RLE compression without intermediate allocations.
pub fn Compressor(comptime T: type) type {
    return struct {
        data: []const T,
        pos: usize = 0,

        const Self = @This();

        pub fn next(self: *Self) ?Entry(T) {
            if (self.pos >= self.data.len) return null;

            const start_pos = self.pos;
            const value = self.data[start_pos];
            self.pos += 1;

            while (self.pos < self.data.len and std.meta.eql(self.data[self.pos], value)) {
                self.pos += 1;
            }

            return Entry(T){
                .value = value,
                .count = self.pos - start_pos,
            };
        }
    };
}

/// Generic iterator for streaming RLE expansion.
pub fn Decompressor(comptime T: type) type {
    return struct {
        entries: []const Entry(T),
        entry_idx: usize = 0,
        sub_pos: usize = 0,

        const Self = @This();

        pub fn next(self: *Self) ?T {
            while (self.entry_idx < self.entries.len) {
                const entry = self.entries[self.entry_idx];
                if (self.sub_pos < entry.count) {
                    const val = entry.value;
                    self.sub_pos += 1;
                    return val;
                }
                self.entry_idx += 1;
                self.sub_pos = 0;
            }
            return null;
        }
    };
}

test "RLE basic compression" {
    const allocator = std.testing.allocator;
    const input = "AAAABBBCCDAA";
    const expected = [_]Entry(u8){
        .{ .value = 'A', .count = 4 },
        .{ .value = 'B', .count = 3 },
        .{ .value = 'C', .count = 2 },
        .{ .value = 'D', .count = 1 },
        .{ .value = 'A', .count = 2 },
    };

    const compressed = try compress(u8, allocator, input);
    defer allocator.free(compressed);

    try std.testing.expectEqual(expected.len, compressed.len);
    for (expected, compressed) |e, c| {
        try std.testing.expectEqual(e.value, c.value);
        try std.testing.expectEqual(e.count, c.count);
    }
}

test "RLE compressor iterator" {
    const input = [_]u32{ 10, 10, 20, 30, 30, 30 };
    var compressor = Compressor(u32){ .data = &input };

    const r1 = compressor.next().?;
    try std.testing.expectEqual(@as(u32, 10), r1.value);
    try std.testing.expectEqual(@as(usize, 2), r1.count);

    const r2 = compressor.next().?;
    try std.testing.expectEqual(@as(u32, 20), r2.value);
    try std.testing.expectEqual(@as(usize, 1), r2.count);

    const r3 = compressor.next().?;
    try std.testing.expectEqual(@as(u32, 30), r3.value);
    try std.testing.expectEqual(@as(usize, 3), r3.count);

    try std.testing.expect(compressor.next() == null);
}

test "RLE basic decompression" {
    const allocator = std.testing.allocator;
    const input = [_]Entry(u8){
        .{ .value = 'A', .count = 4 },
        .{ .value = 'B', .count = 3 },
    };
    const expected = "AAAABBB";

    const decompressed = try decompress(u8, allocator, &input);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, expected, decompressed);
}

test "RLE decompression overflow" {
    const allocator = std.testing.allocator;
    const input = [_]Entry(u8){
        .{ .value = 'A', .count = std.math.maxInt(usize) },
        .{ .value = 'B', .count = 1 },
    };

    const result = decompress(u8, allocator, &input);
    try std.testing.expectError(error.Overflow, result);
}

test "RLE decompressor iterator" {
    const entries = [_]Entry(u8){
        .{ .value = 'X', .count = 2 },
        .{ .value = 'Y', .count = 1 },
    };
    var decompressor = Decompressor(u8){ .entries = &entries };

    try std.testing.expectEqual(@as(?u8, 'X'), decompressor.next());
    try std.testing.expectEqual(@as(?u8, 'X'), decompressor.next());
    try std.testing.expectEqual(@as(?u8, 'Y'), decompressor.next());
    try std.testing.expectEqual(@as(?u8, null), decompressor.next());
}
