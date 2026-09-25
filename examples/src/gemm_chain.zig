//! Experiment: ten chained products with resident weights and one submit, on the GPU, against
//! per-call GPU gemm and the CPU pool. `zig build run-gemm-chain -Drelease=true`
const std = @import("std");
const zignal = @import("zignal");
const Matrix = zignal.Matrix;

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn run(io: std.Io, gpa: std.mem.Allocator, dev: *zignal.gpu.Device, random: std.Random, m: u32, k: u32, layers: usize) !void {
    var x: Matrix(f32) = try .init(gpa, m, k);
    defer x.deinit();
    var w: Matrix(f32) = try .init(gpa, k, k);
    defer w.deinit();
    const amp = @sqrt(3.0 / @as(f32, @floatFromInt(k)));
    for (x.items) |*v| v.* = (random.float(f32) - 0.5) * 2;
    for (w.items) |*v| v.* = (random.float(f32) - 0.5) * 2 * amp;
    const flops: f64 = 2.0 * @as(f64, @floatFromInt(m)) * @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(layers));
    const iters: usize = 5;

    // CPU pool: the same chain, one product after another.
    var cpu_best: i96 = std.math.maxInt(i96);
    var cpu_out: Matrix(f32) = undefined;
    var have_cpu = false;
    for (0..iters) |_| {
        const t = now(io);
        var cur = try x.gemm(io, false, w, false, 1, 0, null);
        for (1..layers) |_| {
            const next = try cur.gemm(io, false, w, false, 1, 0, null);
            cur.deinit();
            cur = next;
        }
        cpu_best = @min(cpu_best, now(io) - t);
        if (have_cpu) cpu_out.deinit();
        cpu_out = cur;
        have_cpu = true;
    }
    defer cpu_out.deinit();

    // GPU per call: upload, one dispatch, readback, for every layer.
    var call_best: i96 = std.math.maxInt(i96);
    for (0..iters) |_| {
        const t = now(io);
        var cur = try dev.gemm(x, false, w, false, 1, 0, null);
        for (1..layers) |_| {
            const next = try dev.gemm(cur, false, w, false, 1, 0, null);
            cur.deinit();
            cur = next;
        }
        call_best = @min(call_best, now(io) - t);
        cur.deinit();
    }

    // GPU resident: weights uploaded once, all layers in one submit.
    const out = try gpa.alloc(f32, x.items.len);
    defer gpa.free(out);
    const chain = try dev.benchChain(io, x, w, layers, iters, out);
    var max_diff: f32 = 0;
    var max_abs: f32 = 0;
    for (out, cpu_out.items) |g, c| {
        max_diff = @max(max_diff, @abs(g - c));
        max_abs = @max(max_abs, @abs(c));
    }
    const resident = chain.input_ns + chain.run_ns + chain.download_ns;
    std.debug.print("{d:>6}x{d:<4} x{d:<2} | {d:>8.2} | {d:>8.2} | {d:>8.2} | {d:>7.2} {d:>6.2} {d:>6.2} | {d:>6.2}x | {d:>6.1} | {d:>7.2} | {e:.1}/{e:.1}\n", .{
        m,                           k,                                             layers,               ms(cpu_best), ms(call_best), ms(resident), ms(chain.input_ns), ms(chain.run_ns), ms(chain.download_ns),
        ms(cpu_best) / ms(resident), flops / @as(f64, @floatFromInt(chain.run_ns)), ms(chain.weights_ns), max_diff,     max_abs,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var dev = try zignal.gpu.Device.init();
    defer dev.deinit();
    std.debug.print("device: {s}\n", .{dev.name()});
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    std.debug.print("{s:>16} | {s:>8} | {s:>8} | {s:>8} | {s:>21} | {s:>7} | {s:>6} | {s:>7} | {s}\n", .{ "M x K, layers", "pool ms", "gpu/call", "resident", "in / run / out ms", "pool/res", "GFLOPS", "w up ms", "maxdiff/maxabs" });
    try run(io, gpa, &dev, random, 65536, 64, 10);
    try run(io, gpa, &dev, random, 16384, 256, 10);
    try run(io, gpa, &dev, random, 4096, 512, 10);
    try run(io, gpa, &dev, random, 1024, 1024, 10);
    try run(io, gpa, &dev, random, 16384, 256, 50);
}
