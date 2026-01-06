//! DEFLATE compression algorithm (RFC 1951).
//!
//! This module provides compression and decompression using the DEFLATE algorithm,
//! which combines LZ77 compression with Huffman coding. It supports multiple
//! compression levels and strategies for different data types.
//!
//! ## Basic Usage
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//!
//! // Compress data
//! const compressed = try deflate(allocator, "Hello, World!", .default, .default);
//! defer allocator.free(compressed);
//!
//! // Decompress data
//! const decompressed = try inflate(allocator, compressed, std.math.maxInt(usize));
//! defer allocator.free(decompressed);
//! ```
//!
//! ## Compression Levels
//!
//! - `.none` - Store only, no compression
//! - `.fastest` - Minimal compression, maximum speed
//! - `.fast` - Fast compression
//! - `.default` - Balanced compression/speed (recommended)
//! - `.best` - Maximum compression, slower
//!
//! ## Compression Strategies
//!
//! - `.default` - Standard compression for general data
//! - `.filtered` - For filtered data (e.g., small values with limited range)
//! - `.huffman_only` - Huffman coding only, no LZ77 matching
//! - `.rle` - Run-length encoding, good for data with many runs

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const bit = @import("bitstream.zig");
const BitReader = bit.BitReader;
const BitWriter = bit.BitWriter;
const huffman = @import("huffman.zig");
const lz77 = @import("lz77.zig");

/// Maximum block size for uncompressed blocks
const MAX_UNCOMPRESSED_BLOCK_SIZE = 65535;

/// Huffman code limits
const MAX_LITERAL_CODES = 286;
const MAX_DISTANCE_CODES = 30;
const MAX_CODE_LENGTH_CODES = 19;

/// DEFLATE compression levels following zlib standard (0-9)
pub const CompressionLevel = enum(u8) {
    /// No compression - store blocks uncompressed
    level_0 = 0,
    /// Fastest compression, lowest compression ratio
    level_1 = 1,
    /// Fast compression, low compression ratio
    level_2 = 2,
    /// Fast compression, slightly better ratio
    level_3 = 3,
    /// Moderate speed, moderate compression
    level_4 = 4,
    /// Moderate speed, good compression
    level_5 = 5,
    /// Default level - good balance of speed and compression
    level_6 = 6,
    /// Slower compression, better ratio
    level_7 = 7,
    /// Slow compression, very good ratio
    level_8 = 8,
    /// Slowest compression, best compression ratio
    level_9 = 9,
};

pub const CompressionStrategy = enum { default, filtered, huffman_only, rle };

