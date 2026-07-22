//! Data segment encoding and decoding: mode selection, character counts,
//! bitstream construction with terminator and padding.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const tables = @import("tables.zig");

pub const Mode = enum(u4) {
    numeric = 0b0001,
    alphanumeric = 0b0010,
    byte = 0b0100,

    /// Number of bits in the character count field for a version.
    pub fn charCountBits(self: Mode, version: u8) u5 {
        const band: usize = if (version <= 9) 0 else if (version <= 26) 1 else 2;
        const widths: [3]u5 = switch (self) {
            .numeric => .{ 10, 12, 14 },
            .alphanumeric => .{ 9, 11, 13 },
            .byte => .{ 8, 16, 16 },
        };
        return widths[band];
    }
};

/// The densest single mode that can represent data.
pub fn detectMode(data: []const u8) Mode {
    var mode: Mode = .numeric;
    for (data) |char| {
        if (char >= '0' and char <= '9') continue;
        if (tables.alphanumericValue(char) != null) {
            mode = .alphanumeric;
        } else {
            return .byte;
        }
    }
    return mode;
}

/// Number of bits the data occupies in a mode, excluding the mode indicator
/// and character count field.
fn dataBits(mode: Mode, len: usize) usize {
    const numeric_extra = [3]usize{ 0, 4, 7 };
    return switch (mode) {
        .numeric => 10 * (len / 3) + numeric_extra[len % 3],
        .alphanumeric => 11 * (len / 2) + 6 * (len % 2),
        .byte => 8 * len,
    };
}

/// Total bits for a single segment holding data in mode at version.
pub fn segmentBits(mode: Mode, version: u8, len: usize) usize {
    return 4 + mode.charCountBits(version) + dataBits(mode, len);
}

/// The smallest version whose data capacity at level fits the message.
pub fn fitVersion(mode: Mode, level: tables.EcLevel, len: usize) !u8 {
    for (tables.min_version..tables.max_version + 1) |v| {
        const version: u8 = @intCast(v);
        const capacity = tables.ecBlocks(version, level).dataCodewords() * 8;
        if (segmentBits(mode, version, len) <= capacity) return version;
    }
    return error.DataTooLarge;
}

/// Appends bits most significant first to a byte list.
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_len: usize = 0,

    fn deinit(self: *BitWriter, allocator: Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn writeBits(self: *BitWriter, allocator: Allocator, value: u32, count: u5) !void {
        var i = count;
        while (i > 0) {
            i -= 1;
            if (self.bit_len % 8 == 0) try self.bytes.append(allocator, 0);
            const bit: u8 = @intCast(value >> i & 1);
            self.bytes.items[self.bit_len / 8] |= bit << @intCast(7 - self.bit_len % 8);
            self.bit_len += 1;
        }
    }
};

/// Reads bits most significant first from a byte slice.
const BitReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn remaining(self: BitReader) usize {
        return self.bytes.len * 8 - self.pos;
    }

    fn readBits(self: *BitReader, count: u5) !u32 {
        if (count > self.remaining()) return error.UnexpectedEndOfData;
        var value: u32 = 0;
        for (0..count) |_| {
            const bit = self.bytes[self.pos / 8] >> @intCast(7 - self.pos % 8) & 1;
            value = value << 1 | bit;
            self.pos += 1;
        }
        return value;
    }
};

/// Encodes data as a single segment with terminator and padding, producing
/// exactly the data codewords for the version and level. Caller frees.
pub fn buildCodewords(
    allocator: Allocator,
    data: []const u8,
    mode: Mode,
    version: u8,
    level: tables.EcLevel,
) ![]u8 {
    const capacity = tables.ecBlocks(version, level).dataCodewords();
    assert(segmentBits(mode, version, data.len) <= capacity * 8);

    var writer: BitWriter = .{};
    errdefer writer.deinit(allocator);
    try writer.writeBits(allocator, @backingInt(mode), 4);
    try writer.writeBits(allocator, @intCast(data.len), mode.charCountBits(version));

    switch (mode) {
        .numeric => {
            var i: usize = 0;
            while (i < data.len) : (i += 3) {
                const group = data[i..@min(i + 3, data.len)];
                var value: u32 = 0;
                for (group) |char| {
                    assert(char >= '0' and char <= '9');
                    value = value * 10 + (char - '0');
                }
                try writer.writeBits(allocator, value, @intCast(1 + 3 * group.len));
            }
        },
        .alphanumeric => {
            var i: usize = 0;
            while (i < data.len) : (i += 2) {
                if (i + 1 < data.len) {
                    const hi: u32 = tables.alphanumericValue(data[i]).?;
                    const lo: u32 = tables.alphanumericValue(data[i + 1]).?;
                    try writer.writeBits(allocator, hi * 45 + lo, 11);
                } else {
                    try writer.writeBits(allocator, tables.alphanumericValue(data[i]).?, 6);
                }
            }
        },
        .byte => {
            for (data) |char| try writer.writeBits(allocator, char, 8);
        },
    }

    // Terminator: up to 4 zero bits, truncated at capacity.
    const terminator: u5 = @intCast(@min(4, capacity * 8 - writer.bit_len));
    try writer.writeBits(allocator, 0, terminator);
    // Zero bits to the next codeword boundary.
    if (writer.bit_len % 8 != 0) {
        try writer.writeBits(allocator, 0, @intCast(8 - writer.bit_len % 8));
    }
    // Alternating pad codewords fill the remaining capacity.
    var pad: u8 = 0xec;
    while (writer.bytes.items.len < capacity) {
        try writer.bytes.append(allocator, pad);
        pad ^= 0xec ^ 0x11;
    }
    return writer.bytes.toOwnedSlice(allocator);
}

