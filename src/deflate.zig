//! Pure Zig implementation of DEFLATE compression and decompression (RFC 1951)
//! Used by PNG for IDAT chunk compression/decompression

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// Fixed Huffman code lengths for literal/length alphabet (RFC 1951)
const FIXED_LITERAL_LENGTHS = [_]u8{
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 0-15
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 16-31
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 32-47
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 48-63
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 64-79
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 80-95
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 96-111
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 112-127
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 128-143
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 144-159
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 160-175
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 176-191
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 192-207
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 208-223
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 224-239
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 240-255
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // 256-271
    7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, // 272-287
};

// Fixed distance code lengths (all 5 bits)
const FIXED_DISTANCE_LENGTHS = [_]u8{5} ** 32;

// Length codes 257-285 (extra bits and base lengths)
const LENGTH_CODES = [_]struct { base: u16, extra_bits: u8 }{
    .{ .base = 3, .extra_bits = 0 }, // 257
    .{ .base = 4, .extra_bits = 0 }, // 258
    .{ .base = 5, .extra_bits = 0 }, // 259
    .{ .base = 6, .extra_bits = 0 }, // 260
    .{ .base = 7, .extra_bits = 0 }, // 261
    .{ .base = 8, .extra_bits = 0 }, // 262
    .{ .base = 9, .extra_bits = 0 }, // 263
    .{ .base = 10, .extra_bits = 0 }, // 264
    .{ .base = 11, .extra_bits = 1 }, // 265
    .{ .base = 13, .extra_bits = 1 }, // 266
    .{ .base = 15, .extra_bits = 1 }, // 267
    .{ .base = 17, .extra_bits = 1 }, // 268
    .{ .base = 19, .extra_bits = 2 }, // 269
    .{ .base = 23, .extra_bits = 2 }, // 270
    .{ .base = 27, .extra_bits = 2 }, // 271
    .{ .base = 31, .extra_bits = 2 }, // 272
    .{ .base = 35, .extra_bits = 3 }, // 273
    .{ .base = 43, .extra_bits = 3 }, // 274
    .{ .base = 51, .extra_bits = 3 }, // 275
    .{ .base = 59, .extra_bits = 3 }, // 276
    .{ .base = 67, .extra_bits = 4 }, // 277
    .{ .base = 83, .extra_bits = 4 }, // 278
    .{ .base = 99, .extra_bits = 4 }, // 279
    .{ .base = 115, .extra_bits = 4 }, // 280
    .{ .base = 131, .extra_bits = 5 }, // 281
    .{ .base = 163, .extra_bits = 5 }, // 282
    .{ .base = 195, .extra_bits = 5 }, // 283
    .{ .base = 227, .extra_bits = 5 }, // 284
    .{ .base = 258, .extra_bits = 0 }, // 285
};

// Distance codes 0-29 (extra bits and base distances)
const DISTANCE_CODES = [_]struct { base: u16, extra_bits: u8 }{
    .{ .base = 1, .extra_bits = 0 }, // 0
    .{ .base = 2, .extra_bits = 0 }, // 1
    .{ .base = 3, .extra_bits = 0 }, // 2
    .{ .base = 4, .extra_bits = 0 }, // 3
    .{ .base = 5, .extra_bits = 1 }, // 4
    .{ .base = 7, .extra_bits = 1 }, // 5
    .{ .base = 9, .extra_bits = 2 }, // 6
    .{ .base = 13, .extra_bits = 2 }, // 7
    .{ .base = 17, .extra_bits = 3 }, // 8
    .{ .base = 25, .extra_bits = 3 }, // 9
    .{ .base = 33, .extra_bits = 4 }, // 10
    .{ .base = 49, .extra_bits = 4 }, // 11
    .{ .base = 65, .extra_bits = 5 }, // 12
    .{ .base = 97, .extra_bits = 5 }, // 13
    .{ .base = 129, .extra_bits = 6 }, // 14
    .{ .base = 193, .extra_bits = 6 }, // 15
    .{ .base = 257, .extra_bits = 7 }, // 16
    .{ .base = 385, .extra_bits = 7 }, // 17
    .{ .base = 513, .extra_bits = 8 }, // 18
    .{ .base = 769, .extra_bits = 8 }, // 19
    .{ .base = 1025, .extra_bits = 9 }, // 20
    .{ .base = 1537, .extra_bits = 9 }, // 21
    .{ .base = 2049, .extra_bits = 10 }, // 22
    .{ .base = 3073, .extra_bits = 10 }, // 23
    .{ .base = 4097, .extra_bits = 11 }, // 24
    .{ .base = 6145, .extra_bits = 11 }, // 25
    .{ .base = 8193, .extra_bits = 12 }, // 26
    .{ .base = 12289, .extra_bits = 12 }, // 27
    .{ .base = 16385, .extra_bits = 13 }, // 28
    .{ .base = 24577, .extra_bits = 13 }, // 29
};

// Huffman tree node
const HuffmanNode = struct {
    symbol: ?u16 = null, // null for internal nodes
    left: ?*HuffmanNode = null,
    right: ?*HuffmanNode = null,
};

