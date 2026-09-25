//! Experiment: the f32 register-blocked gemm kernel against an f16 cooperative-matrix kernel
//! (`src/gpu/kernels/gemm_coop.comp`, built with glslc), both resident with one submit per
//! ten layers. `zig build run-gemm-coop -Drelease=true -- ../src/gpu/kernels/gemm_coop.spv`
const std = @import("std");
const zignal = @import("zignal");
const Matrix = zignal.Matrix;

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn run(io: std.Io, gpa: std.mem.Allocator, dev: *zignal.gpu.Device, spv: []const u8, random: std.Random, m: u32, k: u32, layers: usize) !void {
    var x: Matrix(f32) = try .init(gpa, m, k);
    defer x.deinit();
    var w: Matrix(f32) = try .init(gpa, k, k);
    defer w.deinit();
    const amp = @sqrt(3.0 / @as(f32, @floatFromInt(k)));
    // Values representable in f16 so both kernels see the same inputs.
    for (x.items) |*v| v.* = @floatCast(@as(f16, @floatCast((random.float(f32) - 0.5) * 2)));
    for (w.items) |*v| v.* = @floatCast(@as(f16, @floatCast((random.float(f32) - 0.5) * 2 * amp)));
    const xh = try gpa.alloc(f16, x.items.len);
    defer gpa.free(xh);
    const wh = try gpa.alloc(f16, w.items.len);
    defer gpa.free(wh);
    for (x.items, xh) |v, *h| h.* = @floatCast(v);
    for (w.items, wh) |v, *h| h.* = @floatCast(v);
    const flops: f64 = 2.0 * @as(f64, @floatFromInt(m)) * @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(layers));

    var ref = try x.gemm(io, false, w, false, 1, 0, null);
    defer ref.deinit();

    const out32 = try gpa.alloc(f32, x.items.len);
    defer gpa.free(out32);
    const f32_timing = try dev.benchChain(io, x, w, layers, 5, out32);
    const out16 = try gpa.alloc(f32, x.items.len);
    defer gpa.free(out16);
    const coop = try dev.benchCoop(io, gpa, spv, xh, wh, m, k, layers, 5, out16);
    var max_diff: f32 = 0;
    var max_abs: f32 = 0;
    for (out16, ref.items) |g, c| {
        max_diff = @max(max_diff, @abs(g - c));
        max_abs = @max(max_abs, @abs(c));
    }
    std.debug.print("{d:>6}x{d:<4} x{d:<2} | {d:>8.2} {d:>7.0} | {d:>8.2} {d:>7.0} | {d:>5.2}x | {e:.1}/{e:.1}\n", .{
        m,                                       k,        layers,  ms(f32_timing.run_ns), flops / @as(f64, @floatFromInt(f32_timing.run_ns)), ms(coop.run_ns), flops / @as(f64, @floatFromInt(coop.run_ns)),
        ms(f32_timing.run_ns) / ms(coop.run_ns), max_diff, max_abs,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const spv = args.next() orelse return error.MissingSpvPath;
    var dev = try zignal.gpu.Device.init();
    defer dev.deinit();
    std.debug.print("device: {s}\n", .{dev.name()});
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    std.debug.print("{s:>16} | {s:>16} | {s:>16} | {s:>6} | {s}\n", .{ "M x K, layers", "f32 ms GFLOPS", "coop ms GFLOPS", "gain", "maxdiff/maxabs" });
    try run(io, gpa, &dev, spv, random, 65536, 64, 10);
    try run(io, gpa, &dev, spv, random, 16384, 256, 10);
    try run(io, gpa, &dev, spv, random, 4096, 512, 10);
    try run(io, gpa, &dev, spv, random, 1024, 1024, 10);
    try run(io, gpa, &dev, spv, random, 16384, 256, 50);
}