pub const DeflateDecoder = struct {
    gpa: Allocator,
    output: ArrayList(u8),
    literal_decoder: huffman.Decoder,
    distance_decoder: huffman.Decoder,
    current_byte_offset: usize = 0,
    max_output_bytes: usize = std.math.maxInt(usize),

    pub fn init(allocator: Allocator) DeflateDecoder {
        return .{
            .gpa = allocator,
            .output = .empty,
            .literal_decoder = .init(allocator),
            .distance_decoder = .init(allocator),
        };
    }

    pub fn deinit(self: *DeflateDecoder) void {
        self.output.deinit(self.gpa);
        self.literal_decoder.deinit();
        self.distance_decoder.deinit();
    }

    pub fn decode(self: *DeflateDecoder, compressed_data: []const u8, max_output_bytes: usize) !ArrayList(u8) {
        self.output.clearRetainingCapacity();
        self.max_output_bytes = max_output_bytes;
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
                3 => return error.InvalidDeflateBlockType,
                else => unreachable,
            }
            if (is_final) break;
        }
        return self.output.clone(self.gpa);
    }

    fn decodeUncompressedBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        reader.skipToByteBoundary();
        var len_bytes: [2]u8 = undefined;
        var nlen_bytes: [2]u8 = undefined;
        try reader.readBytes(&len_bytes);
        try reader.readBytes(&nlen_bytes);
        const len = std.mem.readInt(u16, len_bytes[0..2], .little);
        const nlen = std.mem.readInt(u16, nlen_bytes[0..2], .little);
        if (len != ~nlen) return error.InvalidUncompressedBlock;
        try self.ensureOutputCapacity(len);
        const old_len = self.output.items.len;
        const new_len = old_len + len;
        self.output.items.len = new_len;
        try reader.readBytes(self.output.items[old_len..new_len]);
    }

    fn decodeFixedHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        try self.literal_decoder.buildFromLengths(&huffman.FIXED_LITERAL_LENGTHS);
        try self.distance_decoder.buildFromLengths(&huffman.FIXED_DISTANCE_LENGTHS);
        try self.decodeHuffmanBlock(reader);
    }

    fn decodeDynamicHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        const hlit = try reader.readBits(5) + 257;
        const hdist = try reader.readBits(5) + 1;
        const hclen = try reader.readBits(4) + 4;

        var code_length_lengths: [19]u8 = @splat(0);
        for (0..hclen) |i| {
            code_length_lengths[huffman.code_length_order[i]] = @intCast(try reader.readBits(3));
        }
        var code_length_decoder: huffman.Decoder = .init(self.gpa);
        defer code_length_decoder.deinit();
        try code_length_decoder.buildFromLengths(&code_length_lengths);

        var lengths = try self.gpa.alloc(u8, hlit + hdist);
        defer self.gpa.free(lengths);
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
                var r: u32 = repeat_count;
                while (r > 0) : (r -= 1) {
                    if (i >= lengths.len) return error.InvalidCodeLength;
                    lengths[i] = repeat_value;
                    i += 1;
                }
            } else if (symbol == 17) {
                const repeat_count = try reader.readBits(3) + 3;
                var r: u32 = repeat_count;
                while (r > 0) : (r -= 1) {
                    if (i >= lengths.len) return error.InvalidCodeLength;
                    lengths[i] = 0;
                    i += 1;
                }
            } else if (symbol == 18) {
                const repeat_count = try reader.readBits(7) + 11;
                var r: u32 = repeat_count;
                while (r > 0) : (r -= 1) {
                    if (i >= lengths.len) return error.InvalidCodeLength;
                    lengths[i] = 0;
                    i += 1;
                }
            } else {
                return error.InvalidDynamicCodeLength;
            }
        }

        try self.literal_decoder.buildFromLengths(lengths[0..hlit]);
        try self.distance_decoder.buildFromLengths(lengths[hlit .. hlit + hdist]);
        try self.decodeHuffmanBlock(reader);
    }

    fn decodeHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        while (true) {
            const symbol = try self.decodeSymbol(reader, &self.literal_decoder);
            if (symbol < 256) {
                try self.ensureOutputCapacity(1);
                try self.output.append(self.gpa, @intCast(symbol));
            } else if (symbol == 256) {
                break;
            } else if (symbol <= 285) {
                const length_code = symbol - 257;
                if (length_code >= huffman.LENGTH_TABLE.len) return error.InvalidLengthCode;
                const length_info = huffman.LENGTH_TABLE[length_code];
                const length_val: usize = @intCast(length_info.base + try reader.readBits(length_info.extra_bits));

                const distance_symbol = try self.decodeSymbol(reader, &self.distance_decoder);
                if (distance_symbol >= huffman.DISTANCE_TABLE.len) return error.InvalidDistanceCode;
                const distance_info = huffman.DISTANCE_TABLE[distance_symbol];
                const distance_val: usize = @intCast(distance_info.base + try reader.readBits(distance_info.extra_bits));

                if (distance_val > self.output.items.len) return error.InvalidDistance;
                const start_pos = self.output.items.len - distance_val;
                var j: usize = 0;
                try self.ensureOutputCapacity(length_val);
                while (j < length_val) : (j += 1) {
                    const byte = self.output.items[start_pos + (j % distance_val)];
                    try self.output.append(self.gpa, byte);
                }
            } else {
                return error.InvalidDeflateSymbol;
            }
        }
    }

    fn ensureOutputCapacity(self: *DeflateDecoder, additional: usize) !void {
        if (additional == 0) return;
        const new_total = std.math.add(usize, self.output.items.len, additional) catch return error.OutputLimitExceeded;
        if (new_total > self.max_output_bytes) return error.OutputLimitExceeded;

        if (new_total > self.output.capacity) {
            const doubled = std.math.mul(usize, self.output.capacity, 2) catch self.max_output_bytes;
            const desired = @max(new_total, doubled);
            const capped = @min(desired, self.max_output_bytes);
            try self.output.ensureTotalCapacityPrecise(self.gpa, capped);
        }
    }

    fn decodeSymbol(self: *DeflateDecoder, reader: *BitReader, decoder: *huffman.Decoder) !u16 {
        self.current_byte_offset = reader.byte_pos;
        const remaining_bits = (reader.data.len - reader.byte_pos) * 8 - reader.bit_pos;
        if (remaining_bits > 0) {
            var peek_value: u16 = 0;
            var t_byte = reader.byte_pos;
            var t_bit: u8 = reader.bit_pos;
            var i: u8 = 0;
            while (i < 9 and t_byte < reader.data.len) : (i += 1) {
                const bitv = (reader.data[t_byte] >> @as(u3, @intCast(t_bit))) & 1;
                peek_value |= @as(u16, bitv) << @intCast(i);
                t_bit += 1;
                if (t_bit >= 8) {
                    t_bit = 0;
                    t_byte += 1;
                }
            }
            const entry = decoder.fast_table[peek_value & decoder.fast_mask];
            if (entry != 0) {
                const symbol = entry & 0x0FFF;
                const code_length: u8 = @intCast((entry >> 12) & 0xF);
                if (remaining_bits >= code_length) {
                    _ = try reader.readBits(code_length);
                    return symbol;
                }
            }
        }

        if (decoder.root) |root| {
            var current = root;
            while (current.symbol == null) {
                const bitv = try reader.readBits(1);
                if (bitv == 0) {
                    if (current.left) |left| {
                        current = left;
                    } else return error.InvalidDeflateHuffmanCode;
                } else {
                    if (current.right) |right| {
                        current = right;
                    } else return error.InvalidDeflateHuffmanCode;
                }
            }
            return current.symbol.?;
        }
        return error.InvalidDeflateHuffmanCode;
    }
};