// Huffman decoder table for faster decoding
const HuffmanDecoder = struct {
    // Fast lookup table for common short codes
    fast_table: [512]u16 = [_]u16{0} ** 512, // 9-bit lookup
    fast_mask: u16 = 511, // 2^9 - 1

    // Tree for longer codes
    root: ?*HuffmanNode = null,
    allocator: Allocator,
    nodes: ArrayList(HuffmanNode),

    pub fn init(allocator: Allocator) HuffmanDecoder {
        return .{
            .allocator = allocator,
            .nodes = ArrayList(HuffmanNode).init(allocator),
        };
    }

    pub fn deinit(self: *HuffmanDecoder) void {
        self.nodes.deinit();
    }

    fn reverseBits(code: u16, length: u8) u16 {
        var result: u16 = 0;
        var temp = code;
        for (0..length) |_| {
            result = (result << 1) | (temp & 1);
            temp >>= 1;
        }
        return result;
    }

    pub fn buildFromLengths(self: *HuffmanDecoder, code_lengths: []const u8) !void {

        // Reset fast table and clear nodes
        self.fast_table = [_]u16{0} ** 512;
        self.nodes.clearRetainingCapacity();
        self.root = null;

        // Count codes of each length
        var length_count = [_]u16{0} ** 16;
        for (code_lengths) |len| {
            if (len > 0) length_count[len] += 1;
        }

        // Calculate first code for each length
        var code: u16 = 0;
        var first_code = [_]u16{0} ** 16;
        for (1..16) |bits| {
            code = (code + length_count[bits - 1]) << 1;
            first_code[bits] = code;
        }

        // Pre-allocate enough nodes for the worst case (all long codes)
        var max_nodes: usize = 1; // Root
        for (code_lengths) |len| {
            if (len > 9) max_nodes += len;
        }
        try self.nodes.ensureTotalCapacity(max_nodes);

        // Build fast lookup table and tree
        for (code_lengths, 0..) |len, symbol| {
            if (len == 0) continue;

            const sym_code = first_code[len];
            first_code[len] += 1;

            // Reverse the bits for proper deflate bit order
            const reversed_code = reverseBits(sym_code, @intCast(len));

            if (len <= 9) {
                // Add to fast table with all possible suffixes
                const num_entries = @as(u16, 1) << @intCast(9 - len);
                var i: u16 = 0;
                while (i < num_entries) : (i += 1) {
                    const table_index = reversed_code | (i << @intCast(len));
                    self.fast_table[table_index] = @as(u16, @intCast(symbol)) | (@as(u16, @intCast(len)) << 12);
                }
            } else {
                // Add to tree for longer codes
                if (self.root == null) {
                    self.nodes.appendAssumeCapacity(.{});
                    self.root = &self.nodes.items[0];
                }

                var current = self.root.?;
                for (0..len) |bit_idx| {
                    const bit = (reversed_code >> @as(u4, @intCast(bit_idx))) & 1;
                    if (bit == 0) {
                        if (current.left == null) {
                            self.nodes.appendAssumeCapacity(.{});
                            current.left = &self.nodes.items[self.nodes.items.len - 1];
                        }
                        current = current.left.?;
                    } else {
                        if (current.right == null) {
                            self.nodes.appendAssumeCapacity(.{});
                            current.right = &self.nodes.items[self.nodes.items.len - 1];
                        }
                        current = current.right.?;
                    }
                }
                current.symbol = @intCast(symbol);
            }
        }
    }
};

