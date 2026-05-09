//! Variable-length LZW codec for GIF.
//!
//! GIF LZW packs codes LSB-first within bytes (opposite of TIFF/PDF). Codes are
//! 3..12 bits wide, growing as the dictionary fills. Two control codes:
//! `clear_code = 1 << min_code_size` resets the dictionary; `eoi_code =
//! clear_code + 1` ends the stream.
//!
//! The decoder is chunked: callers feed sub-block payloads via `decodeChunk`
//! and the decoder maintains its bit accumulator across calls. The encoder
//! consumes a flat slice of palette indices and emits raw LZW bytes; the GIF
//! caller wraps those in 0xFF-max sub-blocks.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

pub const max_lzw_bits: u4 = 12;
pub const max_dict_entries: u16 = 1 << max_lzw_bits; // 4096

const sentinel: u16 = std.math.maxInt(u16);

pub const Decoder = struct {
    min_code_size: u4,
    code_size: u4,
    clear_code: u16,
    eoi_code: u16,
    dict_size: u16,
    /// Most recently decoded code, or `sentinel` when waiting for the first
    /// non-control code after init / Clear.
    prev_code: u16,
    saw_eoi: bool,

    /// LSB-first bit accumulator straddling chunk boundaries.
    accum: u32,
    bits_in_accum: u5,

    /// Dictionary: each entry has a parent-code link plus the byte the code
    /// appended to its parent's string. Root entries are self-referential
    /// (parent = sentinel); the `string_buf` uses the chain to materialize
    /// strings on demand.
    prefix: [max_dict_entries]u16,
    suffix: [max_dict_entries]u8,

    /// Scratch buffer for reverse-walked strings.
    string_buf: [max_dict_entries]u8,

    pub fn init(min_code_size: u4) !Decoder {
        if (min_code_size < 2 or min_code_size > 8) return error.InvalidMinCodeSize;

        var self: Decoder = undefined;
        self.min_code_size = min_code_size;
        self.code_size = min_code_size + 1;
        self.clear_code = @as(u16, 1) << min_code_size;
        self.eoi_code = self.clear_code + 1;
        self.dict_size = self.eoi_code + 1;
        self.prev_code = sentinel;
        self.saw_eoi = false;
        self.accum = 0;
        self.bits_in_accum = 0;

        var i: u16 = 0;
        while (i < self.clear_code) : (i += 1) {
            self.prefix[i] = sentinel;
            self.suffix[i] = @intCast(i);
        }
        return self;
    }

    fn resetDict(self: *Decoder) void {
        self.code_size = self.min_code_size + 1;
        self.dict_size = self.eoi_code + 1;
        self.prev_code = sentinel;
    }

    /// Feeds `in` (one or more concatenated LZW data sub-block payloads, with
    /// sub-block framing already stripped) and writes decoded indices into
    /// `out`. Returns bytes written and bytes consumed; bit-level state is
    /// retained across calls so chunk boundaries are transparent.
    /// Returns `error.LzwOutputOverflow` if `out` cannot hold the next code's
    /// expansion — caller bounds total output by `width * height`.
    pub fn decodeChunk(self: *Decoder, in: []const u8, out: []u8) !struct { written: usize, consumed: usize } {
        var written: usize = 0;
        var consumed: usize = 0;

        while (true) {
            if (self.saw_eoi) break;

            // Refill accumulator until we have at least code_size bits.
            while (self.bits_in_accum < self.code_size) {
                if (consumed >= in.len) {
                    return .{ .written = written, .consumed = consumed };
                }
                const byte = in[consumed];
                self.accum |= @as(u32, byte) << @as(u5, @intCast(self.bits_in_accum));
                self.bits_in_accum += 8;
                consumed += 1;
            }

            const mask: u32 = (@as(u32, 1) << @as(u5, @intCast(self.code_size))) - 1;
            const code: u16 = @intCast(self.accum & mask);
            self.accum >>= @as(u5, @intCast(self.code_size));
            self.bits_in_accum -= @as(u5, @intCast(self.code_size));

            if (code == self.eoi_code) {
                self.saw_eoi = true;
                break;
            }

            if (code == self.clear_code) {
                self.resetDict();
                continue;
            }

            if (code > self.dict_size) return error.InvalidLzwCode;

            // K[0]wK pattern: code references the slot we're about to add.
            const is_special = code == self.dict_size;
            if (is_special and self.prev_code == sentinel) return error.InvalidLzwCode;
            const lookup_code: u16 = if (is_special) self.prev_code else code;

            // Walk the prefix chain into string_buf in reverse order.
            // For K[0]wK, the output is prev_string + first_char_of_prev_string.
            // In the reversed buffer that's [first_char, reversed(prev_string)],
            // so reserve position 0 for `first_char` and walk into [1..].
            var len: usize = if (is_special) 1 else 0;
            var cur: u16 = lookup_code;
            while (cur != sentinel) {
                self.string_buf[len] = self.suffix[cur];
                len += 1;
                if (len > max_dict_entries) return error.InvalidLzwCode;
                const next = self.prefix[cur];
                if (next == cur) return error.InvalidLzwCode; // self-loop guard
                cur = next;
            }

            const first_char = self.string_buf[len - 1];
            if (is_special) {
                self.string_buf[0] = first_char;
            }

            if (out.len - written < len) return error.LzwOutputOverflow;

            // Reverse-copy into out.
            var k: usize = 0;
            while (k < len) : (k += 1) {
                out[written + k] = self.string_buf[len - 1 - k];
            }
            written += len;

            // Add new entry: prev_code -> first_char (skipped for first code after Clear).
            if (self.prev_code != sentinel and self.dict_size < max_dict_entries) {
                self.prefix[self.dict_size] = self.prev_code;
                self.suffix[self.dict_size] = first_char;
                self.dict_size += 1;

                // Grow code_size in lockstep with the encoder: when the slot we
                // just inserted saturates the current width, the next code in
                // the stream will be one bit wider.
                if (self.dict_size == (@as(u16, 1) << self.code_size) and self.code_size < max_lzw_bits) {
                    self.code_size += 1;
                }
            }

            self.prev_code = code;
        }

        return .{ .written = written, .consumed = consumed };
    }

    pub fn isDone(self: Decoder) bool {
        return self.saw_eoi;
    }
};

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