pub const DeflateEncoder = struct {
    gpa: Allocator,
    output: ArrayList(u8),
    level: CompressionLevel,
    strategy: CompressionStrategy,
    max_chain: usize,
    nice_length: usize,
    hash_table: lz77.HashTable,
    literal_freq: [MAX_LITERAL_CODES + 2]u32, // 288 total (286 used + 2 reserved)
    distance_freq: [MAX_DISTANCE_CODES + 2]u32, // 32 total (30 used + 2 reserved),

    pub fn init(gpa: Allocator, level: CompressionLevel, strategy: CompressionStrategy) DeflateEncoder {
        const params = getStrategyParams(level, strategy);
        return .{
            .gpa = gpa,
            .output = .empty,
            .level = level,
            .strategy = strategy,
            .max_chain = params.max_chain,
            .nice_length = params.nice_length,
            .hash_table = lz77.HashTable.init(),
            .literal_freq = std.mem.zeroes([MAX_LITERAL_CODES + 2]u32),
            .distance_freq = std.mem.zeroes([MAX_DISTANCE_CODES + 2]u32),
        };
    }

    const LevelParams = struct { max_chain: usize, nice_length: usize };
    fn getStrategyParams(level: CompressionLevel, strategy: CompressionStrategy) LevelParams {
        const base = switch (level) {
            .level_0 => LevelParams{ .max_chain = 0, .nice_length = 0 },
            .level_1 => LevelParams{ .max_chain = 1, .nice_length = 8 },
            .level_2 => LevelParams{ .max_chain = 4, .nice_length = 8 },
            .level_3 => LevelParams{ .max_chain = 8, .nice_length = 16 },
            .level_4 => LevelParams{ .max_chain = 16, .nice_length = 32 },
            .level_5 => LevelParams{ .max_chain = 32, .nice_length = 64 },
            .level_6 => LevelParams{ .max_chain = 32, .nice_length = 128 },
            .level_7 => LevelParams{ .max_chain = 64, .nice_length = 128 },
            .level_8 => LevelParams{ .max_chain = 256, .nice_length = 258 },
            .level_9 => LevelParams{ .max_chain = 4096, .nice_length = 258 },
        };
        return switch (strategy) {
            .default => base,
            .filtered => LevelParams{ .max_chain = @min(base.max_chain, 16), .nice_length = @min(base.nice_length, 32) },
            .rle => LevelParams{ .max_chain = @min(base.max_chain, 8), .nice_length = base.nice_length },
            .huffman_only => LevelParams{ .max_chain = 0, .nice_length = 0 },
        };
    }

    pub fn deinit(self: *DeflateEncoder) void {
        self.output.deinit(self.gpa);
    }

    fn getLengthCode(length: u16) struct { code: u16, extra_bits: u8, extra_value: u16 } {
        for (huffman.LENGTH_TABLE) |lc| {
            if (length >= lc.base) {
                const next_base = if (lc.code == 285) 259 else huffman.LENGTH_TABLE[lc.code - 257 + 1].base;
                if (length < next_base) return .{ .code = lc.code, .extra_bits = lc.extra_bits, .extra_value = length - lc.base };
            }
        }
        return .{ .code = 285, .extra_bits = 0, .extra_value = 0 };
    }

    fn getDistanceCode(distance: u16) struct { code: u16, extra_bits: u8, extra_value: u16 } {
        for (huffman.DISTANCE_TABLE) |dc| {
            if (distance >= dc.base) {
                const next_base = if (dc.code == 29) 32769 else huffman.DISTANCE_TABLE[dc.code + 1].base;
                if (distance < next_base) return .{ .code = dc.code, .extra_bits = dc.extra_bits, .extra_value = distance - dc.base };
            }
        }
        return .{ .code = 29, .extra_bits = 0, .extra_value = 0 };
    }

    pub fn encode(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        self.output.clearRetainingCapacity();
        // Store-only for no compression
        if (self.level == .level_0) return self.encodeUncompressed(data);

        // Use static Huffman for speed (levels 1-3), dynamic for better compression (4-9)
        switch (self.level) {
            .level_0 => return self.encodeUncompressed(data),
            .level_1, .level_2, .level_3 => return self.encodeStaticHuffman(data),
            .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 => return self.encodeDynamicHuffman(data),
        }
    }

    fn shouldUseDynamicHuffman(self: *DeflateEncoder, data: []const u8) !bool {
        _ = self;
        if (data.len < 512) return false;
        var freq: [256]u32 = std.mem.zeroes([256]u32);
        for (data) |b| freq[b] += 1;
        var unique: u32 = 0;
        var maxf: u32 = 0;
        var minf: u32 = std.math.maxInt(u32);
        for (freq) |f| {
            if (f > 0) {
                unique += 1;
                maxf = @max(maxf, f);
                minf = @min(minf, f);
            }
        }
        if (unique > 200) return false;
        if (unique < 20) return true;
        const ratio = if (minf > 0) @as(f32, @floatFromInt(maxf)) / @as(f32, @floatFromInt(minf)) else 1.0;
        return ratio > 10.0;
    }

    fn encodeUncompressed(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        if (data.len == 0) {
            try self.output.append(self.gpa, 0x01); // final block, stored type
            try self.output.append(self.gpa, 0x00); // LEN = 0 (little endian)
            try self.output.append(self.gpa, 0x00);
            try self.output.append(self.gpa, 0xFF); // NLEN = ~LEN
            try self.output.append(self.gpa, 0xFF);
            return self.output.clone(self.gpa);
        }

        const block_size = @min(data.len, MAX_UNCOMPRESSED_BLOCK_SIZE);
        var pos: usize = 0;
        while (pos < data.len) {
            const remaining = data.len - pos;
            const chunk = @min(remaining, block_size);
            const is_final = (pos + chunk >= data.len);
            const header: u8 = if (is_final) 0x01 else 0x00;
            try self.output.append(self.gpa, header);
            const len: u16 = @intCast(chunk);
            const nlen: u16 = ~len;
            try self.output.append(self.gpa, @intCast(len & 0xFF));
            try self.output.append(self.gpa, @intCast((len >> 8) & 0xFF));
            try self.output.append(self.gpa, @intCast(nlen & 0xFF));
            try self.output.append(self.gpa, @intCast((nlen >> 8) & 0xFF));
            try self.output.appendSlice(self.gpa, data[pos .. pos + chunk]);
            pos += chunk;
        }
        return self.output.clone(self.gpa);
    }

    const CodeLenSym = struct { symbol: u8, extra_bits: u8, extra_value: u16 };

    fn encodeCodeLengths(allocator: Allocator, lengths: []const u8) ![]CodeLenSym {
        // Conservative, spec-compliant encoder for the HLIT+HDIST code-length sequence.
        // - Always uses 17/18 for zero runs.
        // - Uses 16 only when repeating the immediately previous non-zero length.
        // - Otherwise emits literal code lengths directly.
        var out: ArrayList(CodeLenSym) = .empty;
        errdefer out.deinit(allocator);

        if (lengths.len == 0) return out.toOwnedSlice(allocator);

        var i: usize = 0;
        var prevlen: i32 = -1;
        while (i < lengths.len) {
            const curlen = lengths[i];
            if (curlen == 0) {
                // Zero run
                var run: usize = 0;
                while (i + run < lengths.len and lengths[i + run] == 0) : (run += 1) {}

                var r = run;
                while (r >= 11) {
                    const c = @min(r, 138);
                    try out.append(allocator, .{ .symbol = 18, .extra_bits = 7, .extra_value = @intCast(c - 11) });
                    r -= c;
                }
                if (r >= 3) {
                    try out.append(allocator, .{ .symbol = 17, .extra_bits = 3, .extra_value = @intCast(r - 3) });
                    r = 0;
                }
                while (r > 0) : (r -= 1) {
                    try out.append(allocator, .{ .symbol = 0, .extra_bits = 0, .extra_value = 0 });
                }
                prevlen = 0;
                i += run;
            } else {
                // Non-zero run of a single code length value
                const val = curlen;
                var run: usize = 0;
                while (i + run < lengths.len and lengths[i + run] == val) : (run += 1) {}

                // Always emit the first instance literally
                try out.append(allocator, .{ .symbol = val, .extra_bits = 0, .extra_value = 0 });
                prevlen = @intCast(val);
                var r = run - 1; // remaining

                // Use 16 only to repeat the same non-zero previous value in 3..6 chunks
                while (r >= 3 and prevlen == val) {
                    const c = @min(r, 6);
                    try out.append(allocator, .{ .symbol = 16, .extra_bits = 2, .extra_value = @intCast(c - 3) });
                    r -= c;
                }
                // Emit any remaining 1-2 as literals
                while (r > 0) : (r -= 1) {
                    try out.append(allocator, .{ .symbol = val, .extra_bits = 0, .extra_value = 0 });
                }

                i += run;
            }
        }

        return out.toOwnedSlice(allocator);
    }

    fn encodeDynamicHuffman(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        self.literal_freq = std.mem.zeroes([288]u32);
        self.distance_freq = std.mem.zeroes([32]u32);
        self.hash_table = lz77.HashTable.init();

        var pos: usize = 0;
        while (pos < data.len) {
            // Find match before inserting current position, so the chain starts from previous head
            const match = if (self.level == .level_0 or self.strategy == .huffman_only)
                null
            else
                self.hash_table.findMatch(data, pos, self.max_chain, self.nice_length);
            if (match) |m| {
                // Insert current position and the covered region into the hash table
                if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
                const length_code = getLengthCode(m.length).code;
                self.literal_freq[length_code] += 1;
                const dist_code = getDistanceCode(m.distance).code;
                self.distance_freq[dist_code] += 1;
                if (self.strategy != .huffman_only) {
                    var step_idx: usize = 1;
                    while (step_idx < m.length and pos + step_idx < data.len) : (step_idx += 1) {
                        self.hash_table.update(data, pos + step_idx);
                    }
                }
                pos += m.length;
            } else {
                if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
                self.literal_freq[data[pos]] += 1;
                pos += 1;
            }
        }
        self.literal_freq[256] = @max(self.literal_freq[256], 1);

        var literal_tree: huffman.Tree = .init(self.gpa);
        try literal_tree.buildFromFrequencies(self.literal_freq[0..286], 15);
        var distance_tree: huffman.Tree = .init(self.gpa);
        try distance_tree.buildFromFrequencies(self.distance_freq[0..30], 15);

        var has_dist = false;
        for (distance_tree.lengths[0..30]) |l| {
            if (l > 0) {
                has_dist = true;
                break;
            }
        }
        if (!has_dist) {
            distance_tree.lengths[0] = 1;
            huffman.generateCanonicalCodes(&distance_tree.lengths, &distance_tree.codes);
        }

        var num_lit_codes: usize = 257;
        for (0..286) |i| {
            if (literal_tree.lengths[285 - i] != 0) {
                num_lit_codes = 286 - i;
                break;
            }
        }
        // Ensure within spec limits (257-286)
        num_lit_codes = @max(num_lit_codes, 257);
        num_lit_codes = @min(num_lit_codes, 286);

        var num_dist_codes: usize = 1;
        for (0..30) |i| {
            if (distance_tree.lengths[29 - i] != 0) {
                num_dist_codes = 30 - i;
                break;
            }
        }
        // Ensure within spec limits (1-30)
        num_dist_codes = @max(num_dist_codes, 1);
        num_dist_codes = @min(num_dist_codes, 30);

        var all_lengths: ArrayList(u8) = .empty;
        defer all_lengths.deinit(self.gpa);
        try all_lengths.appendSlice(self.gpa, literal_tree.lengths[0..num_lit_codes]);
        try all_lengths.appendSlice(self.gpa, distance_tree.lengths[0..num_dist_codes]);
        const enc_lengths = try encodeCodeLengths(self.gpa, all_lengths.items);
        defer self.gpa.free(enc_lengths);

        var cl_freq: [MAX_CODE_LENGTH_CODES]u32 = std.mem.zeroes([MAX_CODE_LENGTH_CODES]u32);
        for (enc_lengths) |cl| cl_freq[cl.symbol] += 1;
        var cl_tree: huffman.Tree = .init(self.gpa);
        try cl_tree.buildFromFrequencies(cl_freq[0..19], 7);
        var num_cl_codes: usize = 4;
        for (0..MAX_CODE_LENGTH_CODES) |i| {
            const idx = huffman.code_length_order[MAX_CODE_LENGTH_CODES - 1 - i];
            if (cl_tree.lengths[idx] != 0) {
                num_cl_codes = MAX_CODE_LENGTH_CODES - i;
                break;
            }
        }
        // Ensure within spec limits (4-19)
        num_cl_codes = @max(num_cl_codes, 4);
        num_cl_codes = @min(num_cl_codes, MAX_CODE_LENGTH_CODES);

        var writer = BitWriter.init(&self.output);
        try writer.writeBits(self.gpa, 0x5, 3); // final block + dynamic (BFINAL=1, BTYPE=10)
        const HLIT = num_lit_codes - 257;
        const HDIST = num_dist_codes - 1;
        const HCLEN = num_cl_codes - 4;

        // Validate HLIT (0-29), HDIST (0-29), HCLEN (0-15) are within spec
        std.debug.assert(HLIT <= 29); // 257 + 29 = 286 max lit codes
        std.debug.assert(HDIST <= 29); // 1 + 29 = 30 max dist codes
        std.debug.assert(HCLEN <= 15); // 4 + 15 = 19 max code length codes

        try writer.writeBits(self.gpa, @intCast(HLIT), 5);
        try writer.writeBits(self.gpa, @intCast(HDIST), 5);
        try writer.writeBits(self.gpa, @intCast(HCLEN), 4);
        for (0..num_cl_codes) |i| {
            const sym = huffman.code_length_order[i];
            try writer.writeBits(self.gpa, cl_tree.lengths[sym], 3);
        }
        for (enc_lengths) |cl| {
            const ci = cl_tree.getCode(cl.symbol);
            const rc = huffman.reverseBits(ci.code, ci.bits);
            try writer.writeBits(self.gpa, rc, ci.bits);
            if (cl.extra_bits > 0) try writer.writeBits(self.gpa, cl.extra_value, cl.extra_bits);
        }

        self.hash_table = .init();
        pos = 0;
        while (pos < data.len) {
            // Query match before inserting current pos to avoid self-hit in the chain
            const match = if (self.level != .level_0 and self.strategy != .huffman_only)
                self.hash_table.findMatch(data, pos, self.max_chain, self.nice_length)
            else
                null;
            if (match) |m| {
                if (self.strategy != .huffman_only) {
                    // Insert current position and the covered region into the hash table
                    self.hash_table.update(data, pos);
                    var step_idx2: usize = 1;
                    while (step_idx2 < m.length and pos + step_idx2 < data.len) : (step_idx2 += 1) {
                        self.hash_table.update(data, pos + step_idx2);
                    }
                }
                const li = getLengthCode(m.length);
                const lc = literal_tree.getCode(li.code);
                try writer.writeBits(self.gpa, huffman.reverseBits(lc.code, lc.bits), lc.bits);
                if (li.extra_bits > 0) try writer.writeBits(self.gpa, li.extra_value, li.extra_bits);
                const di = getDistanceCode(m.distance);
                const dc = distance_tree.getCode(di.code);
                try writer.writeBits(self.gpa, huffman.reverseBits(dc.code, dc.bits), dc.bits);
                if (di.extra_bits > 0) try writer.writeBits(self.gpa, di.extra_value, di.extra_bits);
                pos += m.length;
            } else {
                if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
                const lc = literal_tree.getCode(data[pos]);
                try writer.writeBits(self.gpa, huffman.reverseBits(lc.code, lc.bits), lc.bits);
                pos += 1;
            }
        }
        const eob = literal_tree.getCode(256);
        try writer.writeBits(self.gpa, huffman.reverseBits(eob.code, eob.bits), eob.bits);
        try writer.flush(self.gpa);
        return self.output.clone(self.gpa);
    }

    fn encodeStaticHuffman(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        var writer = BitWriter.init(&self.output);
        self.hash_table = .init();
        try writer.writeBits(self.gpa, 0x3, 3); // final block + static (BFINAL=1, BTYPE=01)

        // Build static literal and distance codes at comptime via canonical generator
        const Codes = struct { code: u16, bits: u8 };
        const lit_codes = blk: {
            @setEvalBranchQuota(10000);
            var codes: [288]Codes = undefined;
            var lens = huffman.FIXED_LITERAL_LENGTHS;
            var codes_raw: [288]u16 = undefined;
            huffman.generateCanonicalCodes(&lens, &codes_raw);
            for (codes_raw, 0..) |c, i| {
                codes[i] = .{ .code = huffman.reverseBits(c, lens[i]), .bits = lens[i] };
            }
            break :blk codes;
        };
        const dist_codes = blk: {
            var codes: [32]Codes = undefined;
            var lens = huffman.FIXED_DISTANCE_LENGTHS;
            var codes_raw: [32]u16 = undefined;
            huffman.generateCanonicalCodes(&lens, &codes_raw);
            for (codes_raw, 0..) |c, i| {
                codes[i] = .{ .code = huffman.reverseBits(c, lens[i]), .bits = lens[i] };
            }
            break :blk codes;
        };

        var pos: usize = 0;
        while (pos < data.len) {
            // Query match BEFORE inserting current position into the hash chains
            const match = if (self.level == .level_1 and self.strategy != .huffman_only)
                self.hash_table.findMatchFast(data, pos)
            else if (self.level != .level_0 and self.strategy != .huffman_only)
                self.hash_table.findMatch(data, pos, self.max_chain, self.nice_length)
            else
                null;
            if (match) |m| {
                // Skip hash updates for most positions in level_1 mode
                if (self.level != .level_1) {
                    if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
                    var step_idx3: usize = 1;
                    while (step_idx3 < m.length and pos + step_idx3 < data.len) : (step_idx3 += 1) {
                        if (self.strategy != .huffman_only) self.hash_table.update(data, pos + step_idx3);
                    }
                }
                const li = getLengthCode(m.length);
                const lc = lit_codes[li.code];
                try writer.writeBits(self.gpa, lc.code, lc.bits);
                if (li.extra_bits > 0) try writer.writeBits(self.gpa, li.extra_value, li.extra_bits);
                const di = getDistanceCode(m.distance);
                const dc = dist_codes[di.code];
                try writer.writeBits(self.gpa, dc.code, dc.bits);
                if (di.extra_bits > 0) try writer.writeBits(self.gpa, di.extra_value, di.extra_bits);
                pos += m.length;
            } else {
                // No match: insert current pos (fast mode updates every other pos)
                if (self.strategy != .huffman_only) {
                    if (self.level == .level_1) {
                        if (pos % 2 == 0) self.hash_table.updateFast(data, pos);
                    } else {
                        self.hash_table.update(data, pos);
                    }
                }
                const lc = lit_codes[data[pos]];
                try writer.writeBits(self.gpa, lc.code, lc.bits);
                pos += 1;
            }
        }
        const eob = lit_codes[256];
        try writer.writeBits(self.gpa, eob.code, eob.bits);
        try writer.flush(self.gpa);
        return self.output.clone(self.gpa);
    }
};