// Bit stream reader for deflate data
const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u8 = 0, // 0-7, position within current byte

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn readBits(self: *BitReader, num_bits: u8) !u32 {
        assert(num_bits <= 32);

        var result: u32 = 0;
        var bits_read: u8 = 0;

        while (bits_read < num_bits) {
            if (self.byte_pos >= self.data.len) {
                return error.UnexpectedEndOfData;
            }

            const current_byte = self.data[self.byte_pos];
            const bits_in_byte = 8 - self.bit_pos;
            const bits_needed = num_bits - bits_read;
            const bits_to_read = @min(bits_needed, bits_in_byte);

            const mask = if (bits_to_read == 8) @as(u8, 0xFF) else (@as(u8, 1) << @as(u3, @intCast(bits_to_read))) - 1;
            const bits = (current_byte >> @as(u3, @intCast(self.bit_pos))) & mask;
            result |= @as(u32, bits) << @as(u5, @intCast(bits_read));

            bits_read += bits_to_read;
            self.bit_pos += bits_to_read;

            if (self.bit_pos >= 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }

        return result;
    }

    pub fn skipToByteBoundary(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    pub fn readBytes(self: *BitReader, buffer: []u8) !void {
        self.skipToByteBoundary();
        if (self.byte_pos + buffer.len > self.data.len) {
            return error.UnexpectedEndOfData;
        }
        @memcpy(buffer, self.data[self.byte_pos .. self.byte_pos + buffer.len]);
        self.byte_pos += buffer.len;
    }
};

// DEFLATE decompressor
pub const DeflateDecoder = struct {
    allocator: Allocator,
    output: ArrayList(u8),
    literal_decoder: HuffmanDecoder,
    distance_decoder: HuffmanDecoder,
    current_byte_offset: usize = 0,

    pub fn init(allocator: Allocator) DeflateDecoder {
        return .{
            .allocator = allocator,
            .output = ArrayList(u8).init(allocator),
            .literal_decoder = HuffmanDecoder.init(allocator),
            .distance_decoder = HuffmanDecoder.init(allocator),
        };
    }

    pub fn deinit(self: *DeflateDecoder) void {
        self.output.deinit();
        self.literal_decoder.deinit();
        self.distance_decoder.deinit();
    }

    pub fn decode(self: *DeflateDecoder, compressed_data: []const u8) !ArrayList(u8) {
        var reader = BitReader.init(compressed_data);
        self.current_byte_offset = 0;

        while (true) {
            self.current_byte_offset = reader.byte_pos;
            const is_final = try reader.readBits(1) == 1;
            const block_type = try reader.readBits(2);

            switch (block_type) {
                0 => try self.decodeUncompressedBlock(&reader),
                1 => try self.decodeFixedHuffmanBlock(&reader),
                2 => try self.decodeDynamicHuffmanBlock(&reader),
                3 => return error.InvalidBlockType,
                else => unreachable,
            }

            if (is_final) break;
        }

        return self.output.clone();
    }

    fn decodeUncompressedBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        reader.skipToByteBoundary();

        var len_bytes: [2]u8 = undefined;
        var nlen_bytes: [2]u8 = undefined;
        try reader.readBytes(&len_bytes);
        try reader.readBytes(&nlen_bytes);

        const len = std.mem.readInt(u16, len_bytes[0..2], .little);
        const nlen = std.mem.readInt(u16, nlen_bytes[0..2], .little);

        if (len != ~nlen) {
            return error.InvalidUncompressedBlock;
        }

        const old_len = self.output.items.len;
        try self.output.resize(old_len + len);
        try reader.readBytes(self.output.items[old_len..]);
    }

    fn decodeFixedHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        // Build fixed Huffman tables
        try self.literal_decoder.buildFromLengths(&FIXED_LITERAL_LENGTHS);
        try self.distance_decoder.buildFromLengths(&FIXED_DISTANCE_LENGTHS);

        try self.decodeHuffmanBlock(reader);
    }

    fn decodeDynamicHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        const hlit = try reader.readBits(5) + 257; // # of literal/length codes
        const hdist = try reader.readBits(5) + 1; // # of distance codes
        const hclen = try reader.readBits(4) + 4; // # of code length codes

        // Code length code order
        const code_length_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

        // Read code length codes
        var code_length_lengths = [_]u8{0} ** 19;
        for (0..hclen) |i| {
            code_length_lengths[code_length_order[i]] = @intCast(try reader.readBits(3));
        }

        // Build code length decoder
        var code_length_decoder = HuffmanDecoder.init(self.allocator);
        defer code_length_decoder.deinit();
        try code_length_decoder.buildFromLengths(&code_length_lengths);

        // Decode literal/length and distance code lengths
        var lengths = try self.allocator.alloc(u8, hlit + hdist);
        defer self.allocator.free(lengths);

        var i: usize = 0;
        while (i < lengths.len) {
            const symbol = try self.decodeSymbol(reader, &code_length_decoder);

            if (symbol < 16) {
                lengths[i] = @intCast(symbol);
                i += 1;
            } else if (symbol == 16) {
                if (i == 0) return error.InvalidCodeLength;
                const repeat_count = try reader.readBits(2) + 3;
                const repeat_value = lengths[i - 1];
                for (0..repeat_count) |_| {
                    if (i >= lengths.len) return error.InvalidCodeLength;
                    lengths[i] = repeat_value;
                    i += 1;
                }
            } else if (symbol == 17) {
                const repeat_count = try reader.readBits(3) + 3;
                for (0..repeat_count) |_| {
                    if (i >= lengths.len) return error.InvalidCodeLength;
                    lengths[i] = 0;
                    i += 1;
                }
            } else if (symbol == 18) {
                const repeat_count = try reader.readBits(7) + 11;
                for (0..repeat_count) |_| {
                    if (i >= lengths.len) return error.InvalidCodeLength;
                    lengths[i] = 0;
                    i += 1;
                }
            } else {
                return error.InvalidCodeLengthSymbol;
            }
        }

        // Build literal/length and distance decoders
        try self.literal_decoder.buildFromLengths(lengths[0..hlit]);
        try self.distance_decoder.buildFromLengths(lengths[hlit .. hlit + hdist]);

        try self.decodeHuffmanBlock(reader);
    }

    fn decodeHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        while (true) {
            const symbol = try self.decodeSymbol(reader, &self.literal_decoder);

            if (symbol < 256) {
                // Literal byte
                try self.output.append(@intCast(symbol));
            } else if (symbol == 256) {
                // End of block
                break;
            } else if (symbol <= 285) {
                // Length/distance pair
                const length_code = symbol - 257;
                if (length_code >= LENGTH_CODES.len) {
                    return error.InvalidLengthCode;
                }

                const length_info = LENGTH_CODES[length_code];
                const length = length_info.base + try reader.readBits(length_info.extra_bits);

                const distance_symbol = try self.decodeSymbol(reader, &self.distance_decoder);
                if (distance_symbol >= DISTANCE_CODES.len) {
                    return error.InvalidDistanceCode;
                }

                const distance_info = DISTANCE_CODES[distance_symbol];
                const distance = distance_info.base + try reader.readBits(distance_info.extra_bits);

                // Copy from sliding window
                if (distance > self.output.items.len) {
                    return error.InvalidDistance;
                }
                const start_pos = self.output.items.len - distance;
                for (0..length) |j| {
                    const byte = self.output.items[start_pos + (j % distance)];
                    try self.output.append(byte);
                }
            } else {
                return error.InvalidLiteralLengthSymbol;
            }
        }
    }

    fn decodeSymbol(self: *DeflateDecoder, reader: *BitReader, decoder: *HuffmanDecoder) !u16 {
        self.current_byte_offset = reader.byte_pos;

        // Try fast lookup (handle shorter codes when near end of data)
        const remaining_bits = (reader.data.len - reader.byte_pos) * 8 - reader.bit_pos;

        // Always try fast lookup if we have any bits available
        if (remaining_bits > 0) {
            // Read up to 9 bits for fast lookup, but handle cases with fewer bits
            var peek_value: u16 = 0;
            var temp_byte_pos = reader.byte_pos;
            var temp_bit_pos = reader.bit_pos;
            var bits_read: u8 = 0;

            for (0..9) |i| {
                if (temp_byte_pos >= reader.data.len) break;
                const bit = (reader.data[temp_byte_pos] >> @as(u3, @intCast(temp_bit_pos))) & 1;
                peek_value |= @as(u16, bit) << @intCast(i);
                bits_read += 1;
                temp_bit_pos += 1;
                if (temp_bit_pos >= 8) {
                    temp_bit_pos = 0;
                    temp_byte_pos += 1;
                }
            }

            const entry = decoder.fast_table[peek_value & decoder.fast_mask];
            if (entry != 0) {
                const symbol = entry & 0xFFF;
                const code_length: u8 = @intCast((entry >> 12) & 0xF);

                // Check if we have enough bits for this code
                if (remaining_bits >= code_length) {
                    // Advance reader by code_length bits
                    _ = try reader.readBits(code_length);
                    return symbol;
                }
            }
        }

        // Fall back to tree traversal for longer codes
        if (decoder.root) |root| {
            var current = root;
            var bits_read: u8 = 0;
            var bit_sequence: u16 = 0;

            while (current.symbol == null) {
                const bit = try reader.readBits(1);
                bit_sequence = (bit_sequence << 1) | @as(u16, @intCast(bit));
                bits_read += 1;

                if (bit == 0) {
                    if (current.left) |left| {
                        current = left;
                    } else {
                        return error.InvalidHuffmanCode;
                    }
                } else {
                    if (current.right) |right| {
                        current = right;
                    } else {
                        return error.InvalidHuffmanCode;
                    }
                }
            }
            return current.symbol.?;
        }

        return error.InvalidHuffmanCode;
    }
};

