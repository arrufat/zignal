//! Geometric transform micro-benchmarks: resize, rotate, warp, extract on synthetic images.
//! Reports median times serially and on the process thread pool:
//! `zig build run-transform-bench --release -- [name-filter]`.
const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);
const Rectangle = zignal.Rectangle;
const Interpolation = zignal.Interpolation;
const Point = zignal.Point;

const warmup_iters = 2;
const max_iters = 21;

fn itersFor(rows: usize, cols: usize) usize {
    return if (rows * cols > 4_000_000) 5 else 15;
}

fn skipped(name: []const u8, filter: ?[]const u8) bool {
    return if (filter) |f| std.mem.indexOf(u8, name, f) == null else false;
}

fn fillRandom(comptime T: type, img: Image(T), random: std.Random) void {
    if (T == f32) {
        for (img.data) |*px| px.* = 255 * random.float(f32);
    } else {
        random.bytes(std.mem.sliceAsBytes(img.data));
    }
}

/// Runs `ctx.run(run_io)` on a single-threaded `Io` and on `io`'s pool; reports both medians.
fn benchOp(io: std.Io, name: []const u8, rows: usize, cols: usize, ctx: anytype) !void {
    const serial_ns = try medianNs(io, std.Io.Threaded.global_single_threaded.io(), rows, cols, ctx);
    const parallel_ns = try medianNs(io, io, rows, cols, ctx);
    const serial_ms = @as(f64, @floatFromInt(serial_ns)) / std.time.ns_per_ms;
    const parallel_ms = @as(f64, @floatFromInt(parallel_ns)) / std.time.ns_per_ms;
    const mpix_s = @as(f64, @floatFromInt(rows * cols)) / @as(f64, @floatFromInt(parallel_ns)) * 1000.0;
    std.debug.print("{s:<40} | {d:>4}x{d:<4} | {d:>9.3} | {d:>9.3} | {d:>6.2}x | {d:>8.1}\n", .{ name, rows, cols, serial_ms, parallel_ms, serial_ms / parallel_ms, mpix_s });
}

fn medianNs(io: std.Io, run_io: std.Io, rows: usize, cols: usize, ctx: anytype) !u64 {
    var samples: [max_iters]u64 = undefined;
    const iters = itersFor(rows, cols);
    for (0..warmup_iters) |_| try ctx.run(run_io);
    for (samples[0..iters]) |*s| {
        const start = std.Io.Clock.awake.now(io);
        try ctx.run(run_io);
        s.* = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
    }
    std.mem.sort(u64, samples[0..iters], {}, std.sort.asc(u64));
    return samples[iters / 2];
}

fn methodName(method: Interpolation) []const u8 {
    return switch (method) {
        .mitchell => "mitchell",
        inline else => |_, tag| @tagName(tag),
    };
}

fn benchResize(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, src_rows: u32, src_cols: u32, dst_rows: u32, dst_cols: u32, method: Interpolation) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "resize {s} {s} {d}x{d}->", .{ @typeName(T), methodName(method), src_rows, src_cols });
    if (skipped(name, filter)) return;
    var src: Image(T) = try .init(gpa, src_rows, src_cols);
    defer src.deinit(gpa);
    fillRandom(T, src, random);
    var dst: Image(T) = try .init(gpa, dst_rows, dst_cols);
    defer dst.deinit(gpa);
    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        gpa: std.mem.Allocator,
        method: Interpolation,
        fn run(self: @This(), run_io: std.Io) !void {
            self.src.resize(run_io, self.gpa, self.dst, self.method);
        }
    };
    try benchOp(io, name, dst_rows, dst_cols, Ctx{ .src = src, .dst = dst, .gpa = gpa, .method = method });
}

