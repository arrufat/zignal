//! Huffman utilities and tables for DEFLATE

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Reverse bits for DEFLATE bit ordering (LSB-first write)
pub fn reverseBits(code: u16, length: u8) u16 {
    var result: u16 = 0;
    var temp = code;
    var i: u8 = 0;
    while (i < length) : (i += 1) {
        result = (result << 1) | (temp & 1);
        temp >>= 1;
    }
    return result;
}

/// Fixed Huffman code lengths for literal/length alphabet (RFC 1951)
pub const FIXED_LITERAL_LENGTHS = [_]u8{
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
};

/// Fixed distance code lengths (all 5 bits)
pub const FIXED_DISTANCE_LENGTHS: [32]u8 = @splat(5);

/// Unified length/distance code information structure
pub const CodeInfo = struct {
    code: u16,
    base: u16,
    extra_bits: u8,
};

/// Length codes table (257-285 map to lengths 3-258)
pub const LENGTH_TABLE = [_]CodeInfo{ .{ .code = 257, .base = 3, .extra_bits = 0 }, .{ .code = 258, .base = 4, .extra_bits = 0 }, .{ .code = 259, .base = 5, .extra_bits = 0 }, .{ .code = 260, .base = 6, .extra_bits = 0 }, .{ .code = 261, .base = 7, .extra_bits = 0 }, .{ .code = 262, .base = 8, .extra_bits = 0 }, .{ .code = 263, .base = 9, .extra_bits = 0 }, .{ .code = 264, .base = 10, .extra_bits = 0 }, .{ .code = 265, .base = 11, .extra_bits = 1 }, .{ .code = 266, .base = 13, .extra_bits = 1 }, .{ .code = 267, .base = 15, .extra_bits = 1 }, .{ .code = 268, .base = 17, .extra_bits = 1 }, .{ .code = 269, .base = 19, .extra_bits = 2 }, .{ .code = 270, .base = 23, .extra_bits = 2 }, .{ .code = 271, .base = 27, .extra_bits = 2 }, .{ .code = 272, .base = 31, .extra_bits = 2 }, .{ .code = 273, .base = 35, .extra_bits = 3 }, .{ .code = 274, .base = 43, .extra_bits = 3 }, .{ .code = 275, .base = 51, .extra_bits = 3 }, .{ .code = 276, .base = 59, .extra_bits = 3 }, .{ .code = 277, .base = 67, .extra_bits = 4 }, .{ .code = 278, .base = 83, .extra_bits = 4 }, .{ .code = 279, .base = 99, .extra_bits = 4 }, .{ .code = 280, .base = 115, .extra_bits = 4 }, .{ .code = 281, .base = 131, .extra_bits = 5 }, .{ .code = 282, .base = 163, .extra_bits = 5 }, .{ .code = 283, .base = 195, .extra_bits = 5 }, .{ .code = 284, .base = 227, .extra_bits = 5 }, .{ .code = 285, .base = 258, .extra_bits = 0 } };

/// Distance codes table (0-29 map to distances 1-32768)
pub const DISTANCE_TABLE = [_]CodeInfo{ .{ .code = 0, .base = 1, .extra_bits = 0 }, .{ .code = 1, .base = 2, .extra_bits = 0 }, .{ .code = 2, .base = 3, .extra_bits = 0 }, .{ .code = 3, .base = 4, .extra_bits = 0 }, .{ .code = 4, .base = 5, .extra_bits = 1 }, .{ .code = 5, .base = 7, .extra_bits = 1 }, .{ .code = 6, .base = 9, .extra_bits = 2 }, .{ .code = 7, .base = 13, .extra_bits = 2 }, .{ .code = 8, .base = 17, .extra_bits = 3 }, .{ .code = 9, .base = 25, .extra_bits = 3 }, .{ .code = 10, .base = 33, .extra_bits = 4 }, .{ .code = 11, .base = 49, .extra_bits = 4 }, .{ .code = 12, .base = 65, .extra_bits = 5 }, .{ .code = 13, .base = 97, .extra_bits = 5 }, .{ .code = 14, .base = 129, .extra_bits = 6 }, .{ .code = 15, .base = 193, .extra_bits = 6 }, .{ .code = 16, .base = 257, .extra_bits = 7 }, .{ .code = 17, .base = 385, .extra_bits = 7 }, .{ .code = 18, .base = 513, .extra_bits = 8 }, .{ .code = 19, .base = 769, .extra_bits = 8 }, .{ .code = 20, .base = 1025, .extra_bits = 9 }, .{ .code = 21, .base = 1537, .extra_bits = 9 }, .{ .code = 22, .base = 2049, .extra_bits = 10 }, .{ .code = 23, .base = 3073, .extra_bits = 10 }, .{ .code = 24, .base = 4097, .extra_bits = 11 }, .{ .code = 25, .base = 6145, .extra_bits = 11 }, .{ .code = 26, .base = 8193, .extra_bits = 12 }, .{ .code = 27, .base = 12289, .extra_bits = 12 }, .{ .code = 28, .base = 16385, .extra_bits = 13 }, .{ .code = 29, .base = 24577, .extra_bits = 13 } };

