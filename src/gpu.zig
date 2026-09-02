//! GPU compute: SPIR-V kernels written in Zig, dispatched through Vulkan.
//!
//! The Vulkan loader is opened at runtime, so zignal itself stays dependency-free; on Linux the
//! module that uses `Device` must link libc (dlopen). Everything degrades to
//! `error.GpuUnavailable` rather than failing to build.
//!
//! ```zig
//! var dev = try zignal.gpu.Device.init();
//! defer dev.deinit();
//! const c = try dev.gemm(a, false, b, false, 1.0, 0.0, null);
//! ```
const std = @import("std");
const Matrix = @import("matrix.zig").Matrix;

pub const Device = @import("gpu/Device.zig");
/// False when the build (`-Dgpu=false`), OS or lack of libc rules the GPU path out at compile time.
pub const supported = Device.supported;

fn testDevice() !Device {
    return Device.init() catch |err| switch (err) {
        error.GpuUnavailable => error.SkipZigTest,
        else => err,
    };
}

fn randomMatrix(allocator: std.mem.Allocator, random: std.Random, rows: u32, cols: u32) !Matrix(f32) {
    const m: Matrix(f32) = try .init(allocator, rows, cols);
    for (m.items) |*x| x.* = random.float(f32) * 2 - 1;
    return m;
}

fn expectClose(expected: Matrix(f32), actual: Matrix(f32), k: u32) !void {
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.cols, actual.cols);
    const tolerance = 1e-5 * @as(f32, @floatFromInt(k));
    for (expected.items, actual.items) |e, a| try std.testing.expectApproxEqAbs(e, a, tolerance);
}

test "gemm matches the CPU path" {
    var dev = try testDevice();
    defer dev.deinit();
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    // Shapes straddle tile boundaries; each is run with every transpose combination.
    const shapes = [_][3]u32{ .{ 1, 1, 1 }, .{ 16, 16, 16 }, .{ 33, 17, 45 }, .{ 100, 3, 70 }, .{ 5, 130, 9 } };
    for (shapes) |shape| {
        const m, const k, const n = shape;
        for ([_]bool{ false, true }) |trans_a| for ([_]bool{ false, true }) |trans_b| {
            var a = try randomMatrix(allocator, random, if (trans_a) k else m, if (trans_a) m else k);
            defer a.deinit();
            var b = try randomMatrix(allocator, random, if (trans_b) n else k, if (trans_b) k else n);
            defer b.deinit();
            var c = try randomMatrix(allocator, random, m, n);
            defer c.deinit();

            var expected = try a.gemm(std.Io.Threaded.global_single_threaded.io(), trans_a, b, trans_b, 0.75, 0.5, c);
            defer expected.deinit();
            var actual = try dev.gemm(a, trans_a, b, trans_b, 0.75, 0.5, c);
            defer actual.deinit();
            try expectClose(expected, actual, k);

            var expected_plain = try a.gemm(std.Io.Threaded.global_single_threaded.io(), trans_a, b, trans_b, 1.0, 0.0, null);
            defer expected_plain.deinit();
            var actual_plain = try dev.gemm(a, trans_a, b, trans_b, 1.0, 0.0, null);
            defer actual_plain.deinit();
            try expectClose(expected_plain, actual_plain, k);
        };
    }
}

test "gemm rejects mismatched dimensions" {
    var dev = try testDevice();
    defer dev.deinit();
    var a: Matrix(f32) = try .init(std.testing.allocator, 4, 3);
    defer a.deinit();
    var b: Matrix(f32) = try .init(std.testing.allocator, 4, 3);
    defer b.deinit();
    try std.testing.expectError(error.DimensionMismatch, dev.gemm(a, false, b, false, 1.0, 0.0, null));
    var c: Matrix(f32) = try .init(std.testing.allocator, 3, 3);
    defer c.deinit();
    try std.testing.expectError(error.DimensionMismatch, dev.gemm(a, false, b, true, 1.0, 1.0, c));
}