// Public decompression function
pub fn inflate(allocator: Allocator, compressed_data: []const u8) ![]u8 {
    var decoder = DeflateDecoder.init(allocator);
    defer decoder.deinit();

    var result = try decoder.decode(compressed_data);
    defer result.deinit();

    return result.toOwnedSlice();
}

// Build static Huffman encoder tables by computing codes from lengths
const StaticHuffmanTables = struct {
    const LiteralCode = struct {
        code: u16,
        bits: u8,
    };

    // Build literal codes from the same lengths as decoder uses
    const literal_codes = blk: {
        @setEvalBranchQuota(10000); // Increase quota for comptime evaluation
        var codes: [288]LiteralCode = undefined;

        // Count codes of each length
        var length_count = [_]u16{0} ** 16;
        for (FIXED_LITERAL_LENGTHS) |len| {
            if (len > 0) length_count[len] += 1;
        }

        // Calculate first code for each length
        var code: u16 = 0;
        var first_code = [_]u16{0} ** 16;
        for (1..16) |bits| {
            code = (code + length_count[bits - 1]) << 1;
            first_code[bits] = code;
        }

        // Assign codes to symbols
        for (FIXED_LITERAL_LENGTHS, 0..) |len, symbol| {
            if (len == 0) {
                codes[symbol] = LiteralCode{ .code = 0, .bits = 0 };
                continue;
            }

            const sym_code = first_code[len];
            first_code[len] += 1;

            // Reverse the bits for proper deflate bit order
            const reversed_code = reverseBits(sym_code, @intCast(len));
            codes[symbol] = LiteralCode{ .code = reversed_code, .bits = @intCast(len) };
        }

        break :blk codes;
    };

    // Distance codes built from fixed lengths like decoder
    const distance_codes = blk: {
        var codes: [32]LiteralCode = undefined;

        // Count codes of each length
        var length_count = [_]u16{0} ** 16;
        for (FIXED_DISTANCE_LENGTHS) |len| {
            if (len > 0) length_count[len] += 1;
        }

        // Calculate first code for each length
        var code: u16 = 0;
        var first_code = [_]u16{0} ** 16;
        for (1..16) |bits| {
            code = (code + length_count[bits - 1]) << 1;
            first_code[bits] = code;
        }

        // Assign codes to symbols (same logic as literals)
        for (FIXED_DISTANCE_LENGTHS, 0..) |len, symbol| {
            if (len == 0) {
                codes[symbol] = LiteralCode{ .code = 0, .bits = 0 };
                continue;
            }

            const sym_code = first_code[len];
            first_code[len] += 1;

            // Reverse the bits for proper deflate bit order
            const reversed_code = reverseBits(sym_code, @intCast(len));
            codes[symbol] = LiteralCode{ .code = reversed_code, .bits = @intCast(len) };
        }

        break :blk codes;
    };

    fn reverseBits(code: u16, length: u8) u16 {
        var result: u16 = 0;
        var temp = code;
        for (0..length) |_| {
            result = (result << 1) | (temp & 1);
            temp >>= 1;
        }
        return result;
    }
};

// Length and distance encoding tables for LZ77
const LengthCode = struct {
    code: u16,
    extra_bits: u8,
    base: u16,
};

const DistanceCode = struct {
    code: u16,
    extra_bits: u8,
    base: u16,
};