pub fn inflate(gpa: Allocator, compressed_data: []const u8, max_output_bytes: usize) ![]u8 {
    var decoder = DeflateDecoder.init(gpa);
    defer decoder.deinit();
    var result = try decoder.decode(compressed_data, max_output_bytes);
    defer result.deinit(gpa);
    return result.toOwnedSlice(gpa);
}

pub fn deflate(gpa: Allocator, data: []const u8, level: CompressionLevel, strategy: CompressionStrategy) ![]u8 {
    var encoder = DeflateEncoder.init(gpa, level, strategy);
    defer encoder.deinit();
    var result = try encoder.encode(data);
    defer result.deinit(gpa);
    return result.toOwnedSlice(gpa);
}

// Tests
test "deflate decompression empty" {
    const allocator = std.testing.allocator;
    const empty_data = [_]u8{};
    const result = inflate(allocator, &empty_data, std.math.maxInt(usize));
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "deflate round-trip uncompressed" {
    const allocator = std.testing.allocator;
    const original_data = "Hello, World! This is a test string for deflate compression.";
    const compressed = try deflate(allocator, original_data, .level_0, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed, std.math.maxInt(usize));
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

test "deflate level_1 fast mode" {
    const allocator = std.testing.allocator;
    const base = "The quick brown fox jumps over the lazy dog. ";
    const test_data = blk: {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        for (0..100) |_| {
            try data.appendSlice(allocator, base);
        }
        break :blk try data.toOwnedSlice(allocator);
    };
    defer allocator.free(test_data);

    // Test that level_1 (fast) mode works and produces valid output
    const compressed_fast = try deflate(allocator, test_data, .level_1, .default);
    defer allocator.free(compressed_fast);

    const decompressed = try inflate(allocator, compressed_fast, std.math.maxInt(usize));
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, test_data, decompressed);

    // Compare with level_6 compression (level_1 should be larger but still compressed)
    const compressed_default = try deflate(allocator, test_data, .level_6, .default);
    defer allocator.free(compressed_default);

    // level_1 should still compress (be smaller than original)
    try std.testing.expect(compressed_fast.len < test_data.len);

    // But typically larger than default compression (trading size for speed)
    // This is not guaranteed for all inputs, so we just verify it works
}

test "deflate uncompressed header endianness" {
    const allocator = std.testing.allocator;
    const test_data = "Test";
    const compressed = try deflate(allocator, test_data, .level_0, .default);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= 5);
    try std.testing.expectEqual(@as(u8, 0x01), compressed[0]);
    const len = compressed[1] | (@as(u16, compressed[2]) << 8);
    const nlen = compressed[3] | (@as(u16, compressed[4]) << 8);
    try std.testing.expectEqual(@as(u16, 4), len);
    try std.testing.expectEqual(@as(u16, 0xFFFB), nlen);
}

