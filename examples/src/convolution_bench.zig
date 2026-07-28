//! Convolution micro-benchmarks: gaussian blur, 2D convolve, sobel, motion blur, separable.
//! Synthetic seeded-random images, no file I/O; reports median time over several iterations.
//! Optional CLI arg filters benchmarks by substring: `run-convolution-bench -- gaussian`

const std = @import("std");
const zignal = @import("zignal");

const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const BorderMode = zignal.BorderMode;

const warmup_iters = 2;
const max_iters = 101;

const sharpen_3x3: [3][3]f32 = .{
    .{ 0, -1, 0 },
    .{ -1, 5, -1 },
    .{ 0, -1, 0 },
};
const box_7x7: [7][7]f32 = @splat(@splat(1.0 / 49.0));
const gaussian_9: [9]f32 = .{ 0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05 };

fn itersFor(rows: usize, cols: usize) usize {
    const pixels = rows * cols;
    return if (pixels <= 64 * 64) max_iters else if (pixels <= 640 * 480) 21 else if (pixels <= 2048 * 2048) 7 else 5;
}

fn fillRandom(comptime T: type, img: Image(T), random: std.Random) void {
    for (img.data) |*px| {
        px.* = switch (T) {
            u8 => random.int(u8),
            f32 => 255 * random.float(f32),
            Rgb => .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) },
            else => @compileError("unsupported pixel type"),
        };
    }
}

/// Checked before any image allocation so filtered-out benchmarks cost nothing.
fn skipped(name: []const u8, filter: ?[]const u8) bool {
    return if (filter) |f| std.mem.indexOf(u8, name, f) == null else false;
}

fn initRandom(comptime T: type, gpa: std.mem.Allocator, random: std.Random, rows: usize, cols: usize) !Image(T) {
    const img: Image(T) = try .init(gpa, @intCast(rows), @intCast(cols));
    fillRandom(T, img, random);
    return img;
}

/// Runs ctx.run() warmup + iters times and reports the median.
fn benchOp(io: std.Io, name: []const u8, rows: usize, cols: usize, ctx: anytype) !void {
    var samples: [max_iters]u64 = undefined;
    const iters = itersFor(rows, cols);
    for (0..warmup_iters) |_| try ctx.run();
    for (samples[0..iters]) |*s| {
        const start = std.Io.Clock.awake.now(io);
        try ctx.run();
        s.* = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
    }
    std.mem.sort(u64, samples[0..iters], {}, std.sort.asc(u64));
    const median_ns = samples[iters / 2];

    const ms = @as(f64, @floatFromInt(median_ns)) / std.time.ns_per_ms;
    const mpix_s = @as(f64, @floatFromInt(rows * cols)) / @as(f64, @floatFromInt(median_ns)) * 1000.0;
    std.debug.print("{s:<42} | {d:>4}x{d:<4} | {d:>10.3} | {d:>8.1}\n", .{ name, rows, cols, ms, mpix_s });
}

fn benchGaussian(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: usize, cols: usize, sigma: f32) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "gaussianBlur {s} sigma={d}", .{ @typeName(T), sigma });
    if (skipped(name, filter)) return;

    var src = try initRandom(T, gpa, random, rows, cols);
    defer src.deinit(gpa);
    var dst: Image(T) = try .initLike(gpa, src);
    defer dst.deinit(gpa);

    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        gpa: std.mem.Allocator,
        sigma: f32,
        fn run(self: @This()) !void {
            try self.src.gaussianBlur(self.dst, self.gpa, self.sigma);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .src = src, .dst = dst, .gpa = gpa, .sigma = sigma });
}

fn benchConvolve2D(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: usize, cols: usize, comptime kernel: anytype, kernel_name: []const u8, border: BorderMode) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "convolve {s} {s} .{s}", .{ kernel_name, @typeName(T), @tagName(border) });
    if (skipped(name, filter)) return;

    var src = try initRandom(T, gpa, random, rows, cols);
    defer src.deinit(gpa);
    var dst: Image(T) = try .initLike(gpa, src);
    defer dst.deinit(gpa);

    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        gpa: std.mem.Allocator,
        border: BorderMode,
        fn run(self: @This()) !void {
            try self.src.convolve(self.dst, self.gpa, kernel, self.border);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .src = src, .dst = dst, .gpa = gpa, .border = border });
}