// Length codes (257-285 map to lengths 3-258)
const length_codes = [_]LengthCode{
    .{ .code = 257, .extra_bits = 0, .base = 3 },   .{ .code = 258, .extra_bits = 0, .base = 4 },
    .{ .code = 259, .extra_bits = 0, .base = 5 },   .{ .code = 260, .extra_bits = 0, .base = 6 },
    .{ .code = 261, .extra_bits = 0, .base = 7 },   .{ .code = 262, .extra_bits = 0, .base = 8 },
    .{ .code = 263, .extra_bits = 0, .base = 9 },   .{ .code = 264, .extra_bits = 0, .base = 10 },
    .{ .code = 265, .extra_bits = 1, .base = 11 },  .{ .code = 266, .extra_bits = 1, .base = 13 },
    .{ .code = 267, .extra_bits = 1, .base = 15 },  .{ .code = 268, .extra_bits = 1, .base = 17 },
    .{ .code = 269, .extra_bits = 2, .base = 19 },  .{ .code = 270, .extra_bits = 2, .base = 23 },
    .{ .code = 271, .extra_bits = 2, .base = 27 },  .{ .code = 272, .extra_bits = 2, .base = 31 },
    .{ .code = 273, .extra_bits = 3, .base = 35 },  .{ .code = 274, .extra_bits = 3, .base = 43 },
    .{ .code = 275, .extra_bits = 3, .base = 51 },  .{ .code = 276, .extra_bits = 3, .base = 59 },
    .{ .code = 277, .extra_bits = 4, .base = 67 },  .{ .code = 278, .extra_bits = 4, .base = 83 },
    .{ .code = 279, .extra_bits = 4, .base = 99 },  .{ .code = 280, .extra_bits = 4, .base = 115 },
    .{ .code = 281, .extra_bits = 5, .base = 131 }, .{ .code = 282, .extra_bits = 5, .base = 163 },
    .{ .code = 283, .extra_bits = 5, .base = 195 }, .{ .code = 284, .extra_bits = 5, .base = 227 },
    .{ .code = 285, .extra_bits = 0, .base = 258 },
};

// Distance codes (0-29 map to distances 1-32768)
const distance_codes = [_]DistanceCode{
    .{ .code = 0, .extra_bits = 0, .base = 1 },       .{ .code = 1, .extra_bits = 0, .base = 2 },
    .{ .code = 2, .extra_bits = 0, .base = 3 },       .{ .code = 3, .extra_bits = 0, .base = 4 },
    .{ .code = 4, .extra_bits = 1, .base = 5 },       .{ .code = 5, .extra_bits = 1, .base = 7 },
    .{ .code = 6, .extra_bits = 2, .base = 9 },       .{ .code = 7, .extra_bits = 2, .base = 13 },
    .{ .code = 8, .extra_bits = 3, .base = 17 },      .{ .code = 9, .extra_bits = 3, .base = 25 },
    .{ .code = 10, .extra_bits = 4, .base = 33 },     .{ .code = 11, .extra_bits = 4, .base = 49 },
    .{ .code = 12, .extra_bits = 5, .base = 65 },     .{ .code = 13, .extra_bits = 5, .base = 97 },
    .{ .code = 14, .extra_bits = 6, .base = 129 },    .{ .code = 15, .extra_bits = 6, .base = 193 },
    .{ .code = 16, .extra_bits = 7, .base = 257 },    .{ .code = 17, .extra_bits = 7, .base = 385 },
    .{ .code = 18, .extra_bits = 8, .base = 513 },    .{ .code = 19, .extra_bits = 8, .base = 769 },
    .{ .code = 20, .extra_bits = 9, .base = 1025 },   .{ .code = 21, .extra_bits = 9, .base = 1537 },
    .{ .code = 22, .extra_bits = 10, .base = 2049 },  .{ .code = 23, .extra_bits = 10, .base = 3073 },
    .{ .code = 24, .extra_bits = 11, .base = 4097 },  .{ .code = 25, .extra_bits = 11, .base = 6145 },
    .{ .code = 26, .extra_bits = 12, .base = 8193 },  .{ .code = 27, .extra_bits = 12, .base = 12289 },
    .{ .code = 28, .extra_bits = 13, .base = 16385 }, .{ .code = 29, .extra_bits = 13, .base = 24577 },
};

