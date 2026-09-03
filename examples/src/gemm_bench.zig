//! GEMM micro-benchmark: `Matrix(f32).gemm` on one thread and on the process thread pool.
//! Square matrices from 64 up to the optional CLI arg (default 1024), plus a tall-skinny case:
//! `zig build run-gemm-bench --release -- 2048`.
const std = @import("std");
const zignal = @import("zignal");
const Matrix = zignal.Matrix;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// Best-of-`iters` wall time of one product on `run_io`.
fn bestNs(io: std.Io, run_io: std.Io, a: Matrix(f32), b: Matrix(f32), iters: usize) !i96 {
    var best: i96 = std.math.maxInt(i96);
    for (0..iters) |_| {
        const start = nowNs(io);
        var c = try a.gemm(run_io, false, b, false, 1.0, 0.0, null);
        best = @min(best, nowNs(io) - start);
        c.deinit();
    }
    return best;
}

fn bench(io: std.Io, gpa: std.mem.Allocator, random: std.Random, m: u32, k: u32, n: u32) !void {
    var a: Matrix(f32) = try .init(gpa, m, k);
    defer a.deinit();
    var b: Matrix(f32) = try .init(gpa, k, n);
    defer b.deinit();
    for (a.items) |*x| x.* = random.float(f32) - 0.5;
    for (b.items) |*x| x.* = random.float(f32) - 0.5;

    // Fewer iterations as the work grows; roughly 2 GFLOP per size and side.
    const flops: u64 = 2 * @as(u64, m) * k * n;
    const iters: usize = @max(1, @min(10, (1 << 31) / flops));
    const serial = try bestNs(io, std.Io.Threaded.global_single_threaded.io(), a, b, iters);
    const pool = try bestNs(io, io, a, b, iters);
    const gflops = @as(f64, @floatFromInt(flops)) / @as(f64, @floatFromInt(pool));
    std.debug.print("{d:>5}x{d:<5}x{d:<5} | {d:>10.3} | {d:>10.3} | {d:>7.2}x | {d:>7.1}\n", .{ m, k, n, ms(serial), ms(pool), ms(serial) / ms(pool), gflops });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const max_size: u32 = if (args.next()) |arg| try std.fmt.parseInt(u32, arg, 10) else 1024;

    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const random = prng.random();

    std.debug.print("{s:>17} | {s:>10} | {s:>10} | {s:>8} | {s:>7}\n", .{ "m x k x n", "serial ms", "pool ms", "speedup", "GFLOPS" });
    std.debug.print("{s:-<17}-+-{s:-<10}-+-{s:-<10}-+-{s:-<8}-+-{s:-<7}\n", .{ "", "", "", "", "" });

    var size: u32 = 64;
    while (size <= max_size) : (size *= 2) try bench(io, gpa, random, size, size, size);
    try bench(io, gpa, random, 4096, 64, 4096);
}