pub const Encoder = struct {
    const DictKey = struct {
        prefix: u16,
        suffix: u8,
    };

    min_code_size: u4,
    code_size: u4,
    clear_code: u16,
    eoi_code: u16,
    next_code: u16,

    /// Maps (prefix_code, suffix_byte) → child_code.
    dict: std.AutoHashMapUnmanaged(DictKey, u16),

    /// LSB-first bit accumulator written out as full bytes whenever ≥ 8 bits.
    bit_accum: u32,
    bits_in_accum: u5,

    pub fn init(gpa: std.mem.Allocator, min_code_size: u4) !Encoder {
        if (min_code_size < 2 or min_code_size > 8) return error.InvalidMinCodeSize;
        var self: Encoder = .{
            .min_code_size = min_code_size,
            .code_size = min_code_size + 1,
            .clear_code = @as(u16, 1) << min_code_size,
            .eoi_code = (@as(u16, 1) << min_code_size) + 1,
            .next_code = (@as(u16, 1) << min_code_size) + 2,
            .dict = .empty,
            .bit_accum = 0,
            .bits_in_accum = 0,
        };
        try self.dict.ensureTotalCapacity(gpa, max_dict_entries);
        return self;
    }

    pub fn deinit(self: *Encoder, gpa: std.mem.Allocator) void {
        self.dict.deinit(gpa);
    }

    fn resetDict(self: *Encoder) void {
        self.dict.clearRetainingCapacity();
        self.code_size = self.min_code_size + 1;
        self.next_code = self.eoi_code + 1;
    }

    fn emitCode(self: *Encoder, gpa: std.mem.Allocator, code: u16, out: *std.ArrayList(u8)) !void {
        self.bit_accum |= @as(u32, code) << @as(u5, @intCast(self.bits_in_accum));
        self.bits_in_accum += @as(u5, @intCast(self.code_size));
        while (self.bits_in_accum >= 8) {
            try out.append(gpa, @intCast(self.bit_accum & 0xFF));
            self.bit_accum >>= 8;
            self.bits_in_accum -= 8;
        }
    }

    fn flushBits(self: *Encoder, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.bits_in_accum > 0) {
            try out.append(gpa, @intCast(self.bit_accum & 0xFF));
            self.bit_accum = 0;
            self.bits_in_accum = 0;
        }
    }

    /// Compresses `indices` (palette indices in scan order) into raw LZW bytes.
    /// Caller wraps the result in 0xFF-max sub-blocks separately.
    pub fn encodeAll(self: *Encoder, gpa: std.mem.Allocator, indices: []const u8, out: *std.ArrayList(u8)) !void {
        try self.emitCode(gpa, self.clear_code, out);

        if (indices.len == 0) {
            try self.emitCode(gpa, self.eoi_code, out);
            try self.flushBits(gpa, out);
            return;
        }

        var prev_code: u16 = indices[0];

        for (indices[1..]) |b| {
            const key: DictKey = .{ .prefix = prev_code, .suffix = b };
            if (self.dict.get(key)) |child| {
                prev_code = child;
            } else {
                try self.emitCode(gpa, prev_code, out);

                if (self.next_code < max_dict_entries) {
                    self.dict.putAssumeCapacity(key, self.next_code);
                    self.next_code += 1;
                    // Grow when the just-inserted slot can no longer be referenced at
                    // the current width — i.e., next_code now exceeds (1 << W).
                    if (self.next_code > (@as(u16, 1) << self.code_size) and self.code_size < max_lzw_bits) {
                        self.code_size += 1;
                    }
                } else {
                    // Dictionary full — emit Clear and reset.
                    try self.emitCode(gpa, self.clear_code, out);
                    self.resetDict();
                }

                prev_code = b;
            }
        }

        try self.emitCode(gpa, prev_code, out);
        try self.emitCode(gpa, self.eoi_code, out);
        try self.flushBits(gpa, out);
    }
};

