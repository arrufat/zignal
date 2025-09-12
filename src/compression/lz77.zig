//! LZ77 hash chain matcher for DEFLATE

const std = @import("std");

pub const Match = struct {
    length: u16,
    distance: u16,
};

pub const HashTable = struct {
    pub const HASH_BITS = 15;
    pub const HASH_SIZE = 1 << HASH_BITS;
    pub const HASH_MASK = HASH_SIZE - 1;
    pub const WINDOW_SIZE = 32768;
    pub const MIN_MATCH = 3;
    pub const MAX_MATCH = 258;

    head: [HASH_SIZE]i64, // Head of hash chains (absolute positions or NIL)
    prev: [WINDOW_SIZE]i64, // Previous positions in chain (absolute positions or NIL)

    const Self = @This();
    pub const NIL: i64 = -1; // Sentinel value for no match
    const WINDOW_MASK = WINDOW_SIZE - 1;

    pub fn init() Self {
        var self = Self{ .head = undefined, .prev = undefined };
        @memset(&self.head, NIL);
        @memset(&self.prev, NIL);
        return self;
    }

    fn hash(data: []const u8) u16 {
        if (data.len < 3) return 0;
        const h = (@as(u32, data[0]) << 10) ^ (@as(u32, data[1]) << 5) ^ data[2];
        return @intCast(h & HASH_MASK);
    }

    pub fn update(self: *Self, data: []const u8, pos: usize) void {
        if (pos + MIN_MATCH > data.len) return;
        const h = hash(data[pos..]);
        const window_index = pos & WINDOW_MASK;
        self.prev[window_index] = self.head[h];
        self.head[h] = @intCast(pos);
    }

    pub fn findMatch(self: *Self, data: []const u8, pos: usize, max_chain: usize, nice_length: usize) ?Match {
        if (pos + MIN_MATCH > data.len) return null;
        const h = hash(data[pos..]);
        var chain_pos = self.head[h];
        var chain_length: usize = 0;
        var best: ?Match = null;

        const max_len = @min(MAX_MATCH, data.len - pos);
        const target = @min(nice_length, max_len);

        while (chain_pos >= 0 and chain_length < max_chain) {
            const match_pos: usize = @intCast(chain_pos);
            if (match_pos >= pos) break;
            const distance = pos - match_pos;
            if (distance > WINDOW_SIZE) break;

            var length: u16 = 0;
            while (length < max_len and pos + length < data.len and match_pos + length < data.len and data[pos + length] == data[match_pos + length]) {
                length += 1;
            }

            if (length >= MIN_MATCH) {
                if (best == null or length > best.?.length) {
                    best = Match{ .length = length, .distance = @intCast(distance) };
                    if (length >= target) break;
                }
            }
            chain_pos = self.prev[@intCast(match_pos & WINDOW_MASK)];
            chain_length += 1;
        }

        return best;
    }
};

test "LZ77 hash table absolute positions" {
    var hash_table = HashTable.init();
    const data = "ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP" ** 100; // 3200 bytes
    const positions = [_]usize{ 0, 100, 32760, 32768, 32769, 65536 };
    for (positions) |pos| {
        if (pos + 3 <= data.len) {
            hash_table.update(data, pos);
            if (pos >= 17) {
                const m = hash_table.findMatch(data, pos, 100, 258);
                if (m) |mm| {
                    try std.testing.expect(mm.distance == 17 or mm.distance == 34);
                    try std.testing.expect(mm.length >= 3);
                }
            }
        }
    }
}