fn benchRotate(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: u32, cols: u32, method: Interpolation) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "rotate 30deg {s} {s}", .{ @typeName(T), methodName(method) });
    if (skipped(name, filter)) return;
    var src: Image(T) = try .init(gpa, rows, cols);
    defer src.deinit(gpa);
    fillRandom(T, src, random);
    const bounds = src.rotateBounds(std.math.pi / 6.0);
    var dst: Image(T) = try .init(gpa, bounds.rows, bounds.cols);
    defer dst.deinit(gpa);
    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        method: Interpolation,
        fn run(self: @This(), run_io: std.Io) !void {
            self.src.rotateInto(run_io, self.dst, std.math.pi / 6.0, self.method, .zero);
        }
    };
    try benchOp(io, name, bounds.rows, bounds.cols, Ctx{ .src = src, .dst = dst, .method = method });
}

fn benchWarp(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: u32, cols: u32) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "warp similarity {s} bilinear", .{@typeName(T)});
    if (skipped(name, filter)) return;
    var src: Image(T) = try .init(gpa, rows, cols);
    defer src.deinit(gpa);
    fillRandom(T, src, random);
    var dst: Image(T) = try .init(gpa, rows, cols);
    defer dst.deinit(gpa);
    const from = [_]Point(2, f32){ .init(.{ 0, 0 }), .init(.{ 100, 0 }), .init(.{ 0, 100 }) };
    const to = [_]Point(2, f32){ .init(.{ 10, 20 }), .init(.{ 95, 30 }), .init(.{ -8, 108 }) };
    const transform = try zignal.SimilarityTransform(f32).init(&from, &to);
    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        transform: @TypeOf(transform),
        fn run(self: @This(), run_io: std.Io) !void {
            self.src.warp(run_io, self.dst, self.transform, .bilinear);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .src = src, .dst = dst, .transform = transform });
}

fn benchExtract(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: u32, cols: u32, size: u32) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "extract rotated {d}^2 {s} bilinear", .{ size, @typeName(T) });
    if (skipped(name, filter)) return;
    var src: Image(T) = try .init(gpa, rows, cols);
    defer src.deinit(gpa);
    fillRandom(T, src, random);
    var dst: Image(T) = try .init(gpa, size, size);
    defer dst.deinit(gpa);
    const Ctx = struct {
        src: Image(T),
        dst: Image(T),
        rect: zignal.Rectangle(f32),
        fn run(self: @This(), run_io: std.Io) !void {
            self.src.extract(run_io, self.dst, self.rect, 0.4, .bilinear, .zero);
        }
    };
    const half: f32 = @floatFromInt(rows / 3);
    const cx: f32 = @floatFromInt(cols / 2);
    const cy: f32 = @floatFromInt(rows / 2);
    try benchOp(io, name, size, size, Ctx{ .src = src, .dst = dst, .rect = .init(cx - half, cy - half, cx + half, cy + half) });
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

    std.debug.print("{s:<40} | {s:^9} | {s:>9} | {s:>9} | {s:>7} | {s:>8}\n", .{ "benchmark", "output", "serial ms", "pool ms", "speedup", "MPix/s" });
    std.debug.print("{s:-<40}-+-{s:-<9}-+-{s:-<9}-+-{s:-<9}-+-{s:-<7}-+-{s:-<8}\n", .{ "", "", "", "", "", "" });

    // Downscale 4K -> 1080p, then upscale 480p -> 4K; per direction: u8, Rgb, f32; kernels
    // in tap order (bilinear 2, bicubic 4, lanczos 6).
    try benchResize(u8, io, gpa, random, filter, 2160, 3840, 1080, 1920, .bilinear);
    try benchResize(u8, io, gpa, random, filter, 2160, 3840, 1080, 1920, .bicubic);
    try benchResize(u8, io, gpa, random, filter, 2160, 3840, 1080, 1920, .lanczos);
    try benchResize(Rgb, io, gpa, random, filter, 2160, 3840, 1080, 1920, .bilinear);
    try benchResize(Rgb, io, gpa, random, filter, 2160, 3840, 1080, 1920, .bicubic);
    try benchResize(Rgb, io, gpa, random, filter, 2160, 3840, 1080, 1920, .lanczos);
    try benchResize(f32, io, gpa, random, filter, 2160, 3840, 1080, 1920, .bilinear);
    try benchResize(f32, io, gpa, random, filter, 2160, 3840, 1080, 1920, .bicubic);
    try benchResize(f32, io, gpa, random, filter, 2160, 3840, 1080, 1920, .lanczos);
    try benchResize(u8, io, gpa, random, filter, 480, 640, 2160, 3840, .bilinear);
    try benchResize(u8, io, gpa, random, filter, 480, 640, 2160, 3840, .bicubic);
    try benchResize(u8, io, gpa, random, filter, 480, 640, 2160, 3840, .lanczos);
    try benchResize(Rgb, io, gpa, random, filter, 480, 640, 2160, 3840, .bilinear);
    try benchResize(Rgb, io, gpa, random, filter, 480, 640, 2160, 3840, .bicubic);
    try benchResize(Rgb, io, gpa, random, filter, 480, 640, 2160, 3840, .lanczos);

    try benchRotate(Rgb, io, gpa, random, filter, 1080, 1920, .bilinear);
    try benchRotate(u8, io, gpa, random, filter, 1080, 1920, .bicubic);
    try benchWarp(Rgb, io, gpa, random, filter, 1080, 1920);
    try benchExtract(Rgb, io, gpa, random, filter, 2160, 3840, 512);

    try benchConvert(Rgb, u8, io, gpa, random, filter, 2160, 3840);
    try benchConvert(Rgba, Rgb, io, gpa, random, filter, 2160, 3840);
    try benchFlip(Rgb, io, gpa, random, filter, 2160, 3840);
    try benchInsert(Rgba, io, gpa, random, filter, 1080, 1920, 480, 640);
}

