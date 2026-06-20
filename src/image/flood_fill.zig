const std = @import("std");
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");

pub const Connectivity = enum {
    four,
    eight,
};

pub const ThresholdMode = enum {
    seed_relative,
    parent_relative,
};

pub const DistanceMetric = enum {
    /// Faster, direct channel-by-channel Euclidean distance.
    euclidean,
    /// Perceptually uniform color distance in Oklab space.
    perceptual,
};

pub const FloodFillOptions = struct {
    /// Maximum color/intensity distance for a neighbor to be filled.
    threshold: f64 = 0,
    /// Neighborhood used when expanding the region.
    connectivity: Connectivity = .four,
    /// Whether neighbors are compared against the seed or their parent pixel.
    mode: ThresholdMode = .seed_relative,
    /// How color distance is measured.
    metric: DistanceMetric = .euclidean,

    pub const default: FloodFillOptions = .{};
};

inline fn getScalarValue(comptime ScalarType: type, value: ScalarType) f64 {
    return switch (@typeInfo(ScalarType)) {
        .int => @floatFromInt(value),
        .float => value,
        else => @compileError("Unsupported scalar type: " ++ @typeName(ScalarType)),
    };
}

fn pixelDistance(comptime T: type, p1: T, p2: T, metric: DistanceMetric) f64 {
    const color = @import("../color.zig");
    if (comptime color.isColor(T)) {
        if (metric == .perceptual) {
            const OklabF32 = color.Oklab(f32);
            const o1 = color.convertColor(OklabF32, p1);
            const o2 = color.convertColor(OklabF32, p2);
            const dl = @as(f64, o1.l) - o2.l;
            const da = @as(f64, o1.a) - o2.a;
            const db = @as(f64, o1.b) - o2.b;
            return @sqrt(dl * dl + da * da + db * db);
        }
    }

    switch (@typeInfo(T)) {
        .int, .float => {
            const val1 = getScalarValue(T, p1);
            const val2 = getScalarValue(T, p2);
            return @abs(val1 - val2);
        },
        .@"struct" => {
            var sum_sq: f64 = 0.0;
            inline for (comptime meta.structFields(T)) |field| {
                const val1 = getScalarValue(field.type, @field(p1, field.name));
                const val2 = getScalarValue(field.type, @field(p2, field.name));
                const diff = val1 - val2;
                sum_sq += diff * diff;
            }
            return @sqrt(sum_sq);
        },
        .array => |arr_info| {
            var sum_sq: f64 = 0.0;
            for (0..arr_info.len) |i| {
                const val1 = getScalarValue(arr_info.child, p1[i]);
                const val2 = getScalarValue(arr_info.child, p2[i]);
                const diff = val1 - val2;
                sum_sq += diff * diff;
            }
            return @sqrt(sum_sq);
        },
        else => @compileError("Unsupported pixel type for distance calculation: " ++ @typeName(T)),
    }
}

// Neighbor offsets in row/col order; the first four are 4-connectivity, all eight are 8-connectivity.
const neighbor_offsets = [_][2]i2{
    .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 },
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
    if (options.metric == .perceptual) {
        if (comptime !@import("../color.zig").isColor(T)) {
            @compileError("Perceptual distance metric is only supported for color pixel types.");
        }
    }

    if (start_row >= image.rows or start_col >= image.cols) {
        return error.OutOfBounds;
    }

    const seed_val = image.at(start_row, start_col).*;

    const Coord = struct { r: u32, c: u32 };
    var stack = std.ArrayList(Coord).empty;
    defer stack.deinit(allocator);

    // Note: The visited tracking array is densely packed using `cols`, whereas the
    // image representation uses `stride` for row padding/alignment.
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

        fn check(ctx: @This(), nr: u32, nc: u32, comp: T) !void {
            const idx = @as(usize, nr) * ctx.image.cols + nc;
            if (!ctx.visited[idx]) {
                const val = ctx.image.at(nr, nc).*;
                if (pixelDistance(T, val, comp, ctx.options.metric) <= ctx.options.threshold) {
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

    const neighbor_count: usize = if (options.connectivity == .eight) 8 else 4;

    while (stack.pop()) |curr| {
        const orig_val = image.at(curr.r, curr.c).*;
        image.at(curr.r, curr.c).* = fill_value;

        const compare_val = switch (options.mode) {
            .seed_relative => seed_val,
            .parent_relative => orig_val,
        };

        for (neighbor_offsets[0..neighbor_count]) |off| {
            const nr = @as(i64, curr.r) + off[0];
            const nc = @as(i64, curr.c) + off[1];
            if (nr < 0 or nr >= image.rows or nc < 0 or nc >= image.cols) continue;
            try ctx.check(@intCast(nr), @intCast(nc), compare_val);
        }
    }
}