/// Generate canonical codes for given bit lengths
pub fn generateCanonicalCodes(lengths: []const u8, out_codes: []u16) void {
    // Count codes of each length
    var bl_count: [16]u16 = std.mem.zeroes([16]u16);
    for (lengths) |len| {
        if (len > 0) bl_count[len] += 1;
    }

    var code: u16 = 0;
    var next_code: [16]u16 = std.mem.zeroes([16]u16);
    bl_count[0] = 0;
    for (1..16) |bits| {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = code;
    }

    // Assign codes to symbols
    @memset(out_codes, 0);
    for (lengths, 0..) |len, i| {
        if (len != 0) {
            out_codes[i] = next_code[len];
            next_code[len] += 1;
        }
    }
}

/// Decoder node for long codes
const HuffmanNode = struct {
    symbol: ?u16 = null,
    left: ?*HuffmanNode = null,
    right: ?*HuffmanNode = null,
};

/// Huffman decoder table for faster decoding
pub const HuffmanDecoder = struct {
    fast_table: [512]u16 = @splat(0),
    fast_mask: u16 = 511,
    root: ?*HuffmanNode = null,
    allocator: Allocator,
    nodes: ArrayList(HuffmanNode),

    pub fn init(gpa: Allocator) HuffmanDecoder {
        return .{ .allocator = gpa, .nodes = .empty };
    }

    pub fn deinit(self: *HuffmanDecoder) void {
        self.nodes.deinit(self.allocator);
    }

    pub fn buildFromLengths(self: *HuffmanDecoder, code_lengths: []const u8) !void {
        self.fast_table = @splat(0);
        self.nodes.clearRetainingCapacity();
        self.root = null;

        // Compute canonical codes
        const codes = try self.allocator.alloc(u16, code_lengths.len);
        defer self.allocator.free(codes);
        generateCanonicalCodes(code_lengths, codes);

        // Pre-allocate nodes for tree path (worst case: sum of long code lengths)
        var max_nodes: usize = 1;
        for (code_lengths) |len| {
            if (len > 9) max_nodes += len;
        }
        try self.nodes.ensureTotalCapacity(self.allocator, max_nodes);

        // Insert entries into fast table or tree
        for (code_lengths, 0..) |len, symbol| {
            if (len == 0) continue;

            const code = codes[symbol];
            const reversed_code = reverseBits(code, @intCast(len));

            if (len <= 9) {
                const num_entries = @as(u16, 1) << @intCast(9 - len);
                var i: u16 = 0;
                while (i < num_entries) : (i += 1) {
                    const table_index = reversed_code | (i << @intCast(len));
                    self.fast_table[table_index] = @as(u16, @intCast(symbol)) | (@as(u16, @intCast(len)) << 12);
                }
            } else {
                if (self.root == null) {
                    self.nodes.appendAssumeCapacity(.{});
                    self.root = &self.nodes.items[0];
                }

                var current = self.root.?;
                var bit_idx: u8 = 0;
                while (bit_idx < len) : (bit_idx += 1) {
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

/// Code length symbols order for dynamic header
pub const code_length_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Encoding-side Huffman tree (builds lengths and canonical codes)
pub const HuffmanTree = struct {
    lengths: [288]u8 = std.mem.zeroes([288]u8),
    codes: [288]u16 = std.mem.zeroes([288]u16),
    max_length: u8 = 0,
    allocator: Allocator,

    const Self = @This();

    const Leaf = struct { sym: u16, freq: u32 };
    const Node = struct { freq: u64, left: i32, right: i32, sym: i32 };

    pub fn init(allocator: Allocator) Self {
        return .{
            .lengths = undefined,
            .codes = undefined,
            .max_length = 0,
            .allocator = allocator,
        };
    }

    /// Build length-limited Huffman tree using standard merge + length limiting
    pub fn buildFromFrequencies(self: *Self, frequencies: []const u32, max_bits: u8) !void {
        const n = frequencies.len;
        std.debug.assert(n <= 288);
        self.lengths = std.mem.zeroes([288]u8);
        self.codes = std.mem.zeroes([288]u16);
        self.max_length = 0;

        // Collect leaves
        var leaves_list: ArrayList(Leaf) = .empty;
        defer leaves_list.deinit(self.allocator);
        for (frequencies, 0..) |f, i| {
            if (f > 0) {
                try leaves_list.append(self.allocator, .{ .sym = @intCast(i), .freq = f });
            }
        }

        if (leaves_list.items.len == 0) return; // No symbols
        if (leaves_list.items.len == 1) {
            self.lengths[leaves_list.items[0].sym] = 1;
            self.max_length = 1;
            generateCanonicalCodes(self.lengths[0..], self.codes[0..]);
            return;
        }

        // Build initial Huffman tree by repeatedly merging two lowest frequencies
        var nodes: ArrayList(Node) = .empty;
        defer nodes.deinit(self.allocator);

        // Add leaves as nodes
        for (leaves_list.items) |leaf| {
            try nodes.append(self.allocator, .{ .freq = leaf.freq, .left = -1, .right = -1, .sym = @intCast(leaf.sym) });
        }

        var alive: ArrayList(i32) = .empty;
        defer alive.deinit(self.allocator);
        // Track indices of alive nodes (start with leaves)
        for (0..nodes.items.len) |idx| try alive.append(self.allocator, @intCast(idx));

        // Iteratively merge two minimums
        while (alive.items.len > 1) {
            var min1_idx: usize = 0;
            var min2_idx: usize = 1;
            const idx_m2: usize = @intCast(alive.items[min2_idx]);
            const idx_m1: usize = @intCast(alive.items[min1_idx]);
            if (nodes.items[idx_m2].freq < nodes.items[idx_m1].freq) {
                const tmp = min1_idx;
                min1_idx = min2_idx;
                min2_idx = tmp;
            }
            var i: usize = 2;
            while (i < alive.items.len) : (i += 1) {
                const ni: usize = @intCast(alive.items[i]);
                const nf = nodes.items[ni].freq;
                const cur_m1: usize = @intCast(alive.items[min1_idx]);
                const cur_m2: usize = @intCast(alive.items[min2_idx]);
                if (nf < nodes.items[cur_m1].freq) {
                    min2_idx = min1_idx;
                    min1_idx = i;
                } else if (nf < nodes.items[cur_m2].freq) {
                    min2_idx = i;
                }
            }

            const a: usize = @intCast(alive.items[min1_idx]);
            const b: usize = @intCast(alive.items[min2_idx]);
            const combined_freq = nodes.items[a].freq + nodes.items[b].freq;
            try nodes.append(self.allocator, .{ .freq = combined_freq, .left = @intCast(a), .right = @intCast(b), .sym = -1 });
            const new_idx: i32 = @intCast(nodes.items.len - 1);

            // Remove higher index first to avoid shifting earlier index
            if (min1_idx > min2_idx) {
                _ = alive.orderedRemove(min1_idx);
                _ = alive.orderedRemove(min2_idx);
            } else {
                _ = alive.orderedRemove(min2_idx);
                _ = alive.orderedRemove(min1_idx);
            }
            try alive.append(self.allocator, new_idx);
        }

        const root_index = alive.items[0];

        // Compute lengths by DFS
        var stack: ArrayList(struct { idx: i32, depth: u16 }) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, .{ .idx = root_index, .depth = 0 });

        while (stack.items.len > 0) {
            const elem = stack.pop() orelse unreachable;
            const node = nodes.items[@intCast(elem.idx)];
            if (node.sym >= 0) {
                const sym_u: usize = @intCast(node.sym);
                var d: u16 = elem.depth;
                if (d == 0) d = 1;
                if (d > 255) d = 255;
                const dl: u8 = @intCast(@min(d, 255));
                self.lengths[sym_u] = dl;
                self.max_length = @max(self.max_length, dl);
            } else {
                if (node.left >= 0) try stack.append(self.allocator, .{ .idx = node.left, .depth = elem.depth + 1 });
                if (node.right >= 0) try stack.append(self.allocator, .{ .idx = node.right, .depth = elem.depth + 1 });
            }
        }

        // Enforce maximum bit length using zlib-style overflow adjustment
        self.limitCodeLengths(max_bits);

        // Generate canonical codes
        generateCanonicalCodes(self.lengths[0..], self.codes[0..]);
    }

    fn limitCodeLengths(self: *Self, max_bits: u8) void {
        var bl_count: [32]u32 = std.mem.zeroes([32]u32);
        var max_len: u8 = 0;
        for (self.lengths) |l| {
            if (l == 0) continue;
            bl_count[l] += 1;
            if (l > max_len) max_len = l;
        }
        if (max_len <= max_bits) return;

        // Compute overflow (codes longer than max_bits)
        var overflow: u32 = 0;
        var len_i: u8 = max_bits + 1;
        while (len_i <= max_len) : (len_i += 1) overflow += bl_count[len_i];

        while (overflow > 0) {
            // Find j with non-zero count to reduce
            var j: i32 = @intCast(max_bits - 1);
            while (j > 0 and bl_count[@intCast(j)] == 0) j -= 1;
            bl_count[@intCast(j)] -= 1;
            bl_count[@intCast(j + 1)] += 2;
            overflow -= 1;
            // Propagate if needed to keep within bounds
            while (bl_count[@intCast(j + 1)] > 1 and @as(u8, @intCast(j + 1)) < max_bits) {
                bl_count[@intCast(j + 1)] -= 2;
                bl_count[@intCast(j + 2)] += 1;
                j += 1;
            }
        }

        // Reassign lengths deterministically using previous lengths as priority
        var order: [288]u16 = undefined;
        var nsyms: usize = 0;
        for (self.lengths, 0..) |l, i| {
            if (l > 0) {
                order[nsyms] = @intCast(i);
                nsyms += 1;
            }
        }
        // Simple stable selection sort by previous length, then symbol index
        var a: usize = 0;
        while (a < nsyms) : (a += 1) {
            var min_j = a;
            var b: usize = a + 1;
            while (b < nsyms) : (b += 1) {
                const ia = order[min_j];
                const ib = order[b];
                const la = self.lengths[ia];
                const lb = self.lengths[ib];
                if (lb < la or (lb == la and ib < ia)) min_j = b;
            }
            if (min_j != a) {
                const tmp = order[a];
                order[a] = order[min_j];
                order[min_j] = tmp;
            }
        }
        // Assign lengths by counts from shortest to longest
        var idx: usize = 0;
        var l: u8 = 1;
        while (l <= max_bits) : (l += 1) {
            var cnt = bl_count[l];
            while (cnt > 0 and idx < nsyms) : (cnt -= 1) {
                const sym = order[idx];
                self.lengths[sym] = l;
                idx += 1;
            }
        }

        // Update max_length
        self.max_length = 0;
        for (self.lengths) |len| {
            if (len > 0) self.max_length = @max(self.max_length, len);
        }
    }

    pub fn getCode(self: *const Self, symbol: usize) struct { code: u16, bits: u8 } {
        return .{ .code = self.codes[symbol], .bits = self.lengths[symbol] };
    }
};

test "huffman decoder build with varied lengths" {
    const allocator = std.testing.allocator;
    var decoder = HuffmanDecoder.init(allocator);
    defer decoder.deinit();
    const code_lengths = [_]u8{ 3, 4, 5, 6, 6, 6, 7, 7, 7, 8, 10, 10, 10, 11, 11, 12, 12, 12, 12, 13 };
    try decoder.buildFromLengths(&code_lengths);
    try std.testing.expect(decoder.root != null);
}

test "png regression lengths build" {
    const allocator = std.testing.allocator;
    var decoder = HuffmanDecoder.init(allocator);
    defer decoder.deinit();
    const code_lengths = [_]u8{ 0, 0, 0, 0, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 0 };
    try decoder.buildFromLengths(&code_lengths);
    try std.testing.expect(decoder.root != null);
}
