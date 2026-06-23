const std = @import("std");
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");

pub const FloodFillOptions = struct {
    pub const Connectivity = enum(u8) {
        four = 4,
        eight = 8,
    };

    pub const ThresholdMode = enum {
        /// Compare each candidate against the seed pixel.
        seed,
        /// Compare each candidate against the neighbor it spread from.
        neighbor,
    };

    /// Maximum color distance for a neighbor to be filled.
    threshold: f64 = 0,
    /// Neighborhood used when expanding the region.
    connectivity: Connectivity = .four,
    /// Reference pixel each candidate is compared against.
    mode: ThresholdMode = .seed,

    pub const default: FloodFillOptions = .{};
};

fn pixelDistance(comptime T: type, p1: T, p2: T) f64 {
    switch (@typeInfo(T)) {
        .int, .float => {
            return @abs(meta.as(f64, p1) - meta.as(f64, p2));
        },
        .@"struct" => {
            var sum_sq: f64 = 0.0;
            inline for (comptime meta.structFields(T)) |field| {
                const diff = meta.as(f64, @field(p1, field.name)) - meta.as(f64, @field(p2, field.name));
                sum_sq += diff * diff;
            }
            return @sqrt(sum_sq);
        },
        .array => |arr_info| {
            var sum_sq: f64 = 0.0;
            for (0..arr_info.len) |i| {
                const diff = meta.as(f64, p1[i]) - meta.as(f64, p2[i]);
                sum_sq += diff * diff;
            }
            return @sqrt(sum_sq);
        },
        else => @compileError("Unsupported pixel type for distance calculation: " ++ @typeName(T)),
    }
}

// Neighbor offsets in row/col order; the first four are 4-connectivity, all eight are 8-connectivity.
const neighbor_offsets = [_][2]i2{
    .{ -1, 0 },  .{ 1, 0 },  .{ 0, -1 }, .{ 0, 1 },
    .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 },
};

pub fn floodFill(
    comptime T: type,
    image: Image(T),
    allocator: std.mem.Allocator,
    start_row: u32,
    start_col: u32,
    fill_value: T,
    options: FloodFillOptions,
) !void {
    if (start_row >= image.rows or start_col >= image.cols) {
        return error.OutOfBounds;
    }

    const seed_val = image.at(start_row, start_col).*;

    const Coord = struct { r: u32, c: u32 };
    var stack = std.ArrayList(Coord).empty;
    defer stack.deinit(allocator);

    // `visited` is densely packed (indexed by `cols`); the image may use a larger `stride`.
    var visited = try allocator.alloc(bool, @as(usize, image.rows) * image.cols);
    defer allocator.free(visited);
    @memset(visited, false);

    try stack.append(allocator, .{ .r = start_row, .c = start_col });
    visited[@as(usize, start_row) * image.cols + start_col] = true;

    const Ctx = struct {
        image: Image(T),
        stack: *std.ArrayList(Coord),
        visited: []bool,
        allocator: std.mem.Allocator,
        options: FloodFillOptions,

        fn check(ctx: *const @This(), nr: u32, nc: u32, comp: T) !void {
            const idx = @as(usize, nr) * ctx.image.cols + nc;
            if (!ctx.visited[idx]) {
                const val = ctx.image.at(nr, nc).*;
                if (pixelDistance(T, val, comp) <= ctx.options.threshold) {
                    ctx.visited[idx] = true;
                    try ctx.stack.append(ctx.allocator, .{ .r = nr, .c = nc });
                }
            }
        }
    };
    const ctx = Ctx{
        .image = image,
        .stack = &stack,
        .visited = visited,
        .allocator = allocator,
        .options = options,
    };

    // Connectivity tag values are the neighbor counts (four = 4, eight = 8).
    const neighbor_count: usize = @intFromEnum(options.connectivity);

    while (stack.pop()) |curr| {
        const orig_val = image.at(curr.r, curr.c).*;
        image.at(curr.r, curr.c).* = fill_value;

        const compare_val = switch (options.mode) {
            .seed => seed_val,
            .neighbor => orig_val,
        };

        for (neighbor_offsets[0..neighbor_count]) |off| {
            const nr = @as(i64, curr.r) + off[0];
            const nc = @as(i64, curr.c) + off[1];
            if (nr < 0 or nr >= image.rows or nc < 0 or nc >= image.cols) continue;
            try ctx.check(@intCast(nr), @intCast(nc), compare_val);
        }
    }
}