/// Decodes the segments in the data codewords back into bytes. Caller frees.
pub fn readSegments(allocator: Allocator, codewords: []const u8, version: u8) ![]u8 {
    var reader: BitReader = .{ .bytes = codewords };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (reader.remaining() >= 4) {
        const indicator = try reader.readBits(4);
        if (indicator == 0) break; // terminator
        const mode = std.enums.fromInt(Mode, indicator) orelse return error.UnsupportedMode;
        const count = try reader.readBits(mode.charCountBits(version));
        switch (mode) {
            .numeric => {
                var left = count;
                while (left > 0) {
                    const digits: u32 = @min(left, 3);
                    var value = try reader.readBits(@intCast(1 + 3 * digits));
                    var chars: [3]u8 = undefined;
                    var i = digits;
                    while (i > 0) {
                        i -= 1;
                        chars[i] = @intCast('0' + value % 10);
                        value /= 10;
                    }
                    if (value != 0) return error.InvalidData;
                    try out.appendSlice(allocator, chars[0..digits]);
                    left -= digits;
                }
            },
            .alphanumeric => {
                var left = count;
                while (left > 0) {
                    if (left >= 2) {
                        const value = try reader.readBits(11);
                        if (value >= 45 * 45) return error.InvalidData;
                        try out.append(allocator, tables.alphanumeric_charset[value / 45]);
                        try out.append(allocator, tables.alphanumeric_charset[value % 45]);
                        left -= 2;
                    } else {
                        const value = try reader.readBits(6);
                        if (value >= 45) return error.InvalidData;
                        try out.append(allocator, tables.alphanumeric_charset[value]);
                        left -= 1;
                    }
                }
            },
            .byte => {
                for (0..count) |_| {
                    try out.append(allocator, @intCast(try reader.readBits(8)));
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

test "detectMode" {
    try std.testing.expectEqual(Mode.numeric, detectMode("0123456789"));
    try std.testing.expectEqual(Mode.alphanumeric, detectMode("HELLO WORLD"));
    try std.testing.expectEqual(Mode.byte, detectMode("hello"));
    try std.testing.expectEqual(Mode.numeric, detectMode(""));
}

test "ISO 18004 Annex I data codewords" {
    // "01234567" as version 1-M: 16 data codewords including padding.
    const codewords = try buildCodewords(std.testing.allocator, "01234567", .numeric, 1, .medium);
    defer std.testing.allocator.free(codewords);
    const expected = [_]u8{ 0x10, 0x20, 0x0c, 0x56, 0x61, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11 };
    try std.testing.expectEqualSlices(u8, &expected, codewords);
}

test "segment roundtrip across modes" {
    const cases = [_][]const u8{ "0123456789012345", "HELLO WORLD $%*+-./:", "byte mode \xff\x00 data", "8", "AC-42", "" };
    for (cases) |data| {
        const mode = detectMode(data);
        const version = try fitVersion(mode, .quartile, data.len);
        const codewords = try buildCodewords(std.testing.allocator, data, mode, version, .quartile);
        defer std.testing.allocator.free(codewords);
        const decoded = try readSegments(std.testing.allocator, codewords, version);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, data, decoded);
    }
}

test "fitVersion picks minimal version and errors when too large" {
    // 25 alphanumeric characters need version 2 at level L? Version 1-L holds
    // up to 25 alphanumeric characters, so 25 fits and 26 does not.
    try std.testing.expectEqual(@as(u8, 1), try fitVersion(.alphanumeric, .low, 25));
    try std.testing.expectEqual(@as(u8, 2), try fitVersion(.alphanumeric, .low, 26));
    try std.testing.expectError(error.DataTooLarge, fitVersion(.byte, .high, 100_000));
}