test "deflate uncompressed empty payload" {
    const allocator = std.testing.allocator;
    const compressed = try deflate(allocator, "", .level_0, .default);
    defer allocator.free(compressed);
    try std.testing.expectEqual(@as(usize, 5), compressed.len);
    const decompressed = try inflate(allocator, compressed, std.math.maxInt(usize));
    defer allocator.free(decompressed);
    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}

test "deflate encoder and decoder reuse without residue" {
    const allocator = std.testing.allocator;
    var encoder = DeflateEncoder.init(allocator, .level_0, .default);
    defer encoder.deinit();
    var decoder = DeflateDecoder.init(allocator);
    defer decoder.deinit();

    const first = "reusable encoder";
    var encoded_first = try encoder.encode(first);
    defer encoded_first.deinit(allocator);
    var decoded_first = try decoder.decode(encoded_first.items, std.math.maxInt(usize));
    defer decoded_first.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first, decoded_first.items);

    const second = "second payload";
    var encoded_second = try encoder.encode(second);
    defer encoded_second.deinit(allocator);
    var decoded_second = try decoder.decode(encoded_second.items, std.math.maxInt(usize));
    defer decoded_second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, second, decoded_second.items);
}

test "deflate decoder capacity respects caller limit" {
    const allocator = std.testing.allocator;
    var data: [600]u8 = undefined;
    for (&data, 0..) |*byte, idx| {
        byte.* = @intCast(idx % 251);
    }
    const compressed = try deflate(allocator, data[0..], .level_6, .default);
    defer allocator.free(compressed);

    var decoder = DeflateDecoder.init(allocator);
    defer decoder.deinit();
    const limit: usize = data.len + 50;

    var decoded = try decoder.decode(compressed, limit);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(data.len, decoded.items.len);
    try std.testing.expect(decoded.capacity <= limit);
    try std.testing.expectEqualSlices(u8, data[0..], decoded.items);
}