fn benchSobel(io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: usize, cols: usize) !void {
    if (skipped("sobel f32", filter)) return;

    var src = try initRandom(f32, gpa, random, rows, cols);
    defer src.deinit(gpa);
    var dst: Image(u8) = try .init(gpa, @intCast(rows), @intCast(cols));
    defer dst.deinit(gpa);

    const Ctx = struct {
        src: Image(f32),
        dst: Image(u8),
        gpa: std.mem.Allocator,
        fn run(self: @This()) !void {
            try self.src.sobel(self.dst, self.gpa);
        }
    };
    try benchOp(io, "sobel f32", rows, cols, Ctx{ .src = src, .dst = dst, .gpa = gpa });
}

fn benchMotionBlur(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: usize, cols: usize, distance: usize) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "motionBlur linear horizontal {s} d={d}", .{ @typeName(T), distance });
    if (skipped(name, filter)) return;

    var src = try initRandom(T, gpa, random, rows, cols);
    defer src.deinit(gpa);
    var dst: Image(T) = try .initLike(gpa, src);
    defer dst.deinit(gpa);

    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        gpa: std.mem.Allocator,
        distance: usize,
        fn run(self: @This()) !void {
            try self.src.motionBlur(self.dst, self.gpa, .{ .linear = .{ .angle = 0, .distance = self.distance } });
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .src = src, .dst = dst, .gpa = gpa, .distance = distance });
}

fn benchSeparable(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: usize, cols: usize) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "convolveSeparable {s} 9-tap .mirror", .{@typeName(T)});
    if (skipped(name, filter)) return;

    var src = try initRandom(T, gpa, random, rows, cols);
    defer src.deinit(gpa);
    var dst: Image(T) = try .initLike(gpa, src);
    defer dst.deinit(gpa);

    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        gpa: std.mem.Allocator,
        fn run(self: @This()) !void {
            try self.src.convolveSeparable(self.dst, self.gpa, &gaussian_9, &gaussian_9, .mirror);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .src = src, .dst = dst, .gpa = gpa });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const filter = args.next();

    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const random = prng.random();

    std.debug.print("{s:<42} | {s:^9} | {s:>10} | {s:>8}\n", .{ "benchmark", "size", "ms", "MPix/s" });
    std.debug.print("{s:-<42}-+-{s:-<9}-+-{s:-<10}-+-{s:-<8}\n", .{ "", "", "", "" });

    // Gaussian blur (separable u8 fixed-point and struct paths)
    try benchGaussian(u8, io, gpa, random, filter, 480, 640, 1);
    try benchGaussian(u8, io, gpa, random, filter, 480, 640, 3);
    try benchGaussian(u8, io, gpa, random, filter, 480, 640, 8);
    try benchGaussian(u8, io, gpa, random, filter, 2048, 2048, 3);
    try benchGaussian(u8, io, gpa, random, filter, 2160, 3840, 3);
    try benchGaussian(Rgb, io, gpa, random, filter, 480, 640, 3);
    try benchGaussian(Rgb, io, gpa, random, filter, 2160, 3840, 3);

    // 2D convolution (interior SIMD + border rows; 64x64 with 7x7 is border-dominated)
    try benchConvolve2D(u8, io, gpa, random, filter, 480, 640, sharpen_3x3, "3x3", .mirror);
    try benchConvolve2D(f32, io, gpa, random, filter, 480, 640, sharpen_3x3, "3x3", .mirror);
    try benchConvolve2D(u8, io, gpa, random, filter, 480, 640, box_7x7, "7x7", .mirror);
    try benchConvolve2D(f32, io, gpa, random, filter, 480, 640, box_7x7, "7x7", .mirror);
    try benchConvolve2D(u8, io, gpa, random, filter, 64, 64, box_7x7, "7x7", .mirror);
    try benchConvolve2D(u8, io, gpa, random, filter, 64, 64, box_7x7, "7x7", .zero);

    // Sobel (two 3x3 convolutions over the same f32 source)
    try benchSobel(io, gpa, random, filter, 480, 640);
    try benchSobel(io, gpa, random, filter, 2160, 3840);

    // Axis-aligned motion blur (separable with an identity 1-tap vertical kernel)
    try benchMotionBlur(Rgb, io, gpa, random, filter, 480, 640, 15);
    try benchMotionBlur(u8, io, gpa, random, filter, 480, 640, 15);

    // Separable f32
    try benchSeparable(f32, io, gpa, random, filter, 480, 640);
    try benchSeparable(f32, io, gpa, random, filter, 2048, 2048);
    try benchSeparable(f32, io, gpa, random, filter, 2160, 3840);
}
