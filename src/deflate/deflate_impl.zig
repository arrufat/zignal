//! DEFLATE encoder/decoder implementation glue

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const bit = @import("bitstream.zig");
const BitReader = bit.BitReader;
const BitWriter = bit.BitWriter;

const huf = @import("huffman.zig");
const HuffmanDecoder = huf.HuffmanDecoder;
const HuffmanTree = huf.HuffmanTree;
const LENGTH_TABLE = huf.LENGTH_TABLE;
const DISTANCE_TABLE = huf.DISTANCE_TABLE;
const FIXED_LITERAL_LENGTHS = huf.FIXED_LITERAL_LENGTHS;
const FIXED_DISTANCE_LENGTHS = huf.FIXED_DISTANCE_LENGTHS;
const reverseBits = huf.reverseBits;
const code_length_order = huf.code_length_order;

const lz = @import("lz77.zig");
const LZ77HashTable = lz.LZ77HashTable;
const LZ77Match = lz.LZ77Match;

pub const CompressionLevel = enum(u4) {
    none = 0,
    fastest = 1,
    fast = 3,
    default = 6,
    best = 9,
    pub fn toInt(self: CompressionLevel) u4 {
        return @intFromEnum(self);
    }
};

pub const CompressionStrategy = enum { default, filtered, huffman_only, rle };

pub const DeflateDecoder = struct {
    gpa: Allocator,
    output: ArrayList(u8),
    literal_decoder: HuffmanDecoder,
    distance_decoder: HuffmanDecoder,
    current_byte_offset: usize = 0,

    pub fn init(allocator: Allocator) DeflateDecoder {
        return .{
            .gpa = allocator,
            .output = .empty,
            .literal_decoder = HuffmanDecoder.init(allocator),
            .distance_decoder = HuffmanDecoder.init(allocator),
        };
    }

    pub fn deinit(self: *DeflateDecoder) void {
        self.output.deinit(self.gpa);
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
        const old_len = self.output.items.len;
        try self.output.resize(self.gpa, old_len + len);
        try reader.readBytes(self.output.items[old_len..]);
    }

    fn decodeFixedHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        try self.literal_decoder.buildFromLengths(&FIXED_LITERAL_LENGTHS);
        try self.distance_decoder.buildFromLengths(&FIXED_DISTANCE_LENGTHS);
        try self.decodeHuffmanBlock(reader);
    }

    fn decodeDynamicHuffmanBlock(self: *DeflateDecoder, reader: *BitReader) !void {
        const hlit = try reader.readBits(5) + 257;
        const hdist = try reader.readBits(5) + 1;
        const hclen = try reader.readBits(4) + 4;

        var code_length_lengths: [19]u8 = @splat(0);
        for (0..hclen) |i| {
            code_length_lengths[code_length_order[i]] = @intCast(try reader.readBits(3));
        }
        var code_length_decoder = HuffmanDecoder.init(self.gpa);
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
                return error.InvalidCodeLengthSymbol;
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
                try self.output.append(self.gpa, @intCast(symbol));
            } else if (symbol == 256) {
                break;
            } else if (symbol <= 285) {
                const length_code = symbol - 257;
                if (length_code >= LENGTH_TABLE.len) return error.InvalidLengthCode;
                const length_info = LENGTH_TABLE[length_code];
                const length_val: usize = @intCast(length_info.base + try reader.readBits(length_info.extra_bits));

                const distance_symbol = try self.decodeSymbol(reader, &self.distance_decoder);
                if (distance_symbol >= DISTANCE_TABLE.len) return error.InvalidDistanceCode;
                const distance_info = DISTANCE_TABLE[distance_symbol];
                const distance_val: usize = @intCast(distance_info.base + try reader.readBits(distance_info.extra_bits));

                if (distance_val > self.output.items.len) return error.InvalidDistance;
                const start_pos = self.output.items.len - distance_val;
                var j: usize = 0;
                while (j < length_val) : (j += 1) {
                    const byte = self.output.items[start_pos + (j % distance_val)];
                    try self.output.append(self.gpa, byte);
                }
            } else {
                return error.InvalidLiteralLengthSymbol;
            }
        }
    }

    fn decodeSymbol(self: *DeflateDecoder, reader: *BitReader, decoder: *HuffmanDecoder) !u16 {
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
                    } else return error.InvalidHuffmanCode;
                } else {
                    if (current.right) |right| {
                        current = right;
                    } else return error.InvalidHuffmanCode;
                }
            }
            return current.symbol.?;
        }
        return error.InvalidHuffmanCode;
    }
};