test "encodeCodeLengths emits spec-compliant stream" {
    const allocator = std.testing.allocator;

    // Construct a pattern of lengths with zero and non-zero runs
    var lengths = [_]u8{
        3, 3, 3, 3, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 0, 0, 0, 1, 1, 1, 1, 1,
    };

    const enc = try DeflateEncoder.encodeCodeLengths(allocator, &lengths);
    defer allocator.free(enc);

    // Build code-length Huffman over symbols 0..18 from frequencies
    var cl_freq: [19]u32 = std.mem.zeroes([19]u32);
    for (enc) |e| cl_freq[e.symbol] += 1;
    var cl_tree: huffman.Tree = .init(allocator);
    defer cl_tree = cl_tree; // silence unused set warning
    try cl_tree.buildFromFrequencies(cl_freq[0..19], 7);

    // Serialize enc to a bitstream using cl_tree and decode it back
    var bits = std.ArrayList(u8).empty;
    defer bits.deinit(allocator);
    var bw = bit.BitWriter.init(&bits);
    for (enc) |e| {
        const ci = cl_tree.getCode(e.symbol);
        const rc = huffman.reverseBits(ci.code, ci.bits);
        try bw.writeBits(allocator, rc, ci.bits);
        if (e.extra_bits > 0) try bw.writeBits(allocator, e.extra_value, e.extra_bits);
    }
    try bw.flush(allocator);

    var br = bit.BitReader.init(bits.items);
    var dec = huffman.Decoder.init(allocator);
    defer dec.deinit();
    try dec.buildFromLengths(&cl_tree.lengths);

    // Local decoder for a single Huffman symbol from `dec`.
    const decodeSym = struct {
        fn go(brp: *bit.BitReader, d: *huffman.Decoder) !u16 {
            // Fast table lookup on up to 9 bits
            const remaining_bits = (brp.data.len - brp.byte_pos) * 8 - brp.bit_pos;
            if (remaining_bits > 0) {
                var peek_value: u16 = 0;
                var t_byte = brp.byte_pos;
                var t_bit: u8 = brp.bit_pos;
                var i: u8 = 0;
                while (i < 9 and t_byte < brp.data.len) : (i += 1) {
                    const bitv = (brp.data[t_byte] >> @as(u3, @intCast(t_bit))) & 1;
                    peek_value |= @as(u16, bitv) << @intCast(i);
                    t_bit += 1;
                    if (t_bit >= 8) {
                        t_bit = 0;
                        t_byte += 1;
                    }
                }
                const entry = d.fast_table[peek_value & d.fast_mask];
                if (entry != 0) {
                    const symbol = entry & 0x0FFF;
                    const code_length: u8 = @intCast((entry >> 12) & 0xF);
                    if (remaining_bits >= code_length) {
                        _ = try brp.readBits(code_length);
                        return symbol;
                    }
                }
            }
            // Fallback to tree walk
            if (d.root) |root| {
                var current = root;
                while (current.symbol == null) {
                    const bitv = try brp.readBits(1);
                    if (bitv == 0) {
                        if (current.left) |left| {
                            current = left;
                        } else return error.InvalidDeflateHuffmanCode;
                    } else {
                        if (current.right) |right| {
                            current = right;
                        } else return error.InvalidDeflateHuffmanCode;
                    }
                }
                return current.symbol.?;
            }
            return error.InvalidDeflateHuffmanCode;
        }
    }.go;

    var out_lens: [lengths.len]u8 = undefined;
    var i: usize = 0;
    while (i < lengths.len) {
        const sym = try decodeSym(&br, &dec);
        if (sym < 16) {
            out_lens[i] = @intCast(sym);
            i += 1;
        } else if (sym == 16) {
            // Repeat previous non-zero 3..6
            try std.testing.expect(i > 0);
            const rep = (try br.readBits(2)) + 3;
            const v = out_lens[i - 1];
            try std.testing.expect(v != 0);
            var r: u32 = rep;
            while (r > 0) : (r -= 1) {
                out_lens[i] = v;
                i += 1;
            }
        } else if (sym == 17) {
            const rep = (try br.readBits(3)) + 3;
            var r: u32 = rep;
            while (r > 0) : (r -= 1) {
                out_lens[i] = 0;
                i += 1;
            }
        } else if (sym == 18) {
            const rep = (try br.readBits(7)) + 11;
            var r: u32 = rep;
            while (r > 0) : (r -= 1) {
                out_lens[i] = 0;
                i += 1;
            }
        } else {
            try std.testing.expect(false); // invalid symbol
        }
    }

    try std.testing.expectEqualSlices(u8, &lengths, &out_lens);
}

test "methods comparison static vs none" {
    const allocator = std.testing.allocator;
    const test_data = "Hello World! Hello World! Hello World! This is a test string for compression.";
    const uncompressed = try deflate(allocator, test_data, .level_0, .default);
    defer allocator.free(uncompressed);
    const static_huffman = try deflate(allocator, test_data, .level_1, .default);
    defer allocator.free(static_huffman);
    const d1 = try inflate(allocator, uncompressed, std.math.maxInt(usize));
    defer allocator.free(d1);
    try std.testing.expectEqualSlices(u8, test_data, d1);
    const d2 = try inflate(allocator, static_huffman, std.math.maxInt(usize));
    defer allocator.free(d2);
    try std.testing.expectEqualSlices(u8, test_data, d2);
}