// ---------------------------------------------------------------------------
// De-interlace
// ---------------------------------------------------------------------------

/// GIF interlace order is 4 passes:
///   pass 1: rows 0, 8, 16, ...
///   pass 2: rows 4, 12, 20, ...
///   pass 3: rows 2, 6, 10, 14, ...
///   pass 4: rows 1, 3, 5, 7, ...
/// `src` holds pass-ordered rows; `dst` receives them in display order.
/// Both buffers must be exactly `width * height` bytes.
pub fn deinterlace(src: []const u8, dst: []u8, width: usize, height: usize) void {
    std.debug.assert(src.len == width * height);
    std.debug.assert(dst.len == width * height);

    const passes = [_]struct { start: usize, step: usize }{
        .{ .start = 0, .step = 8 },
        .{ .start = 4, .step = 8 },
        .{ .start = 2, .step = 4 },
        .{ .start = 1, .step = 2 },
    };

    var src_row: usize = 0;
    for (passes) |pass| {
        var dst_row: usize = pass.start;
        while (dst_row < height) : (dst_row += pass.step) {
            const src_off = src_row * width;
            const dst_off = dst_row * width;
            @memcpy(dst[dst_off .. dst_off + width], src[src_off .. src_off + width]);
            src_row += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "LZW decoder — 4-color sequence with code-size growth" {
    // Indices [0, 1, 2, 3], min_code_size = 2.
    // Encoder emits Clear@3, 0@3, 1@3, 2@3, then grows after the third user
    // emission saturates dict at slot 8, so 3@4 and EOI@4. Total 4*3 + 2*4 = 20
    // bits → 3 bytes (4 padding bits at the end).
    //   bit 0..2  Clear=4 → 0,0,1
    //   bit 3..5  0       → 0,0,0
    //   bit 6..8  1       → 1,0,0
    //   bit 9..11 2       → 0,1,0
    //   bit 12..15 3      → 1,1,0,0
    //   bit 16..19 EOI=5  → 1,0,1,0
    //   byte 0 = 0b00100100 = 0x44
    //   byte 1 = 0b00110100 = 0x34
    //   byte 2 = 0b00000101 = 0x05
    const in = [_]u8{ 0x44, 0x34, 0x05 };
    var dec = try Decoder.init(2);
    var out: [16]u8 = undefined;
    const r = try dec.decodeChunk(&in, &out);
    try expect(dec.isDone());
    try expectEqual(@as(usize, 4), r.written);
    try expectEqual(@as(u8, 0), out[0]);
    try expectEqual(@as(u8, 1), out[1]);
    try expectEqual(@as(u8, 2), out[2]);
    try expectEqual(@as(u8, 3), out[3]);
}

test "LZW decoder — repeated literal forms a longer dictionary entry" {
    // Stream: Clear=4, 0, 0, EOI=5 at min_code_size=2 (code_size=3 throughout).
    // Total bits: 4*3 = 12 → 2 bytes.
    // Codes: 100, 000, 000, 101 → bits 0..11
    //   bit0..2 = 100, bit3..5 = 000, bit6..8 = 000, bit9..11 = 101
    //   byte 0: bits 0..7 = 0,0,1,0,0,0,0,0 = 0x04
    //   byte 1: bits 8..11 + padding = 0,1,0,1,0,0,0,0 = 0x0A
    const in = [_]u8{ 0x04, 0x0A };
    var dec = try Decoder.init(2);
    var out: [16]u8 = undefined;
    const r = try dec.decodeChunk(&in, &out);
    try expect(dec.isDone());
    try expectEqual(@as(usize, 2), r.written);
    try expectEqual(@as(u8, 0), out[0]);
    try expectEqual(@as(u8, 0), out[1]);
}

test "LZW decoder — special K[0]wK pattern" {
    // Three-zero input: encoder emits [Clear=4, 0, 6, EOI=5].
    //   Code 6 references dict[6] which is being added at decode time
    //   (the K[0]wK case): decoder must reconstruct it as prev_string + prev_string[0].
    //   At min_code_size=2 every code is 3 bits (we never hit dict_size=8).
    // LSB-first packing:
    //   bit 0..2  Clear=4   → 0,0,1
    //   bit 3..5  0         → 0,0,0
    //   bit 6..8  6         → 0,1,1   (bits 6,7 in byte 0; bit 8 in byte 1)
    //   bit 9..11 EOI=5     → 1,0,1
    //   byte 0 = 0b10000100 = 0x84
    //   byte 1 = 0b00001011 = 0x0B
    const in = [_]u8{ 0x84, 0x0B };
    var dec = try Decoder.init(2);
    var out: [16]u8 = undefined;
    const r = try dec.decodeChunk(&in, &out);
    try expect(dec.isDone());
    try expectEqual(@as(usize, 3), r.written);
    try expectEqual(@as(u8, 0), out[0]);
    try expectEqual(@as(u8, 0), out[1]);
    try expectEqual(@as(u8, 0), out[2]);
}

test "LZW decoder — empty input returns immediately, not done" {
    var dec = try Decoder.init(2);
    var out: [4]u8 = undefined;
    const r = try dec.decodeChunk(&[_]u8{}, &out);
    try expectEqual(@as(usize, 0), r.written);
    try expectEqual(@as(usize, 0), r.consumed);
    try expect(!dec.isDone());
}

test "LZW decoder — output buffer overflow rejected" {
    const in = [_]u8{ 0x44, 0x34, 0x05 };
    var dec = try Decoder.init(2);
    var out: [2]u8 = undefined;
    try expectError(error.LzwOutputOverflow, dec.decodeChunk(&in, &out));
}

test "LZW decoder — chunk boundary mid-code" {
    var dec = try Decoder.init(2);
    var out: [16]u8 = undefined;
    var written_total: usize = 0;

    const r1 = try dec.decodeChunk(&[_]u8{0x44}, out[written_total..]);
    written_total += r1.written;
    try expect(!dec.isDone());

    const r2 = try dec.decodeChunk(&[_]u8{ 0x34, 0x05 }, out[written_total..]);
    written_total += r2.written;
    try expect(dec.isDone());
    try expectEqual(@as(usize, 4), written_total);
    try expectEqual(@as(u8, 0), out[0]);
    try expectEqual(@as(u8, 1), out[1]);
    try expectEqual(@as(u8, 2), out[2]);
    try expectEqual(@as(u8, 3), out[3]);
}

test "LZW decoder — invalid min_code_size rejected" {
    try expectError(error.InvalidMinCodeSize, Decoder.init(1));
    try expectError(error.InvalidMinCodeSize, Decoder.init(9));
}

// ---------------------------------------------------------------------------
// Encoder + round-trip tests
// ---------------------------------------------------------------------------

fn roundTrip(gpa: std.mem.Allocator, min_code_size: u4, indices: []const u8) !void {
    var encoder = try Encoder.init(gpa, min_code_size);
    defer encoder.deinit(gpa);

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);

    try encoder.encodeAll(gpa, indices, &encoded);

    var decoder = try Decoder.init(min_code_size);
    const decoded = try gpa.alloc(u8, indices.len);
    defer gpa.free(decoded);

    const r = try decoder.decodeChunk(encoded.items, decoded);
    try expect(decoder.isDone());
    try expectEqual(indices.len, r.written);
    try std.testing.expectEqualSlices(u8, indices, decoded);
}

test "LZW encoder — empty input round-trips" {
    const gpa = std.testing.allocator;
    try roundTrip(gpa, 2, &[_]u8{});
}

test "LZW encoder — round-trip [0, 1, 2, 3] at min_code_size=2" {
    const gpa = std.testing.allocator;
    try roundTrip(gpa, 2, &[_]u8{ 0, 1, 2, 3 });
}

test "LZW encoder — round-trip repeated zeros" {
    const gpa = std.testing.allocator;
    try roundTrip(gpa, 2, &[_]u8{ 0, 0, 0, 0 });
    try roundTrip(gpa, 2, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
}

test "LZW encoder — round-trip alternating 0,1 length 4" {
    const gpa = std.testing.allocator;
    try roundTrip(gpa, 2, &.{ 0, 1, 0, 1 });
}

test "LZW encoder — round-trip alternating 0,1 length 6" {
    const gpa = std.testing.allocator;
    try roundTrip(gpa, 2, &.{ 0, 1, 0, 1, 0, 1 });
}

test "LZW encoder — round-trip alternating 0,1 length 8" {
    const gpa = std.testing.allocator;
    try roundTrip(gpa, 2, &.{ 0, 1, 0, 1, 0, 1, 0, 1 });
}

test "LZW encoder — round-trip alternating 0,1 length 256" {
    const gpa = std.testing.allocator;
    var indices: [256]u8 = undefined;
    for (&indices, 0..) |*p, i| p.* = if (i % 2 == 0) 0 else 1;
    try roundTrip(gpa, 2, &indices);
}

test "LZW encoder — round-trip 8-bit min_code_size with 256 colors" {
    const gpa = std.testing.allocator;
    var indices: [1024]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    rng.random().bytes(&indices);
    try roundTrip(gpa, 8, &indices);
}

test "LZW encoder — long stream forces dictionary reset" {
    const gpa = std.testing.allocator;
    // Long pseudo-random sequence at small palette to push past 4096 entries.
    var indices: [16384]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0xBADCAFE);
    for (&indices) |*p| p.* = rng.random().int(u4) & 0x0F; // 4-bit values
    try roundTrip(gpa, 4, &indices);
}

test "deinterlace — 8x8 round-trip via pass order" {
    // Fill src in pass order: row 0 of pass 1, row 1, row 2, ... row 7.
    // After deinterlacing, dst should have rows in display order 0..7 with
    // values matching the canonical pass→display mapping.
    var src: [8 * 8]u8 = undefined;
    var dst: [8 * 8]u8 = undefined;

    // Pass 1: src row 0 → dst row 0; src row 1 → dst row 8 (out of range for h=8);
    //   so for h=8 only dst rows {0, 4, 2, 6, 1, 3, 5, 7} from passes 1..4.
    //   Pass 1: rows 0          (1 row)
    //   Pass 2: rows 4          (1 row)
    //   Pass 3: rows 2, 6       (2 rows)
    //   Pass 4: rows 1, 3, 5, 7 (4 rows)
    //   Total: 8 rows.
    const pass_order = [_]u8{ 0, 4, 2, 6, 1, 3, 5, 7 };

    for (0..8) |sr| {
        const dst_row = pass_order[sr];
        for (0..8) |c| src[sr * 8 + c] = @intCast(dst_row); // tag each pixel with its expected display row
    }

    deinterlace(&src, &dst, 8, 8);

    for (0..8) |dst_row| {
        for (0..8) |c| {
            try expectEqual(@as(u8, @intCast(dst_row)), dst[dst_row * 8 + c]);
        }
    }
}