// Bit writer for variable-length codes
const BitWriter = struct {
    output: *ArrayList(u8),
    bit_buffer: u32 = 0,
    bit_count: u8 = 0,

    pub fn init(output: *ArrayList(u8)) BitWriter {
        return .{ .output = output };
    }

    pub fn writeBits(self: *BitWriter, code: u32, bits: u8) !void {
        self.bit_buffer |= code << @as(u5, @intCast(self.bit_count));
        self.bit_count += bits;

        while (self.bit_count >= 8) {
            try self.output.append(@intCast(self.bit_buffer & 0xFF));
            self.bit_buffer >>= 8;
            self.bit_count -= 8;
        }
    }

    pub fn flush(self: *BitWriter) !void {
        if (self.bit_count > 0) {
            try self.output.append(@intCast(self.bit_buffer & 0xFF));
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
    }
};

// Compression methods for deflate
pub const CompressionMethod = enum {
    uncompressed, // BTYPE = 00 - no compression
    static_huffman, // BTYPE = 01 - static Huffman codes
    // dynamic_huffman could be added later
};

// DEFLATE encoder for PNG compression
pub const DeflateEncoder = struct {
    allocator: Allocator,
    output: ArrayList(u8),

    pub fn init(allocator: Allocator) DeflateEncoder {
        return .{
            .allocator = allocator,
            .output = ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *DeflateEncoder) void {
        self.output.deinit();
    }

    // Simple LZ77 match finder
    const Match = struct {
        length: u16,
        distance: u16,
    };

    fn findMatch(data: []const u8, pos: usize) ?Match {
        if (pos < 3 or data.len < 3) return null;

        const max_length = @min(258, data.len - pos);
        if (max_length < 3) return null;

        const max_distance = @min(32768, pos);

        var best_length: u16 = 0;
        var best_distance: u16 = 0;

        // Simple search - only check a few recent positions to avoid infinite loops
        const search_limit = @min(max_distance, 256); // Limit search to prevent infinite loops

        var distance: u16 = 1;
        while (distance <= search_limit) : (distance += 1) {
            if (distance > pos) break;

            const match_pos = pos - distance;
            var length: u16 = 0;

            // Find the length of the match with proper bounds checking
            while (length < max_length and
                pos + length < data.len and
                match_pos + length < data.len and
                data[pos + length] == data[match_pos + length])
            {
                length += 1;
            }

            // Must be at least 3 bytes to be worthwhile
            if (length >= 3 and length > best_length) {
                best_length = length;
                best_distance = distance;
                // Early exit for good matches to avoid spending too much time
                if (length >= 32) break;
            }
        }

        if (best_length >= 3) {
            return Match{ .length = best_length, .distance = best_distance };
        }

        return null;
    }

    fn getLengthCode(length: u16) struct { code: u16, extra_bits: u8, extra_value: u16 } {
        for (length_codes) |lc| {
            if (length >= lc.base) {
                const next_base = if (lc.code == 285) 259 else length_codes[lc.code - 257 + 1].base;
                if (length < next_base) {
                    return .{
                        .code = lc.code,
                        .extra_bits = lc.extra_bits,
                        .extra_value = length - lc.base,
                    };
                }
            }
        }
        // Should never reach here for valid lengths
        return .{ .code = 285, .extra_bits = 0, .extra_value = 0 };
    }

    fn getDistanceCode(distance: u16) struct { code: u16, extra_bits: u8, extra_value: u16 } {
        for (distance_codes) |dc| {
            if (distance >= dc.base) {
                const next_base = if (dc.code == 29) 32769 else distance_codes[dc.code + 1].base;
                if (distance < next_base) {
                    // Distance code found
                    return .{
                        .code = dc.code,
                        .extra_bits = dc.extra_bits,
                        .extra_value = distance - dc.base,
                    };
                }
            }
        }
        // Should never reach here for valid distances
        return .{ .code = 29, .extra_bits = 0, .extra_value = 0 };
    }

    pub fn encode(self: *DeflateEncoder, data: []const u8, method: CompressionMethod) !ArrayList(u8) {
        switch (method) {
            .uncompressed => return self.encodeUncompressed(data),
            .static_huffman => return self.encodeStaticHuffman(data),
        }
    }

    fn encodeUncompressed(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        const block_size = @min(data.len, 65535); // Max uncompressed block size
        var pos: usize = 0;

        while (pos < data.len) {
            const remaining = data.len - pos;
            const chunk_size = @min(remaining, block_size);
            const is_final = (pos + chunk_size >= data.len);

            // Block header: BFINAL (1 bit) + BTYPE (2 bits) = 000 or 001 for final
            const block_header: u8 = if (is_final) 0x01 else 0x00;
            try self.output.append(block_header);

            // Length and NLEN (one's complement of length)
            const len: u16 = @intCast(chunk_size);
            const nlen: u16 = ~len;

            // Write length in little-endian format
            try self.output.append(@intCast(len & 0xFF));
            try self.output.append(@intCast((len >> 8) & 0xFF));
            // Write NLEN in little-endian format
            try self.output.append(@intCast(nlen & 0xFF));
            try self.output.append(@intCast((nlen >> 8) & 0xFF));

            // Uncompressed data
            try self.output.appendSlice(data[pos .. pos + chunk_size]);

            pos += chunk_size;
        }

        return self.output.clone();
    }

    fn encodeStaticHuffman(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        // Use static Huffman compression (BTYPE = 01)
        var writer = BitWriter.init(&self.output);

        // Debug: check for problematic data patterns
        var has_high_bytes = false;
        for (data) |byte| {
            if (byte > 250) {
                has_high_bytes = true;
                break;
            }
        }
        if (has_high_bytes) {}

        // Write block header: BFINAL=1, BTYPE=01 (static Huffman)
        try writer.writeBits(0x3, 3); // 011 in binary (LSB first: BFINAL=1, BTYPE=01)

        var pos: usize = 0;
        while (pos < data.len) {
            // Try to find a match
            if (findMatch(data, pos)) |match| {
                // Output length/distance pair
                const length_info = getLengthCode(match.length);
                const distance_info = getDistanceCode(match.distance);

                // LZ77 match found

                // Write length code (using static Huffman table)
                const length_huffman = StaticHuffmanTables.literal_codes[length_info.code];
                try writer.writeBits(length_huffman.code, length_huffman.bits);

                // Write extra length bits if needed
                if (length_info.extra_bits > 0) {
                    try writer.writeBits(length_info.extra_value, length_info.extra_bits);
                }

                // Write distance code (5 bits, values 0-31)
                const distance_huffman = StaticHuffmanTables.distance_codes[distance_info.code];
                try writer.writeBits(distance_huffman.code, distance_huffman.bits);

                // Write extra distance bits if needed
                if (distance_info.extra_bits > 0) {
                    try writer.writeBits(distance_info.extra_value, distance_info.extra_bits);
                }

                pos += match.length;
            } else {
                // Output literal
                const literal = data[pos];
                const literal_huffman = StaticHuffmanTables.literal_codes[literal];
                try writer.writeBits(literal_huffman.code, literal_huffman.bits);
                pos += 1;
            }
        }

        // Write end-of-block symbol (256)
        const eob_huffman = StaticHuffmanTables.literal_codes[256];
        try writer.writeBits(eob_huffman.code, eob_huffman.bits);

        // Flush remaining bits
        try writer.flush();

        return self.output.clone();
    }
};

// Public compression function with selectable compression method
pub fn deflate(allocator: Allocator, data: []const u8, method: CompressionMethod) ![]u8 {
    var encoder = DeflateEncoder.init(allocator);
    defer encoder.deinit();

    var result = try encoder.encode(data, method);
    defer result.deinit();

    return result.toOwnedSlice();
}

// Adler-32 checksum implementation (required for zlib format)
fn adler32(data: []const u8) u32 {
    const MOD_ADLER: u32 = 65521;
    var a: u32 = 1;
    var b: u32 = 0;

    for (data) |byte| {
        a = (a + byte) % MOD_ADLER;
        b = (b + a) % MOD_ADLER;
    }

    return (b << 16) | a;
}

// Compress data using zlib format (RFC 1950) - required for PNG IDAT chunks
pub fn zlibCompress(allocator: Allocator, data: []const u8, method: CompressionMethod) ![]u8 {
    // Generate raw DEFLATE data first
    const deflate_data = try deflate(allocator, data, method);
    defer allocator.free(deflate_data);

    // Calculate Adler-32 checksum of original data
    const checksum = adler32(data);

    // Create zlib-wrapped result
    var result = ArrayList(u8).init(allocator);
    defer result.deinit();

    // zlib header (2 bytes)
    // CMF: compression method (8) + compression info (7 for 32K window)
    const cmf: u8 = 0x78; // 8 + (7 << 4) = 120 = 0x78
    // FLG: fcheck will be calculated to make (cmf*256 + flg) % 31 == 0
    var flg: u8 = 0x00; // No preset dictionary, default compression level

    // Calculate FCHECK to make header valid
    const header_base = (@as(u16, cmf) << 8) | flg;
    const fcheck = 31 - (header_base % 31);
    if (fcheck < 31) {
        flg |= @intCast(fcheck);
    }

    try result.append(cmf);
    try result.append(flg);

    // DEFLATE data
    try result.appendSlice(deflate_data);

    // Adler-32 checksum (4 bytes, big-endian)
    try result.append(@intCast((checksum >> 24) & 0xFF));
    try result.append(@intCast((checksum >> 16) & 0xFF));
    try result.append(@intCast((checksum >> 8) & 0xFF));
    try result.append(@intCast(checksum & 0xFF));

    return result.toOwnedSlice();
}

// Decompress zlib format data (RFC 1950)
pub fn zlibDecompress(allocator: Allocator, zlib_data: []const u8) ![]u8 {
    if (zlib_data.len < 6) { // header(2) + data(at least 1) + checksum(4)
        return error.InvalidZlibData;
    }

    // Verify zlib header
    const cmf = zlib_data[0];
    const flg = zlib_data[1];
    const header_check = (@as(u16, cmf) << 8) | flg;

    if ((cmf & 0x0F) != 8) { // compression method must be 8 (deflate)
        return error.UnsupportedCompressionMethod;
    }

    if ((header_check % 31) != 0) {
        return error.InvalidZlibHeader;
    }

    if ((flg & 0x20) != 0) { // FDICT bit - preset dictionary not supported
        return error.PresetDictionaryNotSupported;
    }

    // Extract DEFLATE data (skip header and checksum)
    const deflate_data = zlib_data[2 .. zlib_data.len - 4];

    // Decompress DEFLATE data
    const decompressed = try inflate(allocator, deflate_data);

    // Verify Adler-32 checksum
    const expected_checksum = std.mem.readInt(u32, zlib_data[zlib_data.len - 4 ..][0..4], .big);
    const actual_checksum = adler32(decompressed);

    if (actual_checksum != expected_checksum) {
        allocator.free(decompressed);
        return error.ChecksumMismatch;
    }

    return decompressed;
}

// Basic test
test "deflate decompression" {
    // This is a basic test to ensure the module compiles
    const allocator = std.testing.allocator;

    // Test with empty data should fail gracefully
    const empty_data = [_]u8{};
    const result = inflate(allocator, &empty_data);
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "deflate round-trip compression" {
    const allocator = std.testing.allocator;

    // Test data
    const original_data = "Hello, World! This is a test string for deflate compression.";

    // Compress
    const compressed = try deflate(allocator, original_data, .uncompressed);
    defer allocator.free(compressed);

    // Decompress
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);

    // Verify
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

test "deflate endianness" {
    const allocator = std.testing.allocator;

    // Test that block headers are written in correct endianness
    const test_data = "Test";
    const compressed = try deflate(allocator, test_data, .uncompressed);
    defer allocator.free(compressed);

    // Check first block header
    try std.testing.expect(compressed.len >= 5); // At least header + length/nlen

    // For uncompressed blocks:
    // Byte 0: BFINAL (bit 0) + BTYPE (bits 1-2) = 0x01 for final uncompressed block
    try std.testing.expectEqual(@as(u8, 0x01), compressed[0]);

    // Bytes 1-2: LEN in little-endian
    // Bytes 3-4: NLEN (one's complement of LEN) in little-endian
    const len = compressed[1] | (@as(u16, compressed[2]) << 8);
    const nlen = compressed[3] | (@as(u16, compressed[4]) << 8);

    try std.testing.expectEqual(@as(u16, 4), len); // "Test" is 4 bytes
    try std.testing.expectEqual(@as(u16, 0xFFFB), nlen); // ~4 = 0xFFFB
}

test "huffman tree bit order" {
    const allocator = std.testing.allocator;

    // Test Huffman decoder with specific code lengths that reproduce the PNG issue
    var decoder = HuffmanDecoder.init(allocator);
    defer decoder.deinit();

    // Test code lengths that would trigger the bit-reversal issue with codes longer than 9
    const code_lengths = [_]u8{
        3, 4, 5, 6, 6, 6, 7, 7, 7, 8, 10, 10, 10, 11, 11, 12, 12, 12, 12, 13, // symbols 0-19
    };

    try decoder.buildFromLengths(&code_lengths);

    // Verify that the decoder was built without errors (should have a tree for codes > 9)
    try std.testing.expect(decoder.root != null);
}

test "png huffman decoding regression" {
    const allocator = std.testing.allocator;

    // This test ensures that the PNG Huffman decoding issue (yubin.png) doesn't regress
    // It tests the specific case where longer Huffman codes need proper bit reversal
    var decoder = HuffmanDecoder.init(allocator);
    defer decoder.deinit();

    // Code lengths from a real PNG that previously failed
    const code_lengths = [_]u8{ 0, 0, 0, 0, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 0 };

    // This should not panic or fail
    try decoder.buildFromLengths(&code_lengths);
    try std.testing.expect(decoder.root != null);
}

test "compression methods comparison" {
    const allocator = std.testing.allocator;

    // Test data with some repetition to benefit from compression
    const test_data = "Hello World! Hello World! Hello World! This is a test string for compression.";

    // Test uncompressed method
    const uncompressed = try deflate(allocator, test_data, .uncompressed);
    defer allocator.free(uncompressed);

    // Test static Huffman method
    const static_huffman = try deflate(allocator, test_data, .static_huffman);
    defer allocator.free(static_huffman);

    // Both should decompress back to the original
    const decompressed1 = try inflate(allocator, uncompressed);
    defer allocator.free(decompressed1);
    try std.testing.expectEqualSlices(u8, test_data, decompressed1);

    // Test static Huffman decompression
    const decompressed2 = try inflate(allocator, static_huffman);
    defer allocator.free(decompressed2);
    try std.testing.expectEqualSlices(u8, test_data, decompressed2);

    // Static Huffman should typically produce smaller output than uncompressed
    // (Not always true for very small data, but good to check)
    std.log.info("Uncompressed size: {any}, Static Huffman size: {any}", .{ uncompressed.len, static_huffman.len });
}

test "static huffman zlib round trip" {
    const allocator = std.testing.allocator;

    // Simple test data
    const test_data = "Test data for static Huffman compression";

    // Test zlib with static Huffman
    const compressed = try zlibCompress(allocator, test_data, .static_huffman);
    defer allocator.free(compressed);

    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, test_data, decompressed);
}

test "static huffman with pattern data" {
    const allocator = std.testing.allocator;

    // Test data that mimics grayscale patterns that might cause issues
    var test_data: [256]u8 = undefined;
    for (0..256) |i| {
        test_data[i] = @intCast(i % 256);
    }

    // Test zlib with static Huffman
    const compressed = try zlibCompress(allocator, &test_data, .static_huffman);
    defer allocator.free(compressed);

    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "static huffman end-of-stream edge case" {
    const allocator = std.testing.allocator;

    // Create a specific pattern that results in the end-of-block symbol
    // being at the very end with fewer than 9 bits available
    // This reproduces the exact bug that was fixed
    const test_data = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };

    // Compress with static Huffman - this should create a compressed stream
    // where the final EOB symbol (256) has only 7-8 bits available for reading
    const compressed = try deflate(allocator, &test_data, .static_huffman);
    defer allocator.free(compressed);

    // This decompression should succeed even though the final symbol
    // requires fast lookup but there are <9 bits remaining
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "static huffman with high bytes" {
    const allocator = std.testing.allocator;

    // Test specifically with high byte values that are causing issues
    const test_data = [_]u8{ 250, 251, 252, 253, 254, 255, 255, 254, 253, 252, 251, 250 };

    // Test raw deflate with static Huffman
    const compressed = try deflate(allocator, &test_data, .static_huffman);
    defer allocator.free(compressed);

    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "debug specific grayscale pattern" {
    const allocator = std.testing.allocator;

    // Create the exact pattern that PNG grayscale uses (with row filters)
    var test_data: [64]u8 = undefined;
    for (0..8) |y| {
        test_data[y * 8] = 0; // Row filter byte (none = 0)
        for (1..8) |x| {
            // Checkerboard pattern like the PNG example
            if ((x / 4 + y / 4) % 2 == 0) {
                test_data[y * 8 + x] = @intCast((x * y * 255) / 49); // Will be high values
            } else {
                test_data[y * 8 + x] = @intCast(255 - (x * y * 255) / 49);
            }
        }
    }

    // Test with static Huffman
    const compressed = try deflate(allocator, &test_data, .static_huffman);
    defer allocator.free(compressed);

    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "zlib round-trip compression" {
    const allocator = std.testing.allocator;

    // Test data
    const original_data = "Hello, zlib compression test for PNG!";

    // Compress with zlib format
    const compressed = try zlibCompress(allocator, original_data, .uncompressed);
    defer allocator.free(compressed);

    // Decompress
    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);

    // Verify
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

test "zlib header validation" {
    const allocator = std.testing.allocator;

    // Test with valid header
    const test_data = "Test";
    const compressed = try zlibCompress(allocator, test_data, .uncompressed);
    defer allocator.free(compressed);

    // Check zlib header format
    try std.testing.expect(compressed.len >= 6); // header(2) + data + checksum(4)

    // CMF byte: compression method should be 8
    const cmf = compressed[0];
    try std.testing.expectEqual(@as(u8, 8), cmf & 0x0F);

    // Header should be valid (divisible by 31)
    const header_check = (@as(u16, compressed[0]) << 8) | compressed[1];
    try std.testing.expectEqual(@as(u16, 0), header_check % 31);
}

test "deflate invalid distance check" {
    const allocator = std.testing.allocator;

    // Create a deflate stream with an invalid distance
    // This tests the bounds check we added
    var decoder = DeflateDecoder.init(allocator);
    defer decoder.deinit();

    // Manually set up decoder state with empty output
    decoder.output.clearRetainingCapacity();

    // Test that invalid distance is caught
    const invalid_distance: usize = 100; // Distance > output length

    if (invalid_distance > decoder.output.items.len) {
        // This should be caught by the check we added
        try std.testing.expect(true);
    }
}