fn benchConvert(comptime From: type, comptime To: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: u32, cols: u32) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "convert {s} -> {s}", .{ @typeName(From), @typeName(To) });
    if (skipped(name, filter)) return;
    var src: Image(From) = try .init(gpa, rows, cols);
    defer src.deinit(gpa);
    fillRandom(From, src, random);
    var dst: Image(To) = try .init(gpa, rows, cols);
    defer dst.deinit(gpa);
    const Ctx = struct {
        src: Image(From),
        dst: Image(To),
        fn run(self: @This(), run_io: std.Io) !void {
            self.src.convertInto(run_io, To, self.dst);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .src = src, .dst = dst });
}

/// Both flips back to back, so the image is unchanged between iterations.
fn benchFlip(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: u32, cols: u32) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "flip left-right + top-bottom {s}", .{@typeName(T)});
    if (skipped(name, filter)) return;
    var img: Image(T) = try .init(gpa, rows, cols);
    defer img.deinit(gpa);
    fillRandom(T, img, random);
    const Ctx = struct {
        img: Image(T),
        fn run(self: @This(), run_io: std.Io) !void {
            self.img.flipLeftRight(run_io);
            self.img.flipTopBottom(run_io);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .img = img });
}

/// A rotated, scaled source blended into a canvas: the general `insert` path.
fn benchInsert(comptime T: type, io: std.Io, gpa: std.mem.Allocator, random: std.Random, filter: ?[]const u8, rows: u32, cols: u32, src_rows: u32, src_cols: u32) !void {
    var name_buf: [96]u8 = undefined;
    const name = try std.mem.print(&name_buf, "insert rotated 20deg {s} bilinear normal", .{@typeName(T)});
    if (skipped(name, filter)) return;
    var canvas: Image(T) = try .init(gpa, rows, cols);
    defer canvas.deinit(gpa);
    fillRandom(T, canvas, random);
    var src: Image(T) = try .init(gpa, src_rows, src_cols);
    defer src.deinit(gpa);
    fillRandom(T, src, random);
    const Ctx = struct {
        canvas: Image(T),
        src: Image(T),
        fn run(self: @This(), run_io: std.Io) !void {
            var dst = self.canvas;
            const rect: Rectangle(f32) = .init(200, 100, 200 + 1.5 * 640, 100 + 1.5 * 480);
            dst.insert(run_io, self.src, rect, std.math.pi / 9.0, .bilinear, .normal);
        }
    };
    try benchOp(io, name, rows, cols, Ctx{ .canvas = canvas, .src = src });
}