pub const DeflateEncoder = struct {
    gpa: Allocator,
    output: ArrayList(u8),
    level: CompressionLevel,
    strategy: CompressionStrategy,
    max_chain: usize,
    nice_length: usize,
    hash_table: LZ77HashTable,
    literal_freq: [288]u32,
    distance_freq: [32]u32,

    pub fn init(gpa: Allocator, level: CompressionLevel, strategy: CompressionStrategy) DeflateEncoder {
        const params = getStrategyParams(level, strategy);
        return .{
            .gpa = gpa,
            .output = .empty,
            .level = level,
            .strategy = strategy,
            .max_chain = params.max_chain,
            .nice_length = params.nice_length,
            .hash_table = LZ77HashTable.init(),
            .literal_freq = std.mem.zeroes([288]u32),
            .distance_freq = std.mem.zeroes([32]u32),
        };
    }

    const LevelParams = struct { max_chain: usize, nice_length: usize };
    fn getStrategyParams(level: CompressionLevel, strategy: CompressionStrategy) LevelParams {
        const base = switch (level) {
            .none => LevelParams{ .max_chain = 0, .nice_length = 0 },
            .fastest => LevelParams{ .max_chain = 4, .nice_length = 8 },
            .fast => LevelParams{ .max_chain = 8, .nice_length = 16 },
            .default => LevelParams{ .max_chain = 32, .nice_length = 128 },
            .best => LevelParams{ .max_chain = 4096, .nice_length = 258 },
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
        for (LENGTH_TABLE) |lc| {
            if (length >= lc.base) {
                const next_base = if (lc.code == 285) 259 else LENGTH_TABLE[lc.code - 257 + 1].base;
                if (length < next_base) return .{ .code = lc.code, .extra_bits = lc.extra_bits, .extra_value = length - lc.base };
            }
        }
        return .{ .code = 285, .extra_bits = 0, .extra_value = 0 };
    }

    fn getDistanceCode(distance: u16) struct { code: u16, extra_bits: u8, extra_value: u16 } {
        for (DISTANCE_TABLE) |dc| {
            if (distance >= dc.base) {
                const next_base = if (dc.code == 29) 32769 else DISTANCE_TABLE[dc.code + 1].base;
                if (distance < next_base) return .{ .code = dc.code, .extra_bits = dc.extra_bits, .extra_value = distance - dc.base };
            }
        }
        return .{ .code = 29, .extra_bits = 0, .extra_value = 0 };
    }

    pub fn encode(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        if (self.level == .none) return self.encodeUncompressed(data);
        if (self.level == .best and data.len >= 512) {
            if (try self.shouldUseDynamicHuffman(data)) return self.encodeDynamicHuffman(data);
        }
        return self.encodeStaticHuffman(data);
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
        const block_size = @min(data.len, 65535);
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
        var result: ArrayList(CodeLenSym) = .empty;
        errdefer result.deinit(allocator);
        var i: usize = 0;
        while (i < lengths.len) {
            const current = lengths[i];
            if (current == 0) {
                var run: usize = 1;
                while (i + run < lengths.len and lengths[i + run] == 0) run += 1;
                const total = run;
                while (run > 0) {
                    if (run >= 11) {
                        const count = @min(run, 138);
                        try result.append(allocator, .{ .symbol = 18, .extra_bits = 7, .extra_value = @intCast(count - 11) });
                        run -= count;
                    } else if (run >= 3) {
                        try result.append(allocator, .{ .symbol = 17, .extra_bits = 3, .extra_value = @intCast(run - 3) });
                        run = 0;
                    } else {
                        while (run > 0) : (run -= 1) try result.append(allocator, .{ .symbol = 0, .extra_bits = 0, .extra_value = 0 });
                    }
                }
                i += total;
            } else {
                var run: usize = 1;
                while (i + run < lengths.len and lengths[i + run] == current) run += 1;
                try result.append(allocator, .{ .symbol = current, .extra_bits = 0, .extra_value = 0 });
                const total = run;
                run -= 1;
                while (run >= 3) {
                    const count = @min(run, 6);
                    try result.append(allocator, .{ .symbol = 16, .extra_bits = 2, .extra_value = @intCast(count - 3) });
                    run -= count;
                }
                while (run > 0) : (run -= 1) try result.append(allocator, .{ .symbol = current, .extra_bits = 0, .extra_value = 0 });
                i += total;
            }
        }
        return result.toOwnedSlice(allocator);
    }

    fn encodeDynamicHuffman(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        self.literal_freq = std.mem.zeroes([288]u32);
        self.distance_freq = std.mem.zeroes([32]u32);
        self.hash_table = LZ77HashTable.init();

        var pos: usize = 0;
        while (pos < data.len) {
            if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
            const match = if (self.level == .none or self.strategy == .huffman_only) null else self.hash_table.findMatch(data, pos, self.max_chain, self.nice_length);
            if (match) |m| {
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
                self.literal_freq[data[pos]] += 1;
                pos += 1;
            }
        }
        self.literal_freq[256] = @max(self.literal_freq[256], 1);

        var literal_tree = HuffmanTree{};
        try literal_tree.buildFromFrequencies(self.literal_freq[0..286], 15);
        var distance_tree = HuffmanTree{};
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
            huf.generateCanonicalCodes(distance_tree.lengths[0..], distance_tree.codes[0..]);
        }

        var num_lit_codes: usize = 257;
        for (0..286) |i| {
            if (literal_tree.lengths[285 - i] != 0) {
                num_lit_codes = 286 - i;
                break;
            }
        }
        num_lit_codes = @max(num_lit_codes, 257);
        var num_dist_codes: usize = 1;
        for (0..30) |i| {
            if (distance_tree.lengths[29 - i] != 0) {
                num_dist_codes = 30 - i;
                break;
            }
        }
        num_dist_codes = @max(num_dist_codes, 1);

        var all_lengths: ArrayList(u8) = .empty;
        defer all_lengths.deinit(self.gpa);
        try all_lengths.appendSlice(self.gpa, literal_tree.lengths[0..num_lit_codes]);
        try all_lengths.appendSlice(self.gpa, distance_tree.lengths[0..num_dist_codes]);
        const enc_lengths = try encodeCodeLengths(self.gpa, all_lengths.items);
        defer self.gpa.free(enc_lengths);

        var cl_freq: [19]u32 = std.mem.zeroes([19]u32);
        for (enc_lengths) |cl| cl_freq[cl.symbol] += 1;
        var cl_tree = HuffmanTree{};
        try cl_tree.buildFromFrequencies(cl_freq[0..19], 7);
        var num_cl_codes: usize = 4;
        for (0..19) |i| {
            const idx = code_length_order[18 - i];
            if (cl_tree.lengths[idx] != 0) {
                num_cl_codes = 19 - i;
                break;
            }
        }
        num_cl_codes = @max(num_cl_codes, 4);

        var writer = BitWriter.init(&self.output);
        try writer.writeBits(self.gpa, 0x5, 3); // final block + dynamic (BFINAL=1, BTYPE=10)
        const HLIT = num_lit_codes - 257;
        const HDIST = num_dist_codes - 1;
        const HCLEN = num_cl_codes - 4;
        try writer.writeBits(self.gpa, @intCast(HLIT), 5);
        try writer.writeBits(self.gpa, @intCast(HDIST), 5);
        try writer.writeBits(self.gpa, @intCast(HCLEN), 4);
        for (0..num_cl_codes) |i| {
            const sym = code_length_order[i];
            try writer.writeBits(self.gpa, cl_tree.lengths[sym], 3);
        }
        for (enc_lengths) |cl| {
            const ci = cl_tree.getCode(cl.symbol);
            const rc = reverseBits(ci.code, ci.bits);
            try writer.writeBits(self.gpa, rc, ci.bits);
            if (cl.extra_bits > 0) try writer.writeBits(self.gpa, cl.extra_value, cl.extra_bits);
        }

        self.hash_table = LZ77HashTable.init();
        pos = 0;
        while (pos < data.len) {
            if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
            const match = if (self.level != .none and self.strategy != .huffman_only) self.hash_table.findMatch(data, pos, self.max_chain, self.nice_length) else null;
            if (match) |m| {
                if (self.strategy != .huffman_only) {
                    var step_idx2: usize = 1;
                    while (step_idx2 < m.length and pos + step_idx2 < data.len) : (step_idx2 += 1) {
                        self.hash_table.update(data, pos + step_idx2);
                    }
                }
                const li = getLengthCode(m.length);
                const lc = literal_tree.getCode(li.code);
                try writer.writeBits(self.gpa, reverseBits(lc.code, lc.bits), lc.bits);
                if (li.extra_bits > 0) try writer.writeBits(self.gpa, li.extra_value, li.extra_bits);
                const di = getDistanceCode(m.distance);
                const dc = distance_tree.getCode(di.code);
                try writer.writeBits(self.gpa, reverseBits(dc.code, dc.bits), dc.bits);
                if (di.extra_bits > 0) try writer.writeBits(self.gpa, di.extra_value, di.extra_bits);
                pos += m.length;
            } else {
                const lc = literal_tree.getCode(data[pos]);
                try writer.writeBits(self.gpa, reverseBits(lc.code, lc.bits), lc.bits);
                pos += 1;
            }
        }
        const eob = literal_tree.getCode(256);
        try writer.writeBits(self.gpa, reverseBits(eob.code, eob.bits), eob.bits);
        try writer.flush(self.gpa);
        return self.output.clone(self.gpa);
    }

    fn encodeStaticHuffman(self: *DeflateEncoder, data: []const u8) !ArrayList(u8) {
        var writer = BitWriter.init(&self.output);
        self.hash_table = LZ77HashTable.init();
        try writer.writeBits(self.gpa, 0x3, 3); // final block + static (BFINAL=1, BTYPE=01)

        // Build static literal and distance codes at comptime via canonical generator
        const Codes = struct { code: u16, bits: u8 };
        const lit_codes = blk: {
            @setEvalBranchQuota(10000);
            var codes: [288]Codes = undefined;
            var lens = FIXED_LITERAL_LENGTHS;
            var codes_raw: [288]u16 = undefined;
            huf.generateCanonicalCodes(lens[0..], codes_raw[0..]);
            for (codes_raw, 0..) |c, i| {
                codes[i] = .{ .code = reverseBits(c, lens[i]), .bits = lens[i] };
            }
            break :blk codes;
        };
        const dist_codes = blk: {
            var codes: [32]Codes = undefined;
            var lens = FIXED_DISTANCE_LENGTHS;
            var codes_raw: [32]u16 = undefined;
            huf.generateCanonicalCodes(lens[0..], codes_raw[0..]);
            for (codes_raw, 0..) |c, i| {
                codes[i] = .{ .code = reverseBits(c, lens[i]), .bits = lens[i] };
            }
            break :blk codes;
        };

        var pos: usize = 0;
        while (pos < data.len) {
            if (self.strategy != .huffman_only) self.hash_table.update(data, pos);
            const match = if (self.level != .none and self.strategy != .huffman_only) self.hash_table.findMatch(data, pos, self.max_chain, self.nice_length) else null;
            if (match) |m| {
                var step_idx3: usize = 1;
                while (step_idx3 < m.length and pos + step_idx3 < data.len) : (step_idx3 += 1) {
                    if (self.strategy != .huffman_only) self.hash_table.update(data, pos + step_idx3);
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

pub fn inflate(gpa: Allocator, compressed_data: []const u8) ![]u8 {
    var decoder = DeflateDecoder.init(gpa);
    defer decoder.deinit();
    var result = try decoder.decode(compressed_data);
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
