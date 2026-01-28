const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const StrategyType = enum {
    default,
    filtered,
    huffman_only,
    rle,
};

pub const Strategy = struct {
    type: StrategyType = .default,
    level: flate.Compress.Options = .default,

    pub const default = Strategy{ .type = .default };
    pub const filtered = Strategy{ .type = .filtered };
    pub const huffman_only = Strategy{ .type = .huffman_only };
    pub const rle = Strategy{ .type = .rle };

    pub fn apply(self: Strategy) flate.Compress.Options {
        var opts = self.level;
        switch (self.type) {
            .default => {},
            .filtered => {
                opts.chain = @min(opts.chain, 16);
                opts.nice = @min(opts.nice, 32);
            },
            .rle => {
                opts.chain = @min(opts.chain, 8);
            },
            .huffman_only => {
                opts.chain = 0;
            },
        }
        return opts;
    }
};

/// Generic compression function
pub fn deflate(gpa: Allocator, data: []const u8, strategy: Strategy, container: flate.Container) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // PNG and other users might benefit from some initial capacity
    try aw.ensureTotalCapacity(data.len / 2 + 64);

    const buffer = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(buffer);

    if (strategy.type == .huffman_only) {
        var huff: flate.Compress.Huffman = try .init(&aw.writer, buffer, container);
        try huff.writer.writeAll(data);
        try huff.writer.flush();
    } else {
        const opts = strategy.apply();
        var compressor: flate.Compress = try .init(&aw.writer, buffer, container, opts);
        try compressor.writer.writeAll(data);
        try compressor.writer.flush();
    }

    return aw.toOwnedSlice();
}

/// Generic decompression function
pub fn inflate(gpa: Allocator, data: []const u8, limit: std.Io.Limit, container: flate.Container) ![]u8 {
    var in_stream: std.Io.Reader = .fixed(data);
    const buffer = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(buffer);

    var decompressor: flate.Decompress = .init(&in_stream, container, buffer);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    var remaining = limit;
    while (remaining.nonzero()) {
        const n = decompressor.reader.stream(&aw.writer, remaining) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        remaining = remaining.subtract(n).?;
    } else {
        // We reached the limit, check if there's more
        var one_byte_buf: [1]u8 = undefined;
        var dummy_writer: std.Io.Writer = .fixed(&one_byte_buf);
        if (decompressor.reader.stream(&dummy_writer, .limited(1))) |n| {
            if (n > 0) return error.OutputLimitExceeded;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
    }

    return aw.toOwnedSlice();
}
